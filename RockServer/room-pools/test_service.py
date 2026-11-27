import importlib.util
import json
import pathlib
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

SPEC = importlib.util.spec_from_file_location('room_pools_service', pathlib.Path(__file__).with_name('service.py'))
s = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(s)


class PoolCoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = s.connect(str(pathlib.Path(self.tmp.name) / 'pools.sqlite3'))

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def test_create_add_dedupe_claim_scrub_and_remove(self):
        created = s.create_pool(self.db, 1000, pool_id='363636', label='Team Pool')
        self.assertEqual(created['poolId'], '363636')
        auth = created['auth']
        self.assertTrue(created['coordinationUrl'].endswith(f'/363636#auth={auth}'))

        # Verify plaintext room URL never appears in SQLite file
        links = [
            'https://jazz.sber.ru/calls/room-1?psw=secret1',
            'https://jazz.sber.ru/calls/room-1?psw=secret1#frag',  # duplicate modulo fragment
            'https://jazz.corp.ru:443/calls/room-2?psw=secret2',
            'https://rock.glowsoft.ru/jams/test',  # invalid: self host
            'http://jazz.sber.ru/calls/insecure',  # invalid: http
            'https://127.0.0.1/calls/local',  # invalid: IP
            'https://jazz.sber.ru/',  # invalid: no room path
        ]
        added = s.add_links(self.db, '363636', auth, links, 1001)
        self.assertEqual(added, {'added': 2, 'skippedDuplicates': 1, 'invalid': 4, 'availableCount': 2})

        # Ensure zero plaintext URLs stored on disk
        rows = self.db.execute('SELECT status, nonce, ciphertext FROM pool_links').fetchall()
        self.assertEqual(len(rows), 2)
        for status, nonce, ciphertext in rows:
            self.assertEqual(status, 'available')
            self.assertIsNotNone(nonce)
            self.assertNotIn(b'room-1', ciphertext)
            self.assertNotIn(b'secret1', ciphertext)
            self.assertNotIn(b'jazz.sber.ru', ciphertext)

        # Status aggregates multi-origin counts without exposing raw links
        status = s.get_status(self.db, '363636', auth)
        self.assertEqual(status['availableCount'], 2)
        self.assertEqual(status['usedCount'], 0)
        self.assertEqual(status['origins'], {'https://jazz.sber.ru': 1, 'https://jazz.corp.ru': 1})

        # Claim with preferredOrigin matching second link
        c1 = s.claim_room(self.db, '363636', auth, 1010, preferred_origin='https://jazz.corp.ru', request_id='req-1')
        self.assertEqual(c1['roomUrl'], 'https://jazz.corp.ru/calls/room-2?psw=secret2')
        self.assertEqual(c1['origin'], 'https://jazz.corp.ru')
        self.assertEqual(c1['remainingCount'], 1)
        self.assertNotIn('replayed', c1)

        # Idempotent replay within 300s returns same link without consuming room-1
        c1_replay = s.claim_room(self.db, '363636', auth, 1100, preferred_origin='https://jazz.corp.ru', request_id='req-1')
        self.assertEqual(c1_replay['roomUrl'], c1['roomUrl'])
        self.assertTrue(c1_replay['replayed'])
        self.assertEqual(c1_replay['remainingCount'], 1)

        # Claiming with unmatched preferredOrigin falls back to remaining link on jazz.sber.ru
        c2 = s.claim_room(self.db, '363636', auth, 1400, preferred_origin='https://other.jazz.ru', request_id='req-2')
        self.assertEqual(c2['roomUrl'], 'https://jazz.sber.ru/calls/room-1?psw=secret1')
        self.assertEqual(c2['remainingCount'], 0)

        # Row from t=1010 (>300s before t=1400) has had its ciphertext scrubbed while keeping tombstone
        scrubbed = self.db.execute(
            "SELECT nonce, ciphertext, claim_request_id FROM pool_links WHERE status='used' ORDER BY id DESC LIMIT 1"
        ).fetchone()
        self.assertEqual(scrubbed, (None, None, None))

        # Re-adding already used links is skipped via tombstones
        readd = s.add_links(self.db, '363636', auth, ['https://jazz.sber.ru/calls/room-1?psw=secret1'], 1405)
        self.assertEqual(readd, {'added': 0, 'skippedDuplicates': 1, 'invalid': 0, 'availableCount': 0})

        # Empty pool raises 409
        with self.assertRaises(s.PoolError) as err:
            s.claim_room(self.db, '363636', auth, 1410)
        self.assertEqual(err.exception.status, 409)

        # Add 2 more, list, remove one by id, then re-add the removed unused link (tombstone only applies to used!)
        s.add_links(self.db, '363636', auth, ['https://a.example.com/r/1', 'https://a.example.com/r/2'], 1500)
        listed = s.list_links(self.db, '363636', auth)
        self.assertEqual(len(listed['links']), 2)
        first_id = listed['links'][0]['id']
        removed = s.remove_links(self.db, '363636', auth, ids=[first_id], now=1505)
        self.assertEqual(removed, {'removed': 1, 'availableCount': 1})
        readd_unused = s.add_links(self.db, '363636', auth, ['https://a.example.com/r/1'], 1510)
        self.assertEqual(readd_unused['added'], 1)
        cleared = s.remove_links(self.db, '363636', auth, clear_available=True, now=1515)
        self.assertEqual(cleared, {'removed': 2, 'availableCount': 0})


class PoolHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = str(pathlib.Path(self.tmp.name) / 'http_pools.sqlite3')
        self.write_token = 'super-secret-write-token-123'
        self.server = s.make_server(self.db_path, '127.0.0.1:0', self.write_token)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.server.db.close()
        self.tmp.cleanup()

    def _req(self, method, path, body=None, auth=None, write_token=None, ip='198.51.100.10', extra_headers=None):
        headers = {'X-Real-IP': ip, 'Accept': 'application/json'}
        if auth is not None:
            headers['Authorization'] = f'Bearer {auth}'
        if write_token is not None:
            headers['X-Pool-Write-Token'] = write_token
        if extra_headers:
            headers.update(extra_headers)
        data = None
        if body is not None:
            headers['Content-Type'] = 'application/json'
            data = json.dumps(body).encode('utf-8')
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as resp:
                return resp.status, json.loads(resp.read().decode('utf-8'))
        except urllib.error.HTTPError as err:
            try:
                return err.code, json.loads(err.read().decode('utf-8'))
            finally:
                err.close()

    def test_write_token_enforcement_and_claim_flow(self):
        # Create pool without write token -> 401
        code, _ = self._req('POST', '/api/pools', body={'poolId': 'team1'})
        self.assertEqual(code, 401)
        # Wrong write token -> 403
        code, _ = self._req('POST', '/api/pools', body={'poolId': 'team1'}, write_token='wrong')
        self.assertEqual(code, 403)
        # Valid write token -> 201
        code, created = self._req('POST', '/api/pools', body={'poolId': 'team1', 'label': 'Jazz'}, write_token=self.write_token)
        self.assertEqual(code, 201)
        auth = created['auth']

        # Add links without write token -> 401
        code, _ = self._req('POST', '/api/pools/team1/links', body={'links': ['https://jazz.sber.ru/calls/1']}, auth=auth)
        self.assertEqual(code, 401)
        # Add links with write token -> 200
        code, added = self._req(
            'POST',
            '/api/pools/team1/links',
            body={'links': ['https://jazz.sber.ru/calls/1', 'https://jazz.sber.ru/calls/2']},
            auth=auth,
            write_token=self.write_token,
        )
        self.assertEqual(code, 200)
        self.assertEqual(added['added'], 2)

        # List links requires write token
        code, _ = self._req('GET', '/api/pools/team1/links', auth=auth)
        self.assertEqual(code, 401)
        code, listed = self._req('GET', '/api/pools/team1/links', auth=auth, write_token=self.write_token)
        self.assertEqual(code, 200)
        self.assertEqual(len(listed['links']), 2)

        # Status & Claim DO NOT require write token
        code, status = self._req('GET', '/api/pools/team1', auth=auth)
        self.assertEqual(code, 200)
        self.assertEqual(status['availableCount'], 2)

        code, claimed = self._req('POST', '/api/pools/team1/claim', body={'requestId': 'r1'}, auth=auth)
        self.assertEqual(code, 200)
        self.assertEqual(claimed['roomUrl'], 'https://jazz.sber.ru/calls/1')
        self.assertEqual(claimed['remainingCount'], 1)

        # Remove remaining link requires write token
        code, _ = self._req('POST', '/api/pools/team1/links/remove', body={'clearAvailable': True}, auth=auth)
        self.assertEqual(code, 401)
        code, removed = self._req(
            'POST',
            '/api/pools/team1/links/remove',
            body={'clearAvailable': True},
            auth=auth,
            write_token=self.write_token,
        )
        self.assertEqual(code, 200)
        self.assertEqual(removed['removed'], 1)

    def test_auth_failure_rate_limit(self):
        for i in range(s.IP_AUTH_FAIL_LIMIT):
            code, _ = self._req('GET', '/api/pools/nonexistent', auth='abcd1234', ip='198.51.100.99')
            self.assertEqual(code, 401, f'attempt {i}')
        code, _ = self._req('GET', '/api/pools/nonexistent', auth='abcd1234', ip='198.51.100.99')
        self.assertEqual(code, 429)

    def test_get_action_envelope_and_plain_get_claim_blocked(self):
        import base64

        def b64u(obj):
            return base64.urlsafe_b64encode(json.dumps(obj).encode('utf-8')).decode('ascii').rstrip('=')

        code, created = self._req(
            'GET',
            '/api/pools?rid=1',
            write_token=self.write_token,
            extra_headers={'X-Pool-Action': 'create', 'X-Pool-Payload': b64u({'poolId': 'getpool1', 'label': 'CDN'})},
        )
        self.assertEqual(code, 201)
        auth = created['auth']

        code, added = self._req(
            'GET',
            '/api/pools/getpool1/links?rid=2',
            auth=auth,
            write_token=self.write_token,
            extra_headers={'X-Pool-Action': 'add_links', 'X-Pool-Payload': b64u({'links': ['https://jazz.sber.ru/calls/g1']})},
        )
        self.assertEqual(code, 200)
        self.assertEqual(added['availableCount'], 1)

        # Plain GET /claim without X-Pool-Action must still return 404
        code, _ = self._req('GET', '/api/pools/getpool1/claim', auth=auth)
        self.assertEqual(code, 404)

        code, claimed = self._req(
            'GET',
            '/api/pools/getpool1/claim?rid=3',
            auth=auth,
            extra_headers={'X-Pool-Action': 'claim', 'X-Pool-Payload': b64u({'requestId': 'get-claim-1'})},
        )
        self.assertEqual(code, 200)
        self.assertEqual(claimed['roomUrl'], 'https://jazz.sber.ru/calls/g1')
        self.assertEqual(claimed['remainingCount'], 0)

        code, removed = self._req(
            'GET',
            '/api/pools/getpool1/links/remove?rid=4',
            auth=auth,
            write_token=self.write_token,
            extra_headers={'X-Pool-Action': 'remove_links', 'X-Pool-Payload': b64u({'clearAvailable': True})},
        )
        self.assertEqual(code, 200)
        self.assertEqual(removed['removed'], 0)


if __name__ == '__main__':
    unittest.main()

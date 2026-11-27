#!/usr/bin/env python3
"""Zero-plaintext encrypted room coordination pool service for rock.glowsoft.ru."""
import argparse
import base64
import binascii
import collections
import hmac
import ipaddress
import json
import os
import re
import secrets
import sqlite3
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

DB_DEFAULT = '/var/lib/rock-room-pools/pools.sqlite3'
LISTEN_DEFAULT = '127.0.0.1:18793'
COORD_BASE_URL = 'https://rock.glowsoft.ru/pools'

POOL_ID_RE = re.compile(r'^[a-z0-9_-]{4,24}$')
AUTH_TOKEN_RE = re.compile(r'^[A-Za-z0-9_-]{4,256}$')
REQUEST_ID_RE = re.compile(r'^[A-Za-z0-9._-]{1,64}$')
DNS_LABEL_RE = re.compile(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$')
BASE62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'

MAX_POOLS = 5000
MAX_AVAILABLE_LINKS_PER_POOL = 500
MAX_USED_TOMBSTONES_PER_POOL = 2000
MAX_BATCH_LINKS = 200
MAX_URL_LENGTH = 512
REPLAY_WINDOW_SECONDS = 300

GLOBAL_RATE_LIMIT = 180
IP_RATE_LIMIT = 30
IP_AUTH_FAIL_LIMIT = 8
RATE_WINDOW_SECONDS = 60


class PoolError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def connect(path):
    db = sqlite3.connect(path, timeout=5, isolation_level=None, check_same_thread=False)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA max_page_count=16384')
    init(db)
    return db


def init(db):
    db.execute('BEGIN IMMEDIATE')
    try:
        db.execute(
            '''CREATE TABLE IF NOT EXISTS pools (
                pool_id TEXT PRIMARY KEY,
                label TEXT NOT NULL DEFAULT '',
                salt BLOB NOT NULL,
                auth_verifier BLOB NOT NULL,
                write_verifier BLOB,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                used_count INTEGER NOT NULL DEFAULT 0
            )'''
        )
        cols = {row[1] for row in db.execute('PRAGMA table_info(pools)').fetchall()}
        if 'write_verifier' not in cols:
            db.execute('ALTER TABLE pools ADD COLUMN write_verifier BLOB')
        db.execute(
            '''CREATE TABLE IF NOT EXISTS pool_links (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pool_id TEXT NOT NULL,
                url_hash BLOB NOT NULL,
                origin_hash BLOB NOT NULL,
                status TEXT NOT NULL,
                nonce BLOB,
                ciphertext BLOB,
                added_at INTEGER NOT NULL,
                claimed_at INTEGER,
                claim_request_id TEXT,
                UNIQUE(pool_id, url_hash)
            )'''
        )
        db.execute('CREATE INDEX IF NOT EXISTS idx_pool_links_lookup ON pool_links(pool_id, status, id)')
        db.commit()
    except Exception:
        db.rollback()
        raise


def _generate_pool_id(db):
    for _ in range(32):
        candidate = str(secrets.randbelow(900000) + 100000)
        if not db.execute('SELECT 1 FROM pools WHERE pool_id=?', (candidate,)).fetchone():
            return candidate
    return secrets.token_hex(4)


def _generate_auth_token():
    return ''.join(secrets.choice(BASE62) for _ in range(22))


def _auth_verifier(salt, auth_token):
    return hmac.digest(salt, b'verify:' + auth_token.encode('ascii'), 'sha256')


def _write_verifier(salt, write_token):
    return hmac.digest(salt, b'write:' + write_token.encode('utf-8'), 'sha256')


def _derive_key(salt, auth_token):
    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        info=b'rock-pool-v1',
    ).derive(auth_token.encode('ascii'))


def _url_hash(salt, canonical_url):
    return hmac.digest(salt, b'url:' + canonical_url.encode('utf-8'), 'sha256')


def _origin_hash(salt, canonical_origin):
    return hmac.digest(salt, b'origin:' + canonical_origin.encode('utf-8'), 'sha256')


def _encrypt_payload(enc_key, pool_id, canonical_url, canonical_origin):
    nonce = secrets.token_bytes(12)
    payload = json.dumps({'url': canonical_url, 'origin': canonical_origin}, separators=(',', ':')).encode('utf-8')
    ciphertext = AESGCM(enc_key).encrypt(nonce, payload, pool_id.encode('ascii'))
    return nonce, ciphertext


def _decrypt_payload(enc_key, pool_id, nonce, ciphertext):
    try:
        raw = AESGCM(enc_key).decrypt(nonce, ciphertext, pool_id.encode('ascii'))
        return json.loads(raw.decode('utf-8'))
    except (InvalidTag, ValueError, TypeError, UnicodeDecodeError) as exc:
        raise PoolError(401, 'invalid_auth', 'Invalid pool ID or auth token.') from exc


def normalize_origin(raw_origin):
    if not isinstance(raw_origin, str):
        return None
    text = raw_origin.strip()
    if not text or len(text) > MAX_URL_LENGTH or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in text):
        return None
    try:
        parts = urllib.parse.urlsplit(text)
    except ValueError:
        return None
    if parts.scheme.lower() != 'https' or parts.username is not None or parts.password is not None:
        return None
    host = (parts.hostname or '').strip('.').lower()
    if not _is_valid_public_host(host):
        return None
    try:
        port = parts.port
    except ValueError:
        return None
    if port is not None and not (1 <= port <= 65535):
        return None
    host_port = host if (port is None or port == 443) else f'{host}:{port}'
    return f'https://{host_port}'


def _is_valid_public_host(host):
    if not host or len(host) > 253 or '.' not in host or host == 'localhost' or host == 'rock.glowsoft.ru':
        return False
    try:
        ipaddress.ip_address(host)
        return False
    except ValueError:
        pass
    labels = host.split('.')
    if len(labels) < 2:
        return False
    return all(DNS_LABEL_RE.fullmatch(label) for label in labels)


def validate_guest_url(raw_url):
    if not isinstance(raw_url, str):
        return None
    text = raw_url.strip()
    if not text or len(text) > MAX_URL_LENGTH or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in text):
        return None
    try:
        parts = urllib.parse.urlsplit(text)
    except ValueError:
        return None
    if parts.scheme.lower() != 'https' or parts.username is not None or parts.password is not None:
        return None
    host = (parts.hostname or '').strip('.').lower()
    if not _is_valid_public_host(host):
        return None
    try:
        port = parts.port
    except ValueError:
        return None
    if port is not None and not (1 <= port <= 65535):
        return None
    segments = [seg for seg in parts.path.split('/') if seg]
    if not segments or any(seg in ('.', '..') for seg in segments):
        return None
    host_port = host if (port is None or port == 443) else f'{host}:{port}'
    canonical_origin = f'https://{host_port}'
    canonical_url = urllib.parse.urlunsplit(('https', host_port, parts.path, parts.query, ''))
    return canonical_url, canonical_origin


def _verify_pool_auth(db, pool_id, auth_token):
    if not isinstance(pool_id, str):
        raise PoolError(401, 'invalid_auth', 'Invalid pool ID or auth token.')
    pool_id = pool_id.strip().lower()
    if not POOL_ID_RE.fullmatch(pool_id):
        raise PoolError(401, 'invalid_auth', 'Invalid pool ID or auth token.')
    if not isinstance(auth_token, str) or not AUTH_TOKEN_RE.fullmatch(auth_token):
        raise PoolError(401, 'invalid_auth', 'Invalid pool ID or auth token.')
    row = db.execute(
        'SELECT label, salt, auth_verifier, write_verifier, used_count FROM pools WHERE pool_id=?',
        (pool_id,),
    ).fetchone()
    if not row:
        raise PoolError(401, 'invalid_auth', 'Invalid pool ID or auth token.')
    label, salt, stored_verifier, write_verifier, used_count = row
    expected_verifier = _auth_verifier(salt, auth_token)
    if not hmac.compare_digest(stored_verifier, expected_verifier):
        raise PoolError(401, 'invalid_auth', 'Invalid pool ID or auth token.')
    enc_key = _derive_key(salt, auth_token)
    return {
        'pool_id': pool_id,
        'label': label,
        'salt': salt,
        'write_verifier': write_verifier,
        'used_count': used_count,
        'enc_key': enc_key,
    }


def _scrub_and_trim_used(db, pool_id, now):
    cutoff = now - REPLAY_WINDOW_SECONDS
    db.execute(
        '''UPDATE pool_links
           SET nonce=NULL, ciphertext=NULL, claim_request_id=NULL
           WHERE pool_id=? AND status='used' AND claimed_at<=? AND (nonce IS NOT NULL OR ciphertext IS NOT NULL OR claim_request_id IS NOT NULL)''',
        (pool_id, cutoff),
    )
    db.execute(
        '''DELETE FROM pool_links
           WHERE id IN (
               SELECT id FROM pool_links
               WHERE pool_id=? AND status='used'
               ORDER BY claimed_at DESC, id DESC
               LIMIT -1 OFFSET ?
           )''',
        (pool_id, MAX_USED_TOMBSTONES_PER_POOL),
    )


def create_pool(db, now, pool_id=None, label=''):
    if pool_id is not None:
        if not isinstance(pool_id, str):
            raise PoolError(400, 'invalid_pool_id', 'Pool ID must be 4-24 lowercase letters, digits, _ or -.')
        pool_id = pool_id.strip().lower()
        if not POOL_ID_RE.fullmatch(pool_id):
            raise PoolError(400, 'invalid_pool_id', 'Pool ID must be 4-24 lowercase letters, digits, _ or -.')
    if label is None:
        label = ''
    if not isinstance(label, str):
        raise PoolError(400, 'invalid_label', 'Label must be a string.')
    label = label.strip()
    if len(label) > 80 or any(ord(c) < 32 or ord(c) == 127 for c in label):
        raise PoolError(400, 'invalid_label', 'Label must be at most 80 characters.')

    db.execute('BEGIN IMMEDIATE')
    try:
        total = db.execute('SELECT count(*) FROM pools').fetchone()[0]
        if total >= MAX_POOLS:
            raise PoolError(503, 'capacity', 'Pool capacity reached.')
        if pool_id is None:
            pool_id = _generate_pool_id(db)
        elif db.execute('SELECT 1 FROM pools WHERE pool_id=?', (pool_id,)).fetchone():
            raise PoolError(409, 'pool_exists', 'This pool ID already exists.')

        auth = _generate_auth_token()
        write_token = _generate_auth_token()
        salt = secrets.token_bytes(16)
        verifier = _auth_verifier(salt, auth)
        w_verifier = _write_verifier(salt, write_token)
        db.execute(
            'INSERT INTO pools(pool_id, label, salt, auth_verifier, write_verifier, created_at, updated_at, used_count) VALUES(?,?,?,?,?,?,?,0)',
            (pool_id, label, salt, verifier, w_verifier, now, now),
        )
        db.commit()
        return {
            'poolId': pool_id,
            'auth': auth,
            'writeToken': write_token,
            'label': label,
            'coordinationUrl': f'{COORD_BASE_URL}/{pool_id}#auth={auth}',
            'manageUrl': f'{COORD_BASE_URL}/{pool_id}#auth={auth}&write={write_token}',
        }
    except Exception:
        db.rollback()
        raise


def get_status(db, pool_id, auth_token):
    ctx = _verify_pool_auth(db, pool_id, auth_token)
    pool_id = ctx['pool_id']
    rows = db.execute(
        "SELECT nonce, ciphertext FROM pool_links WHERE pool_id=? AND status='available' ORDER BY id ASC",
        (pool_id,),
    ).fetchall()
    origins = {}
    for nonce, ciphertext in rows:
        payload = _decrypt_payload(ctx['enc_key'], pool_id, nonce, ciphertext)
        origin = payload['origin']
        origins[origin] = origins.get(origin, 0) + 1
    return {
        'poolId': pool_id,
        'label': ctx['label'],
        'availableCount': len(rows),
        'usedCount': ctx['used_count'],
        'origins': origins,
    }


def list_links(db, pool_id, auth_token):
    ctx = _verify_pool_auth(db, pool_id, auth_token)
    pool_id = ctx['pool_id']
    rows = db.execute(
        "SELECT id, nonce, ciphertext, added_at FROM pool_links WHERE pool_id=? AND status='available' ORDER BY id ASC",
        (pool_id,),
    ).fetchall()
    links = []
    for row_id, nonce, ciphertext, added_at in rows:
        payload = _decrypt_payload(ctx['enc_key'], pool_id, nonce, ciphertext)
        links.append({
            'id': row_id,
            'url': payload['url'],
            'origin': payload['origin'],
            'addedAt': added_at,
        })
    return {
        'poolId': pool_id,
        'availableCount': len(links),
        'usedCount': ctx['used_count'],
        'links': links,
    }


def add_links(db, pool_id, auth_token, raw_links, now):
    ctx = _verify_pool_auth(db, pool_id, auth_token)
    pool_id = ctx['pool_id']
    if not isinstance(raw_links, list) or not (1 <= len(raw_links) <= MAX_BATCH_LINKS):
        raise PoolError(400, 'invalid_links', f'Provide between 1 and {MAX_BATCH_LINKS} links.')

    parsed_candidates = []
    invalid_count = 0
    seen_hashes = set()
    duplicate_in_batch = 0
    for item in raw_links:
        validated = validate_guest_url(item)
        if not validated:
            invalid_count += 1
            continue
        canonical_url, canonical_origin = validated
        u_hash = _url_hash(ctx['salt'], canonical_url)
        if u_hash in seen_hashes:
            duplicate_in_batch += 1
            continue
        seen_hashes.add(u_hash)
        o_hash = _origin_hash(ctx['salt'], canonical_origin)
        parsed_candidates.append((canonical_url, canonical_origin, u_hash, o_hash))

    db.execute('BEGIN IMMEDIATE')
    try:
        # Re-verify inside write lock
        _verify_pool_auth(db, pool_id, auth_token)
        current_available = db.execute(
            "SELECT count(*) FROM pool_links WHERE pool_id=? AND status='available'",
            (pool_id,),
        ).fetchone()[0]
        added = 0
        skipped_duplicates = duplicate_in_batch
        for canonical_url, canonical_origin, u_hash, o_hash in parsed_candidates:
            if db.execute('SELECT 1 FROM pool_links WHERE pool_id=? AND url_hash=?', (pool_id, u_hash)).fetchone():
                skipped_duplicates += 1
                continue
            if current_available >= MAX_AVAILABLE_LINKS_PER_POOL:
                raise PoolError(409, 'pool_full', f'Pool limit of {MAX_AVAILABLE_LINKS_PER_POOL} unused links reached.')
            nonce, ciphertext = _encrypt_payload(ctx['enc_key'], pool_id, canonical_url, canonical_origin)
            db.execute(
                '''INSERT INTO pool_links(pool_id, url_hash, origin_hash, status, nonce, ciphertext, added_at)
                   VALUES(?,?,?,'available',?,?,?)''',
                (pool_id, u_hash, o_hash, nonce, ciphertext, now),
            )
            added += 1
            current_available += 1
        if added > 0:
            db.execute('UPDATE pools SET updated_at=? WHERE pool_id=?', (now, pool_id))
        db.commit()
        return {
            'added': added,
            'skippedDuplicates': skipped_duplicates,
            'invalid': invalid_count,
            'availableCount': current_available,
        }
    except Exception:
        db.rollback()
        raise


def remove_links(db, pool_id, auth_token, ids=None, links=None, clear_available=False, now=0):
    ctx = _verify_pool_auth(db, pool_id, auth_token)
    pool_id = ctx['pool_id']
    if ids is not None and not isinstance(ids, list):
        raise PoolError(400, 'invalid_request', 'ids must be an array of integers.')
    if links is not None and not isinstance(links, list):
        raise PoolError(400, 'invalid_request', 'links must be an array of strings.')
    if not isinstance(clear_available, bool):
        raise PoolError(400, 'invalid_request', 'clearAvailable must be a boolean.')

    clean_ids = []
    for item in (ids or []):
        if type(item) is not int or item <= 0:
            raise PoolError(400, 'invalid_request', 'ids must contain positive integers.')
        clean_ids.append(item)

    link_hashes = []
    for item in (links or []):
        validated = validate_guest_url(item)
        if validated:
            link_hashes.append(_url_hash(ctx['salt'], validated[0]))

    if not clear_available and not clean_ids and not link_hashes:
        raise PoolError(400, 'invalid_request', 'Specify ids, links, or clearAvailable.')

    db.execute('BEGIN IMMEDIATE')
    try:
        _verify_pool_auth(db, pool_id, auth_token)
        removed = 0
        if clear_available:
            cur = db.execute("DELETE FROM pool_links WHERE pool_id=? AND status='available'", (pool_id,))
            removed += cur.rowcount
        else:
            for row_id in clean_ids:
                cur = db.execute(
                    "DELETE FROM pool_links WHERE pool_id=? AND id=? AND status='available'",
                    (pool_id, row_id),
                )
                removed += cur.rowcount
            for u_hash in link_hashes:
                cur = db.execute(
                    "DELETE FROM pool_links WHERE pool_id=? AND url_hash=? AND status='available'",
                    (pool_id, u_hash),
                )
                removed += cur.rowcount
        if removed > 0:
            db.execute('UPDATE pools SET updated_at=? WHERE pool_id=?', (now, pool_id))
        remaining = db.execute(
            "SELECT count(*) FROM pool_links WHERE pool_id=? AND status='available'",
            (pool_id,),
        ).fetchone()[0]
        db.commit()
        return {
            'removed': removed,
            'availableCount': remaining,
        }
    except Exception:
        db.rollback()
        raise


def claim_room(db, pool_id, auth_token, now, preferred_origin=None, request_id=None):
    ctx = _verify_pool_auth(db, pool_id, auth_token)
    pool_id = ctx['pool_id']
    if request_id is not None:
        if not isinstance(request_id, str) or not REQUEST_ID_RE.fullmatch(request_id):
            raise PoolError(400, 'invalid_request_id', 'Invalid requestId format.')
    pref_hash = None
    if preferred_origin is not None and preferred_origin != '':
        norm_origin = normalize_origin(preferred_origin)
        if norm_origin:
            pref_hash = _origin_hash(ctx['salt'], norm_origin)

    db.execute('BEGIN IMMEDIATE')
    try:
        _verify_pool_auth(db, pool_id, auth_token)
        _scrub_and_trim_used(db, pool_id, now)

        if request_id:
            replay = db.execute(
                '''SELECT nonce, ciphertext FROM pool_links
                   WHERE pool_id=? AND status='used' AND claim_request_id=? AND claimed_at>? AND ciphertext IS NOT NULL
                   ORDER BY id DESC LIMIT 1''',
                (pool_id, request_id, now - REPLAY_WINDOW_SECONDS),
            ).fetchone()
            if replay:
                payload = _decrypt_payload(ctx['enc_key'], pool_id, replay[0], replay[1])
                remaining = db.execute(
                    "SELECT count(*) FROM pool_links WHERE pool_id=? AND status='available'",
                    (pool_id,),
                ).fetchone()[0]
                db.commit()
                return {
                    'poolId': pool_id,
                    'roomUrl': payload['url'],
                    'origin': payload['origin'],
                    'remainingCount': remaining,
                    'replayed': True,
                }

        if pref_hash is not None:
            row = db.execute(
                '''SELECT id, nonce, ciphertext FROM pool_links
                   WHERE pool_id=? AND status='available'
                   ORDER BY (origin_hash = ?) DESC, id ASC
                   LIMIT 1''',
                (pool_id, pref_hash),
            ).fetchone()
        else:
            row = db.execute(
                '''SELECT id, nonce, ciphertext FROM pool_links
                   WHERE pool_id=? AND status='available'
                   ORDER BY id ASC
                   LIMIT 1''',
                (pool_id,),
            ).fetchone()

        if not row:
            db.commit()
            raise PoolError(409, 'pool_empty', 'No unused rooms left in this pool.')

        row_id, nonce, ciphertext = row
        payload = _decrypt_payload(ctx['enc_key'], pool_id, nonce, ciphertext)
        db.execute(
            "UPDATE pool_links SET status='used', claimed_at=?, claim_request_id=? WHERE id=?",
            (now, request_id, row_id),
        )
        db.execute('UPDATE pools SET used_count=used_count+1, updated_at=? WHERE pool_id=?', (now, pool_id))
        remaining = db.execute(
            "SELECT count(*) FROM pool_links WHERE pool_id=? AND status='available'",
            (pool_id,),
        ).fetchone()[0]
        db.commit()
        return {
            'poolId': pool_id,
            'roomUrl': payload['url'],
            'origin': payload['origin'],
            'remainingCount': remaining,
        }
    except Exception:
        db.rollback()
        raise


class Handler(BaseHTTPRequestHandler):
    server_version = ''
    sys_version = ''

    def log_message(self, *args):
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def reply(self, status, obj):
        data = json.dumps(obj, separators=(',', ':')).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store, no-cache, private')
        self.send_header('Vary', 'Authorization, X-Pool-Write-Token, X-Pool-Action, X-Pool-Payload')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _check_rate_limit(self, ip, is_auth_failure=False):
        now = time.time()
        with self.server.lock:
            cutoff = now - RATE_WINDOW_SECONDS
            if is_auth_failure:
                fails = self.server.auth_failures
                while fails and fails[0][0] <= cutoff:
                    fails.popleft()
                if sum(1 for ts, fail_ip in fails if fail_ip == ip) >= IP_AUTH_FAIL_LIMIT:
                    return False
                fails.append((now, ip))
                return True

            rates = self.server.rates
            while rates and rates[0][0] <= cutoff:
                rates.popleft()
            if len(rates) >= GLOBAL_RATE_LIMIT or sum(1 for ts, req_ip in rates if req_ip == ip) >= IP_RATE_LIMIT:
                return False
            rates.append((now, ip))
            return True

    def _is_auth_failure_blocked(self, ip):
        now = time.time()
        cutoff = now - RATE_WINDOW_SECONDS
        with self.server.lock:
            fails = self.server.auth_failures
            while fails and fails[0][0] <= cutoff:
                fails.popleft()
            return sum(1 for _, fail_ip in fails if fail_ip == ip) >= IP_AUTH_FAIL_LIMIT

    def _client_ip(self):
        ip = self.headers.get('X-Real-IP', '').strip()
        if not ip or len(ip) > 64:
            raise PoolError(400, 'bad_request', 'Missing client IP.')
        return ip

    def _require_write_token(self, ip):
        expected = self.server.write_token
        provided = self.headers.get('X-Pool-Write-Token', '').strip()
        if not provided:
            self._check_rate_limit(ip, is_auth_failure=True)
            raise PoolError(401, 'write_token_required', 'Write password is required.')
        if not hmac.compare_digest(provided.encode('utf-8'), expected.encode('utf-8')):
            self._check_rate_limit(ip, is_auth_failure=True)
            raise PoolError(403, 'invalid_write_token', 'Invalid write password.')

    def _require_pool_write_access(self, ip, pool_id, auth_token):
        provided = self.headers.get('X-Pool-Write-Token', '').strip()
        if not provided:
            self._check_rate_limit(ip, is_auth_failure=True)
            raise PoolError(401, 'write_token_required', 'Write password is required.')
        try:
            with self.server.lock:
                ctx = _verify_pool_auth(self.server.db, pool_id, auth_token)
        except PoolError as err:
            if err.status == 401:
                self._check_rate_limit(ip, is_auth_failure=True)
            raise
        if hmac.compare_digest(provided.encode('utf-8'), self.server.write_token.encode('utf-8')):
            return
        w_verifier = ctx.get('write_verifier')
        if w_verifier is not None and hmac.compare_digest(w_verifier, _write_verifier(ctx['salt'], provided)):
            return
        self._check_rate_limit(ip, is_auth_failure=True)
        raise PoolError(403, 'invalid_write_token', 'Invalid write password.')

    def _bearer_token(self, ip):
        raw = self.headers.get('Authorization', '').strip()
        if not raw.lower().startswith('bearer '):
            self._check_rate_limit(ip, is_auth_failure=True)
            raise PoolError(401, 'auth_required', 'Pool auth token is required.')
        token = raw[7:].strip()
        if not token:
            self._check_rate_limit(ip, is_auth_failure=True)
            raise PoolError(401, 'auth_required', 'Pool auth token is required.')
        return token

    def _read_json_body(self, optional=False):
        if self.headers.get('Transfer-Encoding'):
            raise PoolError(400, 'bad_request', 'Chunked encoding is not supported.')
        raw_len = self.headers.get('Content-Length', '')
        if not raw_len:
            if optional:
                return {}
            raise PoolError(400, 'bad_request', 'Missing Content-Length.')
        try:
            length = int(raw_len)
        except ValueError as exc:
            raise PoolError(400, 'bad_request', 'Invalid Content-Length.') from exc
        if length == 0 and optional:
            return {}
        if not (1 <= length <= 65536):
            raise PoolError(400, 'bad_request', 'Request body too large.')
        ctype = self.headers.get('Content-Type', '').split(';')[0].strip().lower()
        if ctype != 'application/json':
            raise PoolError(400, 'bad_request', 'Send application/json.')
        try:
            parsed = json.loads(self.rfile.read(length).decode('utf-8'))
        except (ValueError, UnicodeDecodeError) as exc:
            raise PoolError(400, 'bad_request', 'Invalid JSON body.') from exc
        if not isinstance(parsed, dict):
            raise PoolError(400, 'bad_request', 'JSON body must be an object.')
        return parsed

    def _read_action_payload(self):
        encoded = self.headers.get('X-Pool-Payload', '').strip()
        if not encoded:
            return {}
        if len(encoded) > 6144:
            raise PoolError(400, 'bad_request', 'Action payload too large.')
        padded = encoded.replace('-', '+').replace('_', '/')
        padded += '=' * ((4 - len(padded) % 4) % 4)
        try:
            raw = base64.b64decode(padded, validate=True)
            parsed = json.loads(raw.decode('utf-8'))
        except (binascii.Error, ValueError, UnicodeDecodeError) as exc:
            raise PoolError(400, 'bad_request', 'Invalid X-Pool-Payload.') from exc
        if not isinstance(parsed, dict):
            raise PoolError(400, 'bad_request', 'Action payload must be a JSON object.')
        return parsed

    def _handle_request(self, method):
        path = urllib.parse.urlsplit(self.path).path
        if method == 'GET' and path == '/healthz':
            body = b'ok\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        try:
            ip = self._client_ip()
            if self._is_auth_failure_blocked(ip) or not self._check_rate_limit(ip, is_auth_failure=False):
                return self.reply(429, {'error': 'rate_limited', 'message': 'Too many requests. Try again shortly.'})

            parts = [p for p in path.split('/') if p]
            now = int(time.time())
            action = self.headers.get('X-Pool-Action', '').strip().lower() if method == 'GET' else ''

            # POST /api/pools (or GET with X-Pool-Action: create)
            if (method == 'POST' or action == 'create') and parts == ['api', 'pools']:
                self._require_write_token(ip)
                body = self._read_action_payload() if action == 'create' else self._read_json_body(optional=True)
                with self.server.lock:
                    result = create_pool(
                        self.server.db,
                        now,
                        pool_id=body.get('poolId'),
                        label=body.get('label', ''),
                    )
                return self.reply(201, result)

            if len(parts) >= 3 and parts[:2] == ['api', 'pools']:
                pool_id = parts[2].strip().lower()

                # GET /api/pools/<id>
                if method == 'GET' and not action and len(parts) == 3:
                    auth = self._bearer_token(ip)
                    try:
                        with self.server.lock:
                            result = get_status(self.server.db, pool_id, auth)
                        return self.reply(200, result)
                    except PoolError as err:
                        if err.status == 401:
                            self._check_rate_limit(ip, is_auth_failure=True)
                        raise

                # POST /api/pools/<id>/claim (or GET with X-Pool-Action: claim)
                if (method == 'POST' or action == 'claim') and len(parts) == 4 and parts[3] == 'claim':
                    auth = self._bearer_token(ip)
                    body = self._read_action_payload() if action == 'claim' else self._read_json_body(optional=True)
                    try:
                        with self.server.lock:
                            result = claim_room(
                                self.server.db,
                                pool_id,
                                auth,
                                now,
                                preferred_origin=body.get('preferredOrigin'),
                                request_id=body.get('requestId'),
                            )
                        return self.reply(200, result)
                    except PoolError as err:
                        if err.status == 401:
                            self._check_rate_limit(ip, is_auth_failure=True)
                        raise

                # GET /api/pools/<id>/links (plain GET without action lists queued links)
                if method == 'GET' and not action and len(parts) == 4 and parts[3] == 'links':
                    auth = self._bearer_token(ip)
                    self._require_pool_write_access(ip, pool_id, auth)
                    try:
                        with self.server.lock:
                            result = list_links(self.server.db, pool_id, auth)
                        return self.reply(200, result)
                    except PoolError as err:
                        if err.status == 401:
                            self._check_rate_limit(ip, is_auth_failure=True)
                        raise

                # POST /api/pools/<id>/links (or GET with X-Pool-Action: add_links)
                if (method == 'POST' or action == 'add_links') and len(parts) == 4 and parts[3] == 'links':
                    auth = self._bearer_token(ip)
                    self._require_pool_write_access(ip, pool_id, auth)
                    body = self._read_action_payload() if action == 'add_links' else self._read_json_body(optional=False)
                    try:
                        with self.server.lock:
                            result = add_links(self.server.db, pool_id, auth, body.get('links'), now)
                        return self.reply(200, result)
                    except PoolError as err:
                        if err.status == 401:
                            self._check_rate_limit(ip, is_auth_failure=True)
                        raise

                # POST /api/pools/<id>/links/remove, DELETE /api/pools/<id>/links, or GET with X-Pool-Action: remove_links
                if (method == 'POST' and len(parts) == 5 and parts[3:5] == ['links', 'remove']) or (
                    method == 'DELETE' and len(parts) == 4 and parts[3] == 'links'
                ) or (
                    action == 'remove_links' and ((len(parts) == 5 and parts[3:5] == ['links', 'remove']) or (len(parts) == 4 and parts[3] == 'links'))
                ):
                    auth = self._bearer_token(ip)
                    self._require_pool_write_access(ip, pool_id, auth)
                    body = self._read_action_payload() if action == 'remove_links' else self._read_json_body(optional=False)
                    try:
                        with self.server.lock:
                            result = remove_links(
                                self.server.db,
                                pool_id,
                                auth,
                                ids=body.get('ids'),
                                links=body.get('links'),
                                clear_available=body.get('clearAvailable', False),
                                now=now,
                            )
                        return self.reply(200, result)
                    except PoolError as err:
                        if err.status == 401:
                            self._check_rate_limit(ip, is_auth_failure=True)
                        raise

            return self.reply(404, {'error': 'not_found', 'message': 'Endpoint not found.'})
        except PoolError as err:
            return self.reply(err.status, {'error': err.code, 'message': err.message})
        except sqlite3.Error:
            return self.reply(503, {'error': 'unavailable', 'message': 'Database unavailable.'})

    def do_GET(self):
        self._handle_request('GET')

    def do_POST(self):
        self._handle_request('POST')

    def do_DELETE(self):
        self._handle_request('DELETE')


def make_server(db_path, listen_addr, write_token):
    if not write_token or len(write_token.strip()) < 12:
        raise ValueError('POOL_WRITE_TOKEN must be set and at least 12 characters.')
    host, _, port_str = listen_addr.rpartition(':')
    if not host or not port_str:
        raise ValueError('Invalid listen address.')
    port = int(port_str)
    db = connect(db_path)
    srv = ThreadingHTTPServer((host, port), Handler)
    srv.db = db
    srv.write_token = write_token.strip()
    srv.rates = collections.deque()
    srv.auth_failures = collections.deque()
    srv.lock = threading.Lock()
    return srv


def main():
    parser = argparse.ArgumentParser(description='Room coordination pool HTTP service')
    parser.add_argument('--db', default=os.environ.get('POOL_DB_PATH', DB_DEFAULT))
    parser.add_argument('--listen', default=os.environ.get('LISTEN_ADDR', LISTEN_DEFAULT))
    args = parser.parse_args()
    write_token = os.environ.get('POOL_WRITE_TOKEN', '').strip()
    server = make_server(args.db, args.listen, write_token)
    server.serve_forever()


if __name__ == '__main__':
    main()

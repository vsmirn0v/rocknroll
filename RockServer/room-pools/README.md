# Rock room coordination pools

Loopback Python + SQLite WAL service (`127.0.0.1:18793`) and static web page (`/pools/...`) for coordinating pre-created Jazz/Guest room links across anonymous clients.

## Security model
- **Coordination link (`<id>` + `auth`):** Needed to check pool counts (`GET /api/pools/<id>`) and claim 1 unused room (`POST /api/pools/<id>/claim`).
- **Static write password (`X-Pool-Write-Token` from `/opt/rocknroll/room-pools.env`):** Additionally required to create new pools (`POST /api/pools`), list unused links (`GET /api/pools/<id>/links`), add links (`POST /api/pools/<id>/links`), and remove links (`POST /api/pools/<id>/links/remove` or `DELETE /api/pools/<id>/links`).
- **Zero-plaintext storage:** Room URLs and origins are encrypted at rest with AES-256-GCM using a key derived via HKDF-SHA256 from the pool's `auth` token and random salt. Claimed links are scrubbed after a 5-minute idempotency window while keeping HMAC `url_hash` tombstones so already-used rooms cannot be accidentally re-added.

## Local tests
```sh
python3 -m unittest discover -s RockServer/room-pools -p 'test_*.py' -v
```

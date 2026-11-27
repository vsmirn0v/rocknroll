# Rock room coordination pools

Loopback Python + SQLite WAL service (`127.0.0.1:18793`) and static web page (`/pools/...`) for coordinating pre-created Jazz/Guest room links across anonymous clients.

## Security model
- **Coordination link (`<id>#auth=<auth>`):** Needed to check pool counts (`GET /api/pools/<id>`) and claim 1 unused room (`POST /api/pools/<id>/claim`).
- **Manage link (`<id>#auth=<auth>&write=<writeToken>`) or static write password (`X-Pool-Write-Token` from `/opt/rocknroll/room-pools.env`):** Each newly created pool also receives its own per-pool `writeToken` (embedded in `manageUrl`), stored hashed/keyed per pool via `write_verifier`, allowing listing unused links (`GET /api/pools/<id>/links`), adding links (`POST /api/pools/<id>/links`), and removing links (`POST /api/pools/<id>/links/remove` or `DELETE /api/pools/<id>/links`) for that specific pool only. Creating new pools (`POST /api/pools`) strictly requires the static master write password (`X-Pool-Write-Token`), which also retains full management access across all pools.
- **Zero-plaintext storage:** Room URLs and origins are encrypted at rest with AES-256-GCM using a key derived via HKDF-SHA256 from the pool's `auth` token and random salt. Claimed links are scrubbed after a 5-minute idempotency window while keeping HMAC `url_hash` tombstones so already-used rooms cannot be accidentally re-added.

## Local tests
```sh
python3 -m unittest discover -s RockServer/room-pools -p 'test_*.py' -v
```

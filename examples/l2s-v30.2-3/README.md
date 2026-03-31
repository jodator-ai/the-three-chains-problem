# l2s-v30.2-3

Three bare ZKsync OS L2 chains (no Prividium stack) — chain IDs **6565**, **6566**, **6567**, protocol v30.2.

## Start

```bash
./start.sh          # bring up the full stack
./start.sh down     # tear down
./start.sh logs -f  # follow logs
```

## Endpoints

| Service | Chain 6565 | Chain 6566 | Chain 6567 |
|---------|-----------|-----------|-----------|
| L2 RPC (zksyncos) | `http://localhost:5050` | `http://localhost:5051` | `http://localhost:5052` |

**Shared:** L1 (Anvil) `http://localhost:5010`

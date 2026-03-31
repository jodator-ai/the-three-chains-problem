# prividium-2

Two Prividium instances — chain IDs **6565** and **6566**.

## Start

```bash
./start.sh          # bring up the full stack
./start.sh down     # tear down
./start.sh logs -f  # follow logs
```

## Endpoints

| Service | Chain 6565 | Chain 6566 |
|---------|-----------|-----------|
| L2 RPC (zksyncos) | `http://localhost:5050` | `http://localhost:5250` |
| Prividium API | `http://localhost:8000` | `http://localhost:8200` |
| [Admin panel](http://localhost:3000) | http://localhost:3000 | [6566](http://localhost:3200) |
| [User panel](http://localhost:3001) | http://localhost:3001 | [6566](http://localhost:3201) |
| [Block explorer](http://localhost:3010) | http://localhost:3010 | [6566](http://localhost:3210) |
| Keycloak | `http://localhost:5080` | `http://localhost:5280` |
| Bundler (ERC-4337) | `http://localhost:4337` | `http://localhost:4537` |
| Prometheus | `http://localhost:9090` | `http://localhost:9290` |

**Shared:** L1 (Anvil) `http://localhost:5010` · Postgres `localhost:5432`

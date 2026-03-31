# prividium-3

Three Prividium instances — chain IDs **6565**, **6566**, and **6567**.

## Start

```bash
./start.sh          # bring up the full stack
./start.sh down     # tear down
./start.sh logs -f  # follow logs
```

## Endpoints

| Service | Chain 6565 | Chain 6566 | Chain 6567 |
|---------|-----------|-----------|-----------|
| L2 RPC (zksyncos) | `http://localhost:5050` | `http://localhost:5250` | `http://localhost:5450` |
| Prividium API | `http://localhost:8000` | `http://localhost:8200` | `http://localhost:8400` |
| [Admin panel](http://localhost:3000) | http://localhost:3000 | [6566](http://localhost:3200) | [6567](http://localhost:3400) |
| [User panel](http://localhost:3001) | http://localhost:3001 | [6566](http://localhost:3201) | [6567](http://localhost:3401) |
| [Block explorer](http://localhost:3010) | http://localhost:3010 | [6566](http://localhost:3210) | [6567](http://localhost:3410) |
| Keycloak | `http://localhost:5080` | `http://localhost:5280` | `http://localhost:5480` |
| Bundler (ERC-4337) | `http://localhost:4337` | `http://localhost:4537` | `http://localhost:4737` |
| Prometheus | `http://localhost:9090` | `http://localhost:9290` | `http://localhost:9490` |

**Shared:** L1 (Anvil) `http://localhost:5010` · Postgres `localhost:5432`

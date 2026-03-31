# prividium-1

Single Prividium instance — chain ID **6565**.

## Start

```bash
./start.sh          # bring up the full stack
./start.sh down     # tear down
./start.sh logs -f  # follow logs
```

## Endpoints

| Service | URL |
|---------|-----|
| L2 RPC (zksyncos) | `http://localhost:5050` |
| Prividium API | `http://localhost:8000` |
| Admin panel | [http://localhost:3000](http://localhost:3000) |
| User panel | [http://localhost:3001](http://localhost:3001) |
| Block explorer | [http://localhost:3010](http://localhost:3010) |
| Keycloak | `http://localhost:5080` |
| Bundler (ERC-4337) | `http://localhost:4337` |
| Prometheus | `http://localhost:9090` |
| L1 (Anvil) | `http://localhost:5010` |
| Postgres | `localhost:5432` |

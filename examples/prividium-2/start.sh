#!/usr/bin/env bash
# Auto-generated — starts all Prividium instances in this directory.
# Usage:  ./start.sh           — runs: docker compose ... up -d
#         ./start.sh down      — tears down
#         ./start.sh logs -f   — follows logs
#         ./start.sh <any docker compose subcommand>
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -eq 0 ]]; then
  exec docker compose -f docker-compose.6565.yml -f docker-compose.6566.yml up -d
else
  exec docker compose -f docker-compose.6565.yml -f docker-compose.6566.yml "$@"
fi

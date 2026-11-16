#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/build/e2e-tools" "$project_root/verification"
cd "$project_root/go"
export GOPROXY=off GOTOOLCHAIN=local
# The cached official module omits web/dist; the E2E does not use a dashboard.
go build -tags noweb -o "$project_root/build/e2e-tools/frps" github.com/fatedier/frp/cmd/frps
FRPS_BIN="$project_root/build/e2e-tools/frps" go run ./e2e

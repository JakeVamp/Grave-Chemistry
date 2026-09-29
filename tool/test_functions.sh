#!/usr/bin/env bash
# Runs the Edge Function unit tests (Deno). Set DENO_BIN if deno isn't on
# PATH. Test images are generated in memory; providers are fakes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENO="${DENO_BIN:-$(command -v deno || true)}"
if [ -z "$DENO" ]; then
  echo "deno not found; set DENO_BIN" >&2
  exit 1
fi
cd "$ROOT/supabase/functions"
exec "$DENO" test --allow-read --allow-env tests/

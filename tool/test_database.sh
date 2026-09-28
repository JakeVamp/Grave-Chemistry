#!/usr/bin/env bash
# Runs supabase/tests/*_test.sql against a throwaway local PostgreSQL.
# Each test file gets a fresh database with the Supabase stub and every
# migration applied in order. Requires PostgreSQL server binaries
# (initdb, pg_ctl, psql); set PG_BIN to their directory if not on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PG_BIN="${PG_BIN:-$(dirname "$(command -v initdb 2>/dev/null || ls -d /usr/lib/postgresql/*/bin/initdb 2>/dev/null | tail -1)")}"
PORT="${PG_TEST_PORT:-54329}"

if [ ! -x "$PG_BIN/initdb" ]; then
  echo "PostgreSQL server binaries not found. Set PG_BIN." >&2
  exit 1
fi

# initdb refuses to run as root.
if [ "$(id -u)" = 0 ]; then
  exec su postgres -s /bin/bash -c "PG_BIN='$PG_BIN' PG_TEST_PORT='$PORT' '$0'"
fi

WORK="$(mktemp -d)"
cleanup() {
  "$PG_BIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

"$PG_BIN/initdb" -D "$WORK/data" -A trust -U postgres >/dev/null
"$PG_BIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=" -l "$WORK/log" -w start >/dev/null

PSQL=("$PG_BIN/psql" -h "$WORK" -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1)
failures=0

for test in "$ROOT"/supabase/tests/*_test.sql; do
  name="$(basename "$test" .sql)"
  "${PSQL[@]}" -d postgres -c "drop database if exists gc_test" -c "create database gc_test" >/dev/null 2>&1
  {
    "${PSQL[@]}" -d gc_test -f "$ROOT/supabase/tests/support/supabase_stub.sql"
    for migration in "$ROOT"/supabase/migrations/*.sql; do
      "${PSQL[@]}" -d gc_test -1 -f "$migration"
    done
    "${PSQL[@]}" -d gc_test -f "$ROOT/supabase/tests/support/helpers.sql"
  } > "$WORK/setup.log" 2>&1 || { echo "SETUP FAILED for $name"; cat "$WORK/setup.log"; exit 1; }

  if output="$("${PSQL[@]}" -d gc_test -f "$test" 2>&1)"; then
    passed="$(grep -c 'ok - ' <<<"$output" || true)"
    echo "PASS  $name ($passed checks)"
  else
    echo "FAIL  $name"
    grep -E 'ok - |FAILED|ERROR' <<<"$output" | tail -5
    failures=$((failures + 1))
  fi
done

exit "$failures"

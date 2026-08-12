#!/usr/bin/env bash
#
# Applies every migration to a throwaway Postgres and exercises the row-level
# security policies as real users.
#
# This does not need a Supabase project or the Supabase CLI — tests/00_supabase_stub.sql
# stands in for the pieces of a hosted project the migrations lean on (the
# `auth` schema, `auth.uid()`, and the anon/authenticated roles). All it needs
# is Docker.
#
#   ./run-tests.sh

set -euo pipefail

CONTAINER=bide-rls-test
IMAGE=postgres:16-alpine
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "==> starting $IMAGE"
docker run -d --name "$CONTAINER" \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=bide \
  -v "$ROOT":/bide \
  "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 || {
  echo "postgres never became ready" >&2
  exit 1
}

# The stub first, then every migration in filename order, then the assertions.
files=(-f /bide/tests/00_supabase_stub.sql)
for migration in "$ROOT"/supabase/migrations/*.sql; do
  files+=(-f "/bide/supabase/migrations/$(basename "$migration")")
  echo "==> migration $(basename "$migration")"
done
files+=(-f /bide/tests/01_rls_tests.sql)

docker exec "$CONTAINER" psql -U postgres -d bide -v ON_ERROR_STOP=1 -q "${files[@]}"

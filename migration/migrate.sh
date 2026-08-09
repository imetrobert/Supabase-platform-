#!/usr/bin/env bash
#
# Migrate a Supabase database from one project to another.
#
#   OLD: nnkfnlrscywlosfwdlsw   (source — the project being retired)
#   NEW: ipnajvgwtjrlecbqfwrh   (target — must already exist and be empty)
#
# Usage:
#   export OLD_DB_URL='postgresql://postgres.nnkfnlrscywlosfwdlsw:PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres'
#   export NEW_DB_URL='postgresql://postgres.ipnajvgwtjrlecbqfwrh:PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres'
#   ./migrate.sh dump      # step 1: pull everything out of the old project
#   ./migrate.sh restore   # step 2: push it into the new project
#   ./migrate.sh verify    # step 3: compare row counts on both sides
#
# Get each URL from the Supabase dashboard: Project -> Connect -> Session pooler.
# Use the "Session pooler" (port 5432) string, not the transaction pooler (6543) —
# pg_dump needs prepared statements, which the transaction pooler does not support.
#
# Dump and restore are separate steps on purpose: nothing touches the new project
# until you have looked at the files in ./dump/ and are happy with them.

set -euo pipefail

DUMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dump"

# Schemas that belong to the platform, not to you. Supabase creates these in every
# project, so re-creating them in the target would collide with what is already there.
EXCLUDED_SCHEMAS=(
  auth storage realtime vault graphql graphql_public extensions
  pgbouncer supabase_functions supabase_migrations cron net
  information_schema 'pg_*'
)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_urls() {
  [[ -n "${OLD_DB_URL:-}" ]] || die "OLD_DB_URL is not set (see the header of this script)"
  [[ -n "${NEW_DB_URL:-}" ]] || die "NEW_DB_URL is not set (see the header of this script)"
}

# pg_dump refuses to run against a server newer than itself. Supabase projects are
# on Postgres 15 or 17; a stock Debian/Ubuntu box ships the 16 client, which fails
# against 17 with "server version mismatch". Catch that here rather than mid-dump.
check_client_version() {
  local server client
  server=$(psql "$OLD_DB_URL" -tAc 'SHOW server_version;' | cut -d. -f1)
  client=$(pg_dump --version | grep -oE '[0-9]+' | head -1)
  if (( client < server )); then
    die "pg_dump is version $client but the source server is $server.
Install matching client tools, e.g.
  macOS:  brew install libpq && brew link --force libpq
  Ubuntu: sudo apt install postgresql-client-$server
Or use the Supabase CLI instead, which runs the right version in Docker:
  supabase db dump --db-url \"\$OLD_DB_URL\" -f schema.sql"
  fi
}

exclusion_args() {
  local args=()
  for s in "${EXCLUDED_SCHEMAS[@]}"; do args+=(--exclude-schema="$s"); done
  printf '%s\n' "${args[@]}"
}

cmd_dump() {
  require_urls
  check_client_version
  mkdir -p "$DUMP_DIR"

  mapfile -t excl < <(exclusion_args)

  # Dumped in three sections rather than schema-then-data. Loading pre-data (bare
  # tables), then rows, then post-data (indexes, keys, RLS policies, triggers) means
  # rows never land in a table whose foreign keys are already armed, so there is no
  # need for pg_dump's --disable-triggers. That matters here: --disable-triggers and
  # --use-set-session-authorization both emit statements that require superuser, and
  # the `postgres` role on a Supabase project is not one — the restore would fail with
  # "permission denied to set session authorization".
  #
  # --no-owner / --no-privileges for the same reason: the source's ownership and grants
  # reference platform roles, and re-asserting them is both unnecessary and not
  # permitted. Supabase's own roles already own the schemas in the target.

  echo "==> Dumping table definitions (pre-data)"
  pg_dump "$OLD_DB_URL" \
    --section=pre-data --no-owner --no-privileges --quote-all-identifiers \
    "${excl[@]}" \
    -f "$DUMP_DIR/01_pre_data.sql"

  echo "==> Dumping rows"
  pg_dump "$OLD_DB_URL" \
    --section=data --no-owner --no-privileges --quote-all-identifiers \
    "${excl[@]}" \
    -f "$DUMP_DIR/02_data.sql"

  echo "==> Dumping indexes, keys, RLS policies and triggers (post-data)"
  pg_dump "$OLD_DB_URL" \
    --section=post-data --no-owner --no-privileges --quote-all-identifiers \
    "${excl[@]}" \
    -f "$DUMP_DIR/03_post_data.sql"

  # Auth users live in the auth schema, which we deliberately do NOT re-create —
  # the new project already has its own. We export the rows only, as a reference
  # for re-creating logins. See README section "Logins".
  echo "==> Exporting the list of auth users (reference only, not restored automatically)"
  psql "$OLD_DB_URL" -tAc \
    "SELECT email || '  (created ' || created_at::date || ', last sign-in ' ||
            COALESCE(last_sign_in_at::date::text,'never') || ')'
     FROM auth.users ORDER BY created_at;" \
    > "$DUMP_DIR/auth_users.txt"

  echo "==> Recording source row counts"
  psql "$OLD_DB_URL" -tAF',' -c "
    SELECT schemaname||'.'||relname, n_live_tup
    FROM pg_stat_user_tables
    WHERE schemaname NOT IN ('auth','storage','realtime','vault','extensions','cron','net','supabase_functions','supabase_migrations')
    ORDER BY 1;" > "$DUMP_DIR/row_counts_old.csv"

  echo
  echo "Done. Files written to $DUMP_DIR:"
  ls -la "$DUMP_DIR"
  echo
  echo "Read 01_pre_data.sql before continuing — it is the full list of what the old"
  echo "project actually contains. Then run: $0 restore"
}

cmd_restore() {
  require_urls
  [[ -f "$DUMP_DIR/01_pre_data.sql" ]] || die "no dump found; run '$0 dump' first"

  # A single transaction means a failure anywhere leaves the target untouched,
  # rather than half-migrated.
  echo "==> Restoring into the new project (single transaction)"
  psql "$NEW_DB_URL" \
    --single-transaction \
    --variable ON_ERROR_STOP=1 \
    --file "$DUMP_DIR/01_pre_data.sql" \
    --file "$DUMP_DIR/02_data.sql" \
    --file "$DUMP_DIR/03_post_data.sql"

  echo
  echo "Restore complete. Now run: $0 verify"
}

cmd_verify() {
  require_urls
  mkdir -p "$DUMP_DIR"

  # Exact counts, not pg_stat_user_tables.n_live_tup — that column is an estimate
  # refreshed by ANALYZE, and "close enough" is not a migration check. query_to_xml
  # runs a real count(*) per table from within a single query.
  local q="
    SELECT schemaname||'.'||relname AS tbl,
           (xpath('/row/c/text()', cnt))[1]::text::bigint AS rows
    FROM (
      SELECT schemaname, relname,
             query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, relname),
                          false, true, '') AS cnt
      FROM pg_stat_user_tables
      WHERE schemaname NOT IN ('auth','storage','realtime','vault','extensions',
                               'cron','net','supabase_functions','supabase_migrations')
    ) t ORDER BY 1;"

  echo "==> Row counts, old vs new"
  psql "$OLD_DB_URL" -tAF',' -c "$q" | sort > "$DUMP_DIR/counts_old.txt"
  psql "$NEW_DB_URL" -tAF',' -c "$q" | sort > "$DUMP_DIR/counts_new.txt"

  if diff -u "$DUMP_DIR/counts_old.txt" "$DUMP_DIR/counts_new.txt" > "$DUMP_DIR/counts_diff.txt"; then
    echo "PASS — every table has the same number of rows on both sides:"
    sed 's/^/    /' "$DUMP_DIR/counts_old.txt"
  else
    echo "FAIL — the two projects do not match (-old / +new):"
    sed 's/^/    /' "$DUMP_DIR/counts_diff.txt"
    echo
    echo "Do not delete the old project. Re-run the restore into an empty target."
  fi

  echo
  echo "==> RLS policies on the new project (these must not be empty if they were set before)"
  psql "$NEW_DB_URL" -c \
    "SELECT schemaname, tablename, policyname, cmd, roles
     FROM pg_policies WHERE schemaname='public' ORDER BY tablename, policyname;"

  echo "==> Tables with RLS disabled (anything listed here is readable by anyone with the anon key)"
  psql "$NEW_DB_URL" -c \
    "SELECT c.relname FROM pg_class c
     JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='r' AND NOT c.relrowsecurity;"
}

case "${1:-}" in
  dump)    cmd_dump ;;
  restore) cmd_restore ;;
  verify)  cmd_verify ;;
  *)       die "usage: $0 {dump|restore|verify}" ;;
esac

#!/usr/bin/env bash
#
# Copy the `claims` table between projects using only the REST API and the app
# login — no database password needed.
#
# This is the fallback path. It moves ROWS ONLY: the target table must already
# exist (run schema_claims.sql first). Use migrate.sh instead if you can,
# since that also carries over types, defaults, indexes and RLS policies exactly.
#
# Usage:
#   export OLD_ANON_KEY='sb_publishable_...'        # already in claims-tracker/index.html
#   export NEW_ANON_KEY='sb_publishable_...'        # new project -> Connect -> API keys
#   export LOGIN_EMAIL='you@example.com'
#   export OLD_PASSWORD='...'                        # password on the OLD project
#   export NEW_PASSWORD='...'                        # password on the NEW project
#   ./copy_claims_via_api.sh export     # writes dump/claims.json
#   ./copy_claims_via_api.sh import     # reads dump/claims.json, inserts into new

set -euo pipefail

# Overridable so the script can be pointed at a local mock for testing.
OLD_URL="${OLD_URL:-https://nnkfnlrscywlosfwdlsw.supabase.co}"
NEW_URL="${NEW_URL:-https://ipnajvgwtjrlecbqfwrh.supabase.co}"
PAGE="${PAGE:-1000}"

DUMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dump"
OUT="$DUMP_DIR/claims.json"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required (brew install jq / apt install jq)"

# Exchange email+password for a short-lived access token. RLS is evaluated against
# this token, so the rows we see are exactly the rows the app sees.
login() {
  local base="$1" key="$2" pass="$3" resp token
  resp=$(curl -sS -X POST "$base/auth/v1/token?grant_type=password" \
    -H "apikey: $key" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "$LOGIN_EMAIL" --arg p "$pass" '{email:$e,password:$p}')")
  token=$(jq -r '.access_token // empty' <<<"$resp")
  [[ -n "$token" ]] || die "login to $base failed: $(jq -rc '.error_description // .msg // .' <<<"$resp")"
  printf '%s' "$token"
}

cmd_export() {
  [[ -n "${OLD_ANON_KEY:-}" && -n "${LOGIN_EMAIL:-}" && -n "${OLD_PASSWORD:-}" ]] \
    || die "set OLD_ANON_KEY, LOGIN_EMAIL and OLD_PASSWORD"
  mkdir -p "$DUMP_DIR"

  local token offset=0 batch
  token=$(login "$OLD_URL" "$OLD_ANON_KEY" "$OLD_PASSWORD")

  # PostgREST caps a response at 1000 rows by default, so page until short.
  echo '[]' > "$OUT"
  while :; do
    batch=$(curl -sS "$OLD_URL/rest/v1/claims?select=*&order=id&limit=$PAGE&offset=$offset" \
      -H "apikey: $OLD_ANON_KEY" -H "Authorization: Bearer $token")
    jq -e 'type=="array"' >/dev/null <<<"$batch" \
      || die "unexpected response while reading claims: $batch"
    local n; n=$(jq 'length' <<<"$batch")
    (( n == 0 )) && break
    jq -s '.[0] + .[1]' "$OUT" <(printf '%s' "$batch") > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "  fetched $n rows (offset $offset)"
    (( n < PAGE )) && break
    offset=$(( offset + PAGE ))
  done

  echo "Exported $(jq 'length' "$OUT") rows to $OUT"
  echo "Columns seen: $(jq -r '[.[0] // {} | keys[]] | join(", ")' "$OUT")"
}

cmd_import() {
  [[ -f "$OUT" ]] || die "no $OUT; run '$0 export' first"
  [[ -n "${NEW_ANON_KEY:-}" && -n "${LOGIN_EMAIL:-}" && -n "${NEW_PASSWORD:-}" ]] \
    || die "set NEW_ANON_KEY, LOGIN_EMAIL and NEW_PASSWORD"

  local token total existing
  token=$(login "$NEW_URL" "$NEW_ANON_KEY" "$NEW_PASSWORD")

  # Refuse to run twice — inserting the same file again would silently double the data.
  existing=$(curl -sS "$NEW_URL/rest/v1/claims?select=id&limit=1" \
    -H "apikey: $NEW_ANON_KEY" -H "Authorization: Bearer $token" -H 'Prefer: count=exact' \
    -D - -o /dev/null | grep -i '^content-range:' | sed 's|.*/||' | tr -d '\r')
  [[ "$existing" == "0" ]] || die "the new project's claims table already has $existing rows — refusing to import on top of it"

  total=$(jq 'length' "$OUT")
  echo "Importing $total rows..."
  # Send in chunks so one oversized request cannot fail the whole load.
  jq -c "[range(0; $total; $PAGE)] | .[]" "$OUT" | while read -r off; do
    jq -c ".[$off:$off+$PAGE]" "$OUT" \
      | curl -sS -X POST "$NEW_URL/rest/v1/claims" \
          -H "apikey: $NEW_ANON_KEY" -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
          --data-binary @- \
      && echo "  inserted rows $off..$(( off + PAGE ))"
  done

  echo "Done. Verify:"
  curl -sS "$NEW_URL/rest/v1/claims?select=id&limit=1" \
    -H "apikey: $NEW_ANON_KEY" -H "Authorization: Bearer $token" -H 'Prefer: count=exact' \
    -D - -o /dev/null | grep -i '^content-range:'
}

case "${1:-}" in
  export) cmd_export ;;
  import) cmd_import ;;
  *)      die "usage: $0 {export|import}" ;;
esac

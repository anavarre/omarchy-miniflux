#!/usr/bin/env bash
# Black-box tests for bin/miniflux-api, run by tests/run. Every request goes
# to tests/fixture_server.py on 127.0.0.1 or to a closed loopback port; the
# plain-http cases never reach curl at all. Credentials are fictional and the
# store is a temporary directory, so nothing real is read or written.
#
# Bash 3.2 compatible, like the script under test.

set -u
here=$(cd "$(dirname "$0")" && pwd)
api="$here/../bin/miniflux-api"
bash_bin=$(command -v bash)
work=$(mktemp -d "${TMPDIR:-/tmp}/miniflux-api-test.XXXXXX")
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && { kill "$server_pid"; wait "$server_pid"; } 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

python3 "$here/fixture_server.py" "$work/port" "$work/log" &
server_pid=$!
tries=0
until [ -s "$work/port" ]; do
  tries=$((tries + 1))
  [ "$tries" -le 100 ] || { echo "fixture server did not start" >&2; exit 1; }
  sleep 0.1
done
base="http://127.0.0.1:$(cat "$work/port")"
: > "$work/log"
mkdir -p "$work/home"

passed=0 failed=0
ok() { passed=$((passed + 1)); printf 'ok - %s\n' "$1"; }
not_ok() {
  failed=$((failed + 1)); printf 'not ok - %s\n' "$1"
  printf '#   exit %s\n#   stdout: %s\n#   stderr: %s\n' "$rc" "$out" "$err" | head -c 2000
}
check() { local name="$1"; shift; if "$@"; then ok "$name"; else not_ok "$name"; fi; }

# fresh: point at a new, empty credential store.
n=0
fresh() { n=$((n + 1)); store="$work/store-$n"; }
fresh

# run [VAR=value ...] -- ARGS...: runs the script in a scrubbed environment,
# with $input on stdin, and leaves rc, out and err behind.
input=""
run() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  printf '%s' "$input" | env -i PATH=/usr/bin:/bin HOME="$work/home" MINIFLUX_PLUGIN_DIR="$store" \
    ${envs[@]+"${envs[@]}"} "$bash_bin" "$api" "$@" > "$work/out" 2> "$work/err"
  rc=$?
  out=$(cat "$work/out"); err=$(cat "$work/err")
  input=""
}
expect_rc() { local name="$1" want="$2"; shift 2; run "$@"; check "$name (exit $want)" [ "$rc" -eq "$want" ]; }
requests() { wc -l < "$work/log" | tr -d ' '; }
last_request() { tail -n1 "$work/log"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
mode() { if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
key=(MINIFLUX_API_KEY=key)

# --- arguments -------------------------------------------------------------
expect_rc "no command" 64 --
expect_rc "unknown command" 64 -- frobnicate
expect_rc "entries without arguments" 64 -- entries
expect_rc "entries limit 0" 64 -- entries 0 all
expect_rc "entries limit 101" 64 -- entries 101 all
expect_rc "entries limit with a leading zero" 64 -- entries 05 all
expect_rc "entries unknown filter" 64 -- entries 5 starred
expect_rc "mark without ids" 64 -- mark
expect_rc "mark a non-numeric id" 64 -- mark 1 x
expect_rc "mark a shell fragment" 64 -- mark '1;id'
expect_rc "save-entry without an id" 64 -- save-entry

# --- stderr cap ------------------------------------------------------------
run -- mark "$(printf '%05000d' 0 | tr 0 x)"
check "a long error exits 64" [ "$rc" -eq 64 ]
check "stderr is cut off at 2 KiB" [ "$(wc -c < "$work/err" | tr -d ' ')" -eq 2048 ]

# --- setup codes -----------------------------------------------------------
expect_rc "no server" 10 -- auth
expect_rc "no username" 11 MINIFLUX_SERVER=m.example -- auth
expect_rc "no secret" 12 MINIFLUX_SERVER=m.example MINIFLUX_USERNAME=ann -- auth

# --- plain http is refused off this machine, before any request ------------
before=$(requests)
for server in http://m.example http://m.example:80/ http://localhost@m.example \
    http://ann:pw@m.example http://localhost.m.example http://127.0.0.1.m.example \
    http://127.evil 'http://[::1].m.example' 'http://m.example/?h=@localhost' \
    http://m.example/localhost "http://m.example#@127.0.0.1"; do
  expect_rc "refuses $server" 13 "${key[@]}" MINIFLUX_SERVER="$server" -- auth
done
check "no refused server was contacted" [ "$(requests)" -eq "$before" ]
input=$'http://m.example\nann\npw\n' expect_rc "save refuses plain http" 13 -- save
check "a refused save leaves no store behind" [ ! -e "$store" ]

# Loopback and https are let through to curl. Port 1 is closed, so reaching
# curl shows up as exit 20 (request failed) rather than 13.
for server in http://localhost:1 http://ann@localhost:1 http://127.0.0.1:1 'http://[::1]:1' \
    https://127.0.0.1:1 127.0.0.1:1; do
  expect_rc "lets $server through" 20 "${key[@]}" MINIFLUX_SERVER="$server" -- auth
done

# --- requests --------------------------------------------------------------
run "${key[@]}" MINIFLUX_SERVER="$base" -- auth
check "auth succeeds against the fixture" [ "$rc" -eq 0 ]
check "auth ends with the HTTP status" [ "$(printf '%s' "$out" | tail -n1)" = 200 ]
check "auth sends the API key header" has "$(last_request)" '"seen": {"token": "key"}'

run MINIFLUX_API_KEY='a"b\c' MINIFLUX_SERVER="$base" -- auth
check "an awkward API key reaches the server intact" has "$(last_request)" '"seen": {"token": "a\"b\\c"}'
check "a rejected key still exits 0 with the status" [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | tail -n1)" = 401 ]
run MINIFLUX_USERNAME=ann MINIFLUX_PASSWORD="p\"w\\" MINIFLUX_SERVER="$base" -- auth
check "an awkward password reaches the server intact" has "$(last_request)" '"password": "p\"w\\"'

run "${key[@]}" MINIFLUX_SERVER="$base" -- entries 5 unread
check "entries asks for the limit and unread" has "$(last_request)" '"query": "order=published_at&direction=desc&limit=5&status=unread"'
run "${key[@]}" MINIFLUX_SERVER="$base" -- entries 3 all
check "entries all asks for every status" has "$(last_request)" '"query": "order=published_at&direction=desc&limit=3"'
run "${key[@]}" MINIFLUX_SERVER="$base" -- mark 4 9
check "mark sends one PUT for the batch" has "$(last_request)" '"method": "PUT", "mode": "", "route": "/v1/entries", "query": "", "body": "{\"entry_ids\":[4,9],\"status\":\"read\"}"'
run "${key[@]}" MINIFLUX_SERVER="$base" -- save-entry 4
check "save-entry posts to the entry" [ "$(printf '%s' "$out" | tail -n1)" = 202 ] && has "$(last_request)" '"route": "/v1/entries/4/save"'

# --- size cap --------------------------------------------------------------
expect_rc "an oversized body without a length" 22 "${key[@]}" MINIFLUX_SERVER="$base/big" -- auth
check "says the answer was too large" has "$err" "more than 16 MiB"
expect_rc "an oversized body with a length" 22 "${key[@]}" MINIFLUX_SERVER="$base/bigcl" -- auth
check "prints nothing of an oversized body" [ -z "$out" ]

# --- save, config, forget --------------------------------------------------
fresh
input=$'\nann\npw\n' expect_rc "save without a server" 10 -- save
input="$base"$'\nann\nwrong\n' expect_rc "save with a wrong password" 21 -- save
check "reports the status it was refused with" [ "$err" = 401 ]
check "a failed save leaves no store behind" [ ! -e "$store" ]

input="$base"$'\nann\npw\n' expect_rc "save mints an API key" 0 -- save
check "stores the key" [ "$(cat "$store/token")" = key ]
check "stores the key id" [ "$(cat "$store/token-id")" = 7 ]
check "keeps no password" [ ! -e "$store/password" ]
check "the store is 0700" [ "$(mode "$store")" = 700 ]
check "the key is 0600" [ "$(mode "$store/token")" = 600 ]
check "no temporary file is left" [ -z "$(find "$store" -name '.*' -type f)" ]
check "config holds server and username" [ "$(cat "$store/config")" = "server=$base"$'\n'"username=ann" ]
run -- config
check "config reports without the secret" [ "$out" = "{\"server\":\"$base\",\"username\":\"ann\",\"hasSecret\":true}" ]
run -- auth
check "auth uses the stored key" [ "$rc" -eq 0 ] && has "$(last_request)" '"seen": {"token": "key"}'

input="$base"$'\nann\npw\n' expect_rc "a second save" 0 -- save
check "revokes the key it replaced" has "$(last_request)" '"method": "DELETE", "mode": "", "route": "/v1/api-keys/7"'
check "stores the new key id" [ "$(cat "$store/token-id")" = 8 ]
check "reports no leftover key" [ -z "$out" ]

expect_rc "forget" 0 -- forget
check "forget removes every file" [ -z "$(ls -A "$store")" ]
expect_rc "signed out after forget" 10 -- auth

fresh
input="$base/revokefail"$'\nann\npw\n' run -- save
input="$base/revokefail"$'\nann\npw\n' run -- save
check "a refused revoke is reported, not fatal" [ "$rc" -eq 0 ] && [ "$out" = "revoke-failed 9" ]

fresh
input="$base/old"$'\nann\npw\n' expect_rc "save on an instance without API keys" 0 -- save
check "keeps the password instead" [ "$(cat "$store/password")" = pw ] && [ ! -e "$store/token" ]

fresh
input="$base/notoken"$'\nann\npw\n' expect_rc "a key answer without a token" 23 -- save
check "reports the status of the key answer" [ "$err" = 201 ]
check "a failed mint leaves no store behind" [ ! -e "$store" ]

run "${key[@]}" MINIFLUX_SERVER="$base/nosave" -- save-entry 4
check "save-entry passes a 403 through" [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | tail -n1)" = 403 ]

# --- the environment wins over the store -----------------------------------
fresh
input="$base"$'\nann\npw\n' run -- save
expect_rc "MINIFLUX_SERVER overrides the stored server" 20 MINIFLUX_SERVER=http://127.0.0.1:1 -- auth
run MINIFLUX_API_KEY=other -- auth
check "MINIFLUX_API_KEY overrides the stored key" has "$(last_request)" '"seen": {"token": "other"}'
run MINIFLUX_USERNAME=bob -- config
check "config reports the environment's username" has "$out" '"username":"bob"'

# config is parsed as JSON by the panel, so no value may break the quoting.
json() { printf '%s' "$out" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["server"] + "|" + d["username"])' 2>&1; }
run MINIFLUX_SERVER='https://m.example/a"b\c' MINIFLUX_USERNAME="x\"y" -- config
check "config escapes quotes and backslashes" [ "$(json)" = 'https://m.example/a"b\c|x"y' ]
run MINIFLUX_SERVER=https://m.example MINIFLUX_USERNAME="$(printf 'a\tb\nc\r')" -- config
check "config drops control characters" [ "$(json)" = 'https://m.example|abc' ]

# --- unwritable and unsafe stores ------------------------------------------
# Root can write anywhere, so the unwritable case only means something as a
# regular user.
if [ "$(id -u)" -ne 0 ]; then
  mkdir "$work/readonly"; chmod 500 "$work/readonly"
  store="$work/readonly/store"
  input="$base"$'\nann\npw\n' expect_rc "a store that cannot be created" 24 -- save
  check "says it could not create the store" has "$err" "Could not create"
  chmod 700 "$work/readonly"
fi

# --- unsafe stores ---------------------------------------------------------
fresh
mkdir "$work/elsewhere"
ln -s "$work/elsewhere" "$store"
expect_rc "a symlinked store is refused" 24 -- config
check "names the store it refused" has "$err" "Refusing the credential store"
input="$base"$'\nann\npw\n' expect_rc "save refuses a symlinked store" 24 -- save
check "nothing is written through the link" [ -z "$(ls -A "$work/elsewhere")" ]
fresh
: > "$store"
expect_rc "a store that is a file is refused" 24 -- config

printf '# %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

#!/usr/bin/env bash
# Plain-bash tests for codex-quota.mjs. A fake `codex` (node script) replays
# scripted JSON-RPC lines; no network and no real codex are used.
# shellcheck disable=SC2015  # A && B || C is intentional in these one-line checks
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
QUOTA="$HERE/codex-quota.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tmp="$(mktemp -d)"
cleanup() {
  [ -f "$tmp/grandchild.pid" ] && kill "$(cat "$tmp/grandchild.pid")" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

# Fake codex. Env: FAKE_RESULT = full JSON line to answer id 2 with,
# FAKE_MODE = normal | silent (never answers) | grandchild (answers, then leaves
# a long-lived grandchild holding stdout), FAKE_LOG = file receiving each
# received request line.
FAKE="$tmp/codex"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env node
const { createInterface } = require('node:readline');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
if (process.argv[2] !== 'app-server') process.exit(3);
const mode = process.env.FAKE_MODE || 'normal';
const log = (l) => process.env.FAKE_LOG && fs.appendFileSync(process.env.FAKE_LOG, l + '\n');
const send = (o) => process.stdout.write(JSON.stringify(o) + '\n');
createInterface({ input: process.stdin }).on('line', (line) => {
  log(line);
  const m = JSON.parse(line);
  if (m.method === 'initialize') {
    send({ method: 'remoteControl/status/changed', params: {} });
    send({ id: m.id, result: { userAgent: 'fake' } });
  } else if (m.method === 'account/rateLimits/read') {
    if (mode === 'silent') return;
    if (mode === 'grandchild') {
      const g = spawn('sleep', ['60'], { stdio: ['ignore', 'inherit', 'ignore'] });
      fs.writeFileSync(process.env.FAKE_PIDFILE, String(g.pid));
      setTimeout(() => {}, 60000);
    }
    process.stdout.write(process.env.FAKE_RESULT + '\n');
  }
});
EOF
chmod +x "$FAKE"

NOW="$(date +%s)"
W=604800
# resets_for <elapsed-fraction-percent>: resetsAt such that elapsed == pct/100
resets_for() { echo $(( NOW + W - W * $1 / 100 )); }

win() { printf '{"usedPercent":%s,"windowDurationMins":%s,"resetsAt":%s}' "$1" "$2" "$3"; }
resp() { # <reachedType-json> <primary-json> <secondary-json>
  printf '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":%s,"secondary":%s,"rateLimitReachedType":%s}}}' "$2" "$3" "$1"
}

OUT=""; RC=0
run() { # <result-line> [env assignments...]
  local result="$1"; shift
  OUT="$(env FAKE_RESULT="$result" CODEX_QUOTA_CODEX_BIN="$FAKE" CODEX_QUOTA_TIMEOUT_MS=1500 "$@" node "$QUOTA" 2>/dev/null)"; RC=$?
}
expect() { # <name> <expected output (with \t)>
  local want; want="$(printf '%b' "$2")"
  [ "$RC" -eq 0 ] && [ "$OUT" = "$want" ] && ok "$1" || bad "$1" "rc=$RC got=[$OUT] want=[$want]"
}
expect_prefix() { # <name> <expected prefix>
  local want; want="$(printf '%b' "$2")"
  [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && [ "${OUT#"$want"}" != "$OUT" ] && ok "$1" || bad "$1" "rc=$RC got=[$OUT] want prefix=[$want]"
}

# Even-pace rule. elapsed 50% -> pace 55%
run "$(resp null "$(win 20 300 $((NOW+3600)))" "$(win 54 10080 "$(resets_for 50)")")"
expect "usage below pace line -> codex ok" 'codex\tcodex quota ok'

run "$(resp null "$(win 20 300 $((NOW+3600)))" "$(win 60 10080 "$(resets_for 50)")")"
expect "usage above pace line -> claude" 'claude\tauto-downgraded: codex weekly usage 60% exceeds even-pace limit 55%'

run "$(resp null "$(win 70 10080 "$(resets_for 50)")" null)"
expect "weekly window in primary, secondary null" 'claude\tauto-downgraded: codex weekly usage 70% exceeds even-pace limit 55%'

# Pace is rounded to an integer (elapsed 33% -> 38%)
run "$(resp null "$(win 39 10080 "$(resets_for 33)")" null)"
expect "pace rounded to integer" 'claude\tauto-downgraded: codex weekly usage 39% exceeds even-pace limit 38%'

# Elapsed is clamped: resetsAt far in the future -> elapsed 0 -> pace 5
run "$(resp null "$(win 6 10080 $((NOW+W*3)))" null)"
expect "elapsed clamped to 0" 'claude\tauto-downgraded: codex weekly usage 6% exceeds even-pace limit 5%'
# resetsAt in the past -> elapsed 1 -> pace 105, never exceeded
run "$(resp null "$(win 94 10080 $((NOW-W)))" null)"
expect "elapsed clamped to 1" 'codex\tcodex quota ok'

# Both windows 10080: primary wins
run "$(resp null "$(win 10 10080 "$(resets_for 50)")" "$(win 90 10080 "$(resets_for 50)")")"
expect "two weekly windows -> primary taken" 'codex\tcodex quota ok'

# 95% cap
run "$(resp null "$(win 95 300 $((NOW+3600)))" "$(win 1 10080 "$(resets_for 50)")")"
expect "5h window at 95% -> claude" 'claude\tauto-downgraded: codex 5h-window usage 95% reached 95% cap'
run "$(resp null "$(win 0 300 $((NOW+3600)))" "$(win 97 10080 "$(resets_for 99)")")"
expect "weekly window at 97% -> claude" 'claude\tauto-downgraded: codex weekly usage 97% reached 95% cap'
run "$(resp null "$(win 96.5 120 $((NOW+3600)))" null)"
expect "other window length -> <N>m-window, fractional percent" 'claude\tauto-downgraded: codex 120m-window usage 96.5% reached 95% cap'
run "$(resp null "$(win 99 null $((NOW+3600)))" null)"
expect "non-integer window length -> unknown-window" 'claude\tauto-downgraded: codex unknown-window usage 99% reached 95% cap'
run "$(resp null '{"usedPercent":"99","windowDurationMins":300,"resetsAt":1}' null)"
expect "non-numeric usedPercent skipped in cap rule" 'codex\tcodex quota unavailable: no weekly (10080m) window in response'

# rateLimitReachedType
run "$(resp '"rate_limit_reached"' "$(win 100 10080 "$(resets_for 50)")" null)"
expect "rateLimitReachedType set -> claude" 'claude\tauto-downgraded: codex rate limit reached [rate_limit_reached]'
run "$(resp '"workspace_member_credits_depleted"' "$(win 1 300 null)" '{"usedPercent":"x","windowDurationMins":10080,"resetsAt":null}')"
expect "reached type wins despite invalid window fields" 'claude\tauto-downgraded: codex rate limit reached [workspace_member_credits_depleted]'
run "$(resp 7 "$(win 1 10080 "$(resets_for 50)")" null)"
expect "non-string reachedType ignored" 'codex\tcodex quota ok'

# No weekly window
run "$(resp null "$(win 10 300 $((NOW+3600)))" "$(win 10 777 $((NOW+3600)))")"
expect "only non-weekly windows -> unavailable" 'codex\tcodex quota unavailable: no weekly (10080m) window in response'
run "$(resp null null null)"
expect "both windows null -> unavailable" 'codex\tcodex quota unavailable: no weekly (10080m) window in response'
run '{"id":2,"result":{"rateLimits":{}}}'
expect "windows missing -> unavailable" 'codex\tcodex quota unavailable: no weekly (10080m) window in response'

# Weekly window with invalid fields
run "$(resp null '{"usedPercent":10,"windowDurationMins":10080,"resetsAt":null}' null)"
expect "weekly resetsAt null -> invalid reason" 'codex\tcodex quota unavailable: weekly window has invalid usedPercent/resetsAt'
run "$(resp null '{"usedPercent":"10","windowDurationMins":10080,"resetsAt":5}' null)"
expect "weekly usedPercent string -> invalid reason" 'codex\tcodex quota unavailable: weekly window has invalid usedPercent/resetsAt'

# Query failures
run '{"id":2,"error":{"code":-32600,"message":"chatgpt authentication required to read rate limits"}}'
expect_prefix "error response -> codex unavailable" 'codex\tcodex quota unavailable: '
run '{"id":2,"result":null}'
expect_prefix "null result -> codex unavailable" 'codex\tcodex quota unavailable: '
run '{"id":2,"result":{"rateLimits":"nope"}}'
expect_prefix "rateLimits not an object -> codex unavailable" 'codex\tcodex quota unavailable: '
run '{"id":2,"result":{}}'
expect_prefix "rateLimits missing -> codex unavailable" 'codex\tcodex quota unavailable: '

OUT="$(CODEX_QUOTA_CODEX_BIN="$tmp/does-not-exist" node "$QUOTA" 2>/dev/null)"; RC=$?
expect_prefix "executable not found -> codex unavailable" 'codex\tcodex quota unavailable: '

# Request order
LOG="$tmp/requests.log"
run "$(resp null null null)" FAKE_LOG="$LOG"
if [ "$(jq -r '.method' "$LOG" | paste -sd, -)" = "initialize,initialized,account/rateLimits/read" ] \
  && [ "$(jq -r '.params.clientInfo | (.name|type) + (.version|type)' "$LOG" | head -1)" = stringstring ] \
  && [ "$(jq -r '.id // "none"' "$LOG" | paste -sd, -)" = "1,none,2" ]; then
  ok "requests sent in order initialize, initialized, rateLimits/read"
else bad "requests sent in order" "$(cat "$LOG")"; fi

# Timeout: fake never answers
start="$(date +%s)"
run "" FAKE_MODE=silent
expect_prefix "no response -> timeout -> codex unavailable" 'codex\tcodex quota unavailable: '
[ $(( $(date +%s) - start )) -le 5 ] && ok "timeout fires promptly" || bad "timeout fires promptly"

# Grandchild holding the stdout pipe must not delay the result and must die
start="$(date +%s)"
run "$(resp null "$(win 90 10080 "$(resets_for 50)")" null)" FAKE_MODE=grandchild FAKE_PIDFILE="$tmp/grandchild.pid"
expect "grandchild holding pipe: result still printed" 'claude\tauto-downgraded: codex weekly usage 90% exceeds even-pace limit 55%'
[ $(( $(date +%s) - start )) -le 5 ] && ok "grandchild holding pipe: exits promptly" || bad "grandchild holding pipe: exits promptly"
gpid="$(cat "$tmp/grandchild.pid" 2>/dev/null)"
sleep 0.3
if [ -n "$gpid" ] && ! kill -0 "$gpid" 2>/dev/null; then ok "grandchild killed with the process group"
else bad "grandchild killed with the process group" "pid=$gpid"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

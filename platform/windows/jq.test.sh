#!/usr/bin/env bash
# Two copies of platform/windows/bin/jq on PATH must not exec each other.
# Skip signals: FM_WIN_JQ_SHIM (current) and the historical header
# "jq on Windows writes CRLF" (pre-marker home copies). -ef alone is not
# enough when the copies live in different directories.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1

T=$(mktemp -d /tmp/fm-win-jq.XXXXXX)
trap 'rm -rf "$T"' EXIT

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  if [ "$3" = "$2" ]; then ok "$1"; else not_ok "$1 (want: $2, got: $3)"; fi
}

# Real jq must sit behind both shims so the resolver has something to land on.
REAL_JQ=
IFS=: read -r -a _jq_dirs <<< "$PATH"
for d in "${_jq_dirs[@]}"; do
  [ -n "$d" ] || continue
  [ -x "$d/jq" ] || continue
  case "$(head -c 2 "$d/jq" 2>/dev/null || true)" in
    '#!') continue ;;
  esac
  # Skip the overlay bin itself when it is already on PATH.
  [ ! "$d" -ef "$ROOT/platform/windows/bin" ] || continue
  REAL_JQ=$d/jq
  break
done
[ -n "$REAL_JQ" ] || { echo "not ok - no real jq binary found on PATH behind shims"; exit 1; }
REAL_DIR=$(dirname -- "$REAL_JQ")

mkdir -p "$T/shim-a" "$T/shim-b" "$T/fake-real"
cp -- "$ROOT/platform/windows/bin/jq" "$T/shim-a/jq"
cp -- "$ROOT/platform/windows/bin/jq" "$T/shim-b/jq"
chmod +x "$T/shim-a/jq" "$T/shim-b/jq"

# Counting wrapper: proves the shim lands on a real binary once, with one -b.
# Absolute shebang so a narrowed PATH still runs the wrapper.
cat >"$T/fake-real/jq" <<SH
#!/bin/bash
printf 'args:%s\n' "\$*" >"\${FM_WIN_JQ_TEST_LOG:?}"
exit 0
SH
chmod +x "$T/fake-real/jq"

# Keep /usr/bin:/bin so #!/usr/bin/env bash on the shim itself still resolves.
BASE_PATH=/usr/bin:/bin

# Prefer GNU timeout when present; otherwise a short watchdog kill.
run_bounded() {  # <seconds> <command...>
  local secs=$1 rc
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null; ) &
  local watcher=$!
  wait "$pid"
  rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# 1) Two shim dirs, then a fake real jq: must finish and pass one -b.
export FM_WIN_JQ_TEST_LOG=$T/call.log
rm -f "$FM_WIN_JQ_TEST_LOG"
unset FM_WIN_JQ_BIN FM_WIN_JQ_PATH
out=$(PATH="$T/shim-a:$T/shim-b:$T/fake-real:$BASE_PATH" \
  run_bounded 5 "$T/shim-a/jq" -n 1 2>"$T/err"; echo "rc=$?")
expect "two shims then a real jq finish under the timeout" "rc=0" "$out"
expect "two-shim resolve passes a single leading -b" "args:-b -n 1" "$(cat "$FM_WIN_JQ_TEST_LOG" 2>/dev/null || echo missing)"
[ ! -s "$T/err" ] && ok "two-shim resolve writes no stderr" || not_ok "two-shim resolve stderr: $(cat "$T/err")"

# 2) Same layout through the second shim copy.
rm -f "$FM_WIN_JQ_TEST_LOG"
unset FM_WIN_JQ_BIN FM_WIN_JQ_PATH
out=$(PATH="$T/shim-a:$T/shim-b:$T/fake-real:$BASE_PATH" \
  run_bounded 5 "$T/shim-b/jq" -n 1 2>"$T/err"; echo "rc=$?")
expect "second shim copy also finishes under the timeout" "rc=0" "$out"
expect "second shim copy passes a single leading -b" "args:-b -n 1" "$(cat "$FM_WIN_JQ_TEST_LOG" 2>/dev/null || echo missing)"

# 3) Two shims and no real jq: must exit 127 quickly, not spin.
unset FM_WIN_JQ_BIN FM_WIN_JQ_PATH
out=$(PATH="$T/shim-a:$T/shim-b:$BASE_PATH" \
  run_bounded 5 "$T/shim-a/jq" -n 1 2>"$T/err"; echo "rc=$?")
expect "two shims alone exit 127 under the timeout" "rc=127" "$out"
case "$(cat "$T/err")" in
  *'jq: not found on PATH'*) ok "two shims alone report jq not found" ;;
  *) not_ok "two shims alone stderr: $(cat "$T/err")" ;;
esac

# 4) jq.sh resolver skips sibling shims and exports the real binary.
unset FM_WIN_JQ_BIN FM_WIN_JQ_PATH
# shellcheck disable=SC1091
PATH="$T/shim-a:$T/shim-b:$REAL_DIR:$BASE_PATH" \
  . "$ROOT/platform/windows/jq.sh" "$T/shim-a"
case "${FM_WIN_JQ_BIN-}" in
  "$REAL_JQ") ok "jq.sh resolve lands on the real jq behind two shims" ;;
  *) not_ok "jq.sh resolve got FM_WIN_JQ_BIN=${FM_WIN_JQ_BIN-unset}, want $REAL_JQ" ;;
esac

# 5) A stale FM_WIN_JQ_BIN that points at a shim is ignored by bin/jq.
export FM_WIN_JQ_BIN=$T/shim-b/jq
export FM_WIN_JQ_TEST_LOG=$T/call2.log
rm -f "$FM_WIN_JQ_TEST_LOG"
out=$(PATH="$T/shim-a:$T/fake-real:$BASE_PATH" \
  run_bounded 5 "$T/shim-a/jq" -n 1 2>"$T/err"; echo "rc=$?")
expect "stale FM_WIN_JQ_BIN shim pointer is ignored" "rc=0" "$out"
expect "stale pointer still passes one -b to the real jq" "args:-b -n 1" "$(cat "$FM_WIN_JQ_TEST_LOG" 2>/dev/null || echo missing)"

# 6) Pre-marker (unmarked) home shim + current marked shim must not loop.
# Historical header "jq on Windows writes CRLF" is the skip signal for those.
mkdir -p "$T/unmarked"
cat >"$T/unmarked/jq" <<'SH'
#!/usr/bin/env bash
# jq on Windows writes CRLF, which leaves a CR on every value upstream reads.
# -b makes it write LF.
self=${BASH_SOURCE[0]%/*}
IFS=: read -r -a dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  [ -n "$d" ] && [ ! "$d" -ef "$self" ] && [ -x "$d/jq" ] && exec "$d/jq" -b "$@"
done
echo "jq: not found on PATH" >&2
exit 127
SH
chmod +x "$T/unmarked/jq"
export FM_WIN_JQ_TEST_LOG=$T/call3.log
rm -f "$FM_WIN_JQ_TEST_LOG"
unset FM_WIN_JQ_BIN FM_WIN_JQ_PATH
out=$(PATH="$T/shim-a:$T/unmarked:$T/fake-real:$BASE_PATH" \
  run_bounded 5 "$T/shim-a/jq" -n 1 2>"$T/err"; echo "rc=$?")
expect "marked + unmarked pre-marker shim finish under the timeout" "rc=0" "$out"
expect "marked skips unmarked and passes one -b" "args:-b -n 1" "$(cat "$FM_WIN_JQ_TEST_LOG" 2>/dev/null || echo missing)"

[ "$fails" -eq 0 ]

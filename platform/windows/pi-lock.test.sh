#!/usr/bin/env bash
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=platform/windows/env.sh
. platform/windows/env.sh
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID

# pi.cmd runs Pi as node.exe on the package's bundled script, and from a
# PowerShell pane that node.exe has no MSYS pid. Its tool shells are Git Bash
# started by node, so their walk leaves /proc at once. A node whose parent is
# cmd.exe has no MSYS pid either, so this fixture reaches the same chain
# without starting a real Pi. A real Pi relies on process.title for its name
# elsewhere, which Windows never shows, so the fixture's own name is no help.
T=$(mktemp -d /tmp/fm-win-pi-lock.XXXXXX)
BASH_EXE=$(cygpath -w /usr/bin/bash)
fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  case $3 in *"$2"*) ok "$1" ;; *) not_ok "$1 (got: $3)" ;; esac
}
lock_status() { FM_HOME=$1 bin/fm-lock.sh status 2>&1; }

cleanup() {
  local pid
  for pid in "${SESSION_PIDS[@]}"; do taskkill //F //T //PID "$pid" >/dev/null 2>&1; done
  rm -rf "$T"
}
SESSION_PIDS=()
trap cleanup EXIT

H=$T/home
mkdir -p "$H/state" "$T/marks"
PI_CLI=$T/npm/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js
OTHER_CLI=$T/npm/node_modules/some-tool/dist/cli.js
mkdir -p "${PI_CLI%/*}" "${OTHER_CLI%/*}"
cat > "$PI_CLI" <<'EOF'
const { spawn } = require("child_process");
const fs = require("fs");
const [pidFile, bash, ...rest] = process.argv.slice(2);
fs.writeFileSync(pidFile, String(process.pid));
spawn(bash, rest, { stdio: "ignore" }).on("exit", () => process.exit(0));
EOF
cp "$PI_CLI" "$OTHER_CLI"
cat > "$T/session.sh" <<EOF
#!/usr/bin/env bash
cd $(printf '%q' "$ROOT") || exit 1
. platform/windows/env.sh
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
export FM_HOME=\$2
while kill -0 $$ 2>/dev/null && [ -d $(printf '%q' "$T")/marks ]; do
  for go in $(printf '%q' "$T")/marks/\$1.go.*; do
    [ -e "\$go" ] || continue
    cmd=\$(cat "\$go"); rm -f "\$go"
    eval "\${cmd:-bin/fm-lock.sh}" > "\${go/.go./.out.}" 2>&1
    echo "rc=\$?" >> "\${go/.go./.out.}"
  done
  sleep 0.2
done
EOF
chmod +x "$T/session.sh"

start_session() {  # <name> <home> <cli>
  local i
  # start returns at once, so node outlives its parent and the walk ends there
  # instead of climbing into the session that runs this test.
  /c/Windows/System32/cmd.exe //c start "" //b node "$(cygpath -w "$3")" "$(cygpath -w "$T/$1.pid")" \
    "$BASH_EXE" "$(cygpath -m "$T/session.sh")" "$1" "$2" > /dev/null 2>&1
  SESSION_PID=
  for ((i = 0; i < 100; i++)); do
    [ -s "$T/$1.pid" ] && SESSION_PID=$(cat "$T/$1.pid") && break
    sleep 0.1
  done
  [ -z "$SESSION_PID" ] || SESSION_PIDS+=("$SESSION_PID")
}
run_lock() {
  local i
  printf '%s' "${3:-}" > "$T/marks/$1.go.$2"
  for ((i = 0; i < 600; i++)); do
    grep -q '^rc=' "$T/marks/$1.out.$2" 2>/dev/null && break
    sleep 0.1
  done
  cat "$T/marks/$1.out.$2"
}

start_session p1 "$H" "$PI_CLI"; p1=$SESSION_PID
start_session p2 "$H" "$PI_CLI"; p2=$SESSION_PID
[ -n "$p1" ] && [ -n "$p2" ] || { not_ok "the Pi-shaped node sessions started"; exit 1; }
[ ! -e "/proc/$p1" ] || { not_ok "the fixture node has no MSYS pid"; exit 1; }

expect "a Pi session takes the lock as its node pid" "lock acquired: harness pid $p1" "$(run_lock p1 1)"
expect "status names the Pi session" "held by live harness pid $p1" "$(lock_status "$H")"
expect "the same Pi session re-enters" "lock acquired: harness pid $p1" "$(run_lock p1 2)"
expect "a second Pi session is refused" "another live firstmate session holds the lock (pid $p1)" "$(run_lock p2 1)"
taskkill //F //PID "$p1" >/dev/null 2>&1
expect "status reports a killed Pi holder as stale" "lock: stale (pid $p1" "$(lock_status "$H")"
expect "a second Pi session takes over from a killed holder" "lock acquired: harness pid $p2" "$(run_lock p2 2)"

mkdir -p "$T/other/state"
start_session n1 "$T/other" "$OTHER_CLI"
expect "an unrelated node session is no harness" "cannot locate harness process in ancestry" "$(run_lock n1 1)"

[ "$fails" -eq 0 ]

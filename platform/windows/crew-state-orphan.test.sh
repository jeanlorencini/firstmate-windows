#!/usr/bin/env bash
# A watcher killed while crew_is_provably_working waits on fm-crew-state.sh:
# the read must end with the watcher rather than run on as an orphan. The fake
# herdr's pane read blocks for five minutes, so only the watchdog can end it
# within the 15 s this allows. Runs in the caller's environment without env.sh,
# because the watchdog lives in bin/.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1

T=$(mktemp -d /tmp/fm-win-crew-orphan.XXXXXX)
cleanup() {
  local f
  for f in "$T/caller.pid" "$T/herdr.pid"; do
    [ -s "$f" ] && kill -9 "$(cat "$f")" 2> /dev/null
  done
  rm -rf "$T"
}
trap cleanup EXIT
fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$T/state" "$T/bin"
git -C "$T" init -q wt
cat > "$T/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "status --json") printf '{"server":{"running":true}}\n' ;;
  "pane read") printf '%s\n' "$$" > "$FAKE_DIR/herdr.pid"; exec sleep 300 ;;
esac
exit 0
SH
chmod +x "$T/bin/herdr"
printf '%s\n' "worktree=$T/wt" kind=scout harness=claude backend=herdr \
  window=default:w1:p1 herdr_session=default herdr_pane_id=w1:p1 > "$T/state/t1.meta"
printf 'working: reading\n' > "$T/state/t1.status"

PATH="$T/bin:$PATH" FM_STATE_OVERRIDE="$T/state" FAKE_DIR="$T" \
  bash -c '. "$2/bin/fm-classify-lib.sh"; printf "%s\n" "$$" > "$1/caller.pid"; crew_is_provably_working t1' \
  _ "$T" "$ROOT" > /dev/null 2>&1 &
deadline=$((SECONDS + 120))
until [ -s "$T/herdr.pid" ] || [ "$SECONDS" -ge "$deadline" ]; do sleep 0.2; done
if [ ! -s "$T/herdr.pid" ]; then
  not_ok "the read never reached the fake herdr pane read"
else
  kill -9 "$(cat "$T/caller.pid")"
  deadline=$((SECONDS + 15))
  while kill -0 "$(cat "$T/herdr.pid")" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  if kill -0 "$(cat "$T/herdr.pid")" 2> /dev/null; then
    not_ok "the read was still running 15 s after its caller died"
  else
    ok "the read ends within 15 s of its caller dying"
  fi
fi

[ "$fails" -eq 0 ]

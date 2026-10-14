#!/usr/bin/env bash
# fm-spawn.sh's herdr launch step against a fake herdr pane that renders typed
# text after a delay and drops an Enter that arrives before the text renders,
# as a loaded worker pane does (issue #160: the launch line sat typed and
# unsubmitted). The step runs from fm-spawn.sh's own source, lifted from the
# launch-sent marker to the harness-specific follow-up, with the real herdr
# adapter on top of the fake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-launch)

make_slow_pane_herdr() {  # <fakebin> <pane-dir>
  cat > "$1/herdr" <<SH
#!/usr/bin/env bash
pane=$2
now() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
case "\$1 \$2" in
  'status --json') printf '%s\n' '{"client":{"protocol":99,"version":"9.9.9"},"server":{"running":true,"compatible":true}}' ;;
  'pane send-text') printf '%s\t%s\n' "\$((\$(now) + \${FM_FAKE_RENDER_MS:-5000}))" "\$4" > "\$pane/typed" ;;
  'pane send-keys')
    if [ "\$4" = enter ] && [ -f "\$pane/typed" ]; then
      IFS=\$'\t' read -r ready text < "\$pane/typed"
      if [ "\$(now)" -ge "\$ready" ]; then
        printf '%s\n' "\$text" >> "\$pane/submitted"
        rm -f "\$pane/typed"
      else
        printf 'enter before render\n' >> "\$pane/lost"
      fi
    fi
    ;;
  'pane run') printf '%s\n' "\$4" >> "\$pane/submitted" ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

make_refusing_herdr() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'status --json') printf '%s\n' '{"client":{"protocol":99,"version":"9.9.9"},"server":{"running":true,"compatible":true}}' ;;
  'pane run')
    case "$FM_FAKE_RUN" in
      pane_not_found) printf '%s\n' '{"error":{"code":"pane_not_found","message":"pane w1:p1 not found"}}' >&2 ;;
      *) printf 'herdr: pane write refused\n' >&2 ;;
    esac
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

lift() {  # <awk-range-program>
  awk "$1" "$ROOT/bin/fm-spawn.sh"
}

# fm-spawn.sh's launch step, from the launch-sent marker to the harness
# follow-up, with the helpers it calls, reporting the abort-cleanup flag on exit.
# shellcheck disable=SC2016 # The lifted step expands these in its own shell.
write_launch_step() {  # <file>
  {
    printf '%s\n' 'set -eu' 'trap '\''printf "abort-cleanup=%s\n" "$HERDR_PROJECTION_ABORT_CLEANUP"'\'' EXIT'
    printf '%s\n' '. "$ROOT/bin/fm-backend.sh"' 'fm_backend_source herdr'
    lift '/^shell_quote\(\) \{/,/^\}/'
    lift '/^spawn_send_text_line\(\) \{/,/^\}/'
    lift '/^spawn_send_literal\(\) \{/,/^\}/'
    lift '/^spawn_send_key\(\) \{/,/^\}/'
    lift '/^SPAWN_LAUNCH_SENT=1$/{on=1} /^if \[ "\$HARNESS" = kimi \]; then$/{on=0} on'
  } > "$1"
  grep -q 'spawn_send' "$1" || fail "the launch step was not found in fm-spawn.sh"
}

test_herdr_launch_line_is_submitted_on_a_slow_pane() {
  local dir="$TMP_ROOT/slow" fakebin step out
  mkdir -p "$dir/pane"
  fakebin=$(fm_fakebin "$dir")
  make_slow_pane_herdr "$fakebin" "$dir/pane"
  step="$dir/step.sh"
  write_launch_step "$step"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" ROOT="$ROOT" BACKEND=herdr HARNESS=claude T=fmtest:w1:p1 \
    LAUNCH_FILE="$dir/launch.1.sh" HERDR_PROJECTED=1 HERDR_PROJECTION_ABORT_CLEANUP=1 \
    bash "$step" 2>&1) || fail "the launch step failed: $out"
  assert_contains "$out" "abort-cleanup=0" "the launch step left projection abort cleanup armed"
  [ ! -s "$dir/pane/lost" ] || fail "the pane dropped the launch Enter: $(cat "$dir/pane/lost")"
  [ "$(cat "$dir/pane/submitted" 2>/dev/null)" = ". '$dir/launch.1.sh'" ] \
    || fail "the pane never ran the launch line (submitted: $(cat "$dir/pane/submitted" 2>/dev/null))"
  pass "fm-spawn submits the herdr launch line even when the pane renders it late"
}

# A refused launch write keeps projection cleanup armed only when the line
# cannot have reached the pane, and always shows herdr's own refusal.
test_herdr_launch_refusal_keeps_cleanup_only_when_nothing_was_typed() {
  local dir="$TMP_ROOT/refused" fakebin step out mode target want
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  make_refusing_herdr "$fakebin"
  step="$dir/step.sh"
  write_launch_step "$step"
  for mode in no-target pane_not_found refused; do
    target=fmtest:w1:p1 want=1
    case "$mode" in
      no-target) target=fmtest ;;
      refused) want=0 ;;
    esac
    if out=$(cd "$dir" && PATH="$fakebin:$PATH" ROOT="$ROOT" BACKEND=herdr HARNESS=claude T=$target \
      FM_FAKE_RUN=$mode LAUNCH_FILE="$dir/launch.1.sh" HERDR_PROJECTED=1 HERDR_PROJECTION_ABORT_CLEANUP=1 \
      bash "$step" 2>&1); then
      fail "a $mode launch write must fail the launch step: $out"
    fi
    assert_contains "$out" "abort-cleanup=$want" "a $mode launch write must leave abort cleanup at $want"
    case "$mode" in
      pane_not_found) assert_contains "$out" '"code":"pane_not_found"' "herdr's pane_not_found refusal must reach stderr" ;;
      refused) assert_contains "$out" 'herdr: pane write refused' "herdr's refusal must reach stderr" ;;
    esac
  done
  pass "a refused herdr launch write keeps cleanup armed only when nothing was typed, and keeps herdr's stderr"
}

# fm-spawn.sh's treehouse-settle timeout refusal, from its error line to its
# exit, with the endpoint kill stubbed to record the call and the abort-cleanup
# flag reported on exit.
# shellcheck disable=SC2016 # The lifted step expands these in its own shell.
write_settle_timeout_step() {  # <file>
  {
    printf '%s\n' 'set -u' 'trap '\''printf "abort-cleanup=%s\n" "$HERDR_PROJECTION_ABORT_CLEANUP"'\'' EXIT'
    printf '%s\n' 'rovo_endpoint_cleanup() { printf "endpoint-closed=%s\n" "$T"; }'
    awk '/treehouse get did not enter an isolated worktree within/{on=1} on{print} on && /^    exit 1$/{exit}' "$ROOT/bin/fm-spawn.sh"
  } > "$1"
  grep -q 'exit 1' "$1" || fail "the settle timeout refusal was not found in fm-spawn.sh"
}

# A herdr pane that never reached an isolated worktree is closed through the
# ordinary endpoint kill, and the projection abort path that would refuse a
# focus-unsafe close and keep the pane is disarmed. Other backends are left to
# their own abort cleanup.
test_settle_timeout_closes_the_projected_herdr_pane() {
  local dir="$TMP_ROOT/settle-timeout" step out backend
  mkdir -p "$dir"
  step="$dir/step.sh"
  write_settle_timeout_step "$step"
  for backend in herdr tmux; do
    if out=$(BACKEND=$backend T=fmtest:w1:p1 HERDR_PROJECTION_ABORT_CLEANUP=1 \
      WT='' PROJ_ABS="$dir" last_seen="$dir" last_reason="it is the spawning project itself" \
      bash "$step" 2>&1); then
      fail "the $backend settle timeout must still refuse the spawn: $out"
    fi
    assert_contains "$out" "did not enter an isolated worktree within 60s" \
      "the $backend settle timeout lost its refusal"
    case "$backend" in
      herdr)
        assert_contains "$out" "endpoint-closed=fmtest:w1:p1" "the herdr settle timeout left the pane open"
        assert_contains "$out" "abort-cleanup=0" "the herdr settle timeout left projection abort cleanup armed"
        ;;
      *)
        assert_not_contains "$out" "endpoint-closed=" "the $backend settle timeout must not use the herdr endpoint close"
        assert_contains "$out" "abort-cleanup=1" "the $backend settle timeout must leave abort cleanup to its own path"
        ;;
    esac
  done
  pass "a herdr pane that never reached an isolated worktree is closed rather than left behind"
}

test_herdr_launch_line_is_submitted_on_a_slow_pane
test_herdr_launch_refusal_keeps_cleanup_only_when_nothing_was_typed
test_settle_timeout_closes_the_projected_herdr_pane

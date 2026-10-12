#!/usr/bin/env bash
# Focused coverage for crewmate/scout-only interactive-question blocking:
# Grok --no-ask-user, Claude --disallowedTools AskUserQuestion, brief guidance,
# and needs-decision captain-relevance through the existing classify path.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-no-ask)

make_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG ID <<<"$1"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
}

run_logged_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

test_grok_ship_and_scout_get_no_ask_user() {
  local rec out status launch
  rec=$(make_case grok-ship grok no-ask-grok-ship)
  read_case "$rec"
  out=$(run_logged_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$ID" "$PROJ_DIR" grok --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "grok ship spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --no-ask-user" \
    "grok ship launch missing --no-ask-user"

  rec=$(make_case grok-scout grok no-ask-grok-scout)
  read_case "$rec"
  out=$(run_logged_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$ID" "$PROJ_DIR" grok --scout)
  status=$?
  expect_code 0 "$status" "grok scout spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --no-ask-user" \
    "grok scout launch missing --no-ask-user"
  pass "grok ship and scout launches carry --no-ask-user"
}

test_grok_secondmate_keeps_ask_user() {
  local rec sm out status launch
  rec=$(make_case grok-secondmate grok no-ask-grok-sm)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$ID"
  out=$(run_logged_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$ID" "$sm" grok --secondmate)
  status=$?
  expect_code 0 "$status" "grok secondmate spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve" \
    "grok secondmate launch lost --always-approve"
  assert_not_contains "$launch" "--no-ask-user" \
    "grok secondmate launch blocked ask_user_question; supervisors must keep it"
  pass "grok secondmate launch omits --no-ask-user"
}

test_claude_ship_blocks_ask_user_question() {
  local rec out status launch
  rec=$(make_case claude-ship claude no-ask-claude-ship)
  read_case "$rec"
  out=$(run_logged_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$ID" "$PROJ_DIR" claude --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "claude ship spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--disallowedTools AskUserQuestion" \
    "claude ship launch missing AskUserQuestion deny"
  pass "claude ship launch carries --disallowedTools AskUserQuestion"
}

test_claude_secondmate_keeps_ask_user_question() {
  local rec sm out status launch
  rec=$(make_case claude-secondmate claude no-ask-claude-sm)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$ID"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/claude-work" \
    run_logged_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$ID" "$sm" claude --secondmate)
  status=$?
  expect_code 0 "$status" "claude secondmate spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--disallowedTools AskUserQuestion" \
    "claude secondmate launch blocked AskUserQuestion; supervisors must keep it"
  pass "claude secondmate launch omits AskUserQuestion deny"
}

test_brief_guides_workers_to_needs_decision() {
  local home id brief
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  id="brief-no-ask-guidance"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "local-only brief was not scaffolded"
  assert_grep "Interactive question tools are unavailable in this worker" "$brief" \
    "ship brief missing interactive-question guidance"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep 'append `needs-decision` in the status file and stop' "$brief" \
    "ship brief missing needs-decision routing guidance"

  id="brief-no-ask-guidance-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "Interactive question tools are unavailable in this worker" "$brief" \
    "scout brief missing interactive-question guidance"
  pass "ship and scout briefs route decisions through needs-decision"
}

test_needs_decision_is_captain_relevant_for_watcher_path() {
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  local status_file open_view
  status_file="$TMP_ROOT/needs-decision.status"
  printf 'working [at=1700000000]: investigating\n' > "$status_file"
  printf 'needs-decision [at=1700000001] [key=color]: prefer red or blue?\n' >> "$status_file"

  status_is_captain_relevant 'needs-decision [at=1700000001] [key=color]: prefer red or blue?' \
    || fail "needs-decision line is not captain-relevant"
  status_is_terminal_verb 'needs-decision [key=color]: prefer red or blue?' \
    || fail "needs-decision is not a terminal verb for watcher surfacing"

  open_view=$(status_open_decisions "$status_file")
  case "$open_view" in
    *$'\t'needs-decision$'\t'*color*|*color*$'\t'needs-decision*) ;;
    *color*needs-decision*) ;;
    *)
      # Accept either key-first or verb-first fold output as long as the key is open.
      printf '%s\n' "$open_view" | grep -F 'color' >/dev/null \
        || fail "open decisions did not retain keyed needs-decision: $open_view"
      printf '%s\n' "$open_view" | grep -F 'needs-decision' >/dev/null \
        || fail "open decisions lost needs-decision verb: $open_view"
      ;;
  esac
  pass "needs-decision stays captain-relevant and open for the watcher path"
}

test_grok_ship_and_scout_get_no_ask_user
test_grok_secondmate_keeps_ask_user
test_claude_ship_blocks_ask_user_question
test_claude_secondmate_keeps_ask_user_question
test_brief_guides_workers_to_needs_decision
test_needs_decision_is_captain_relevant_for_watcher_path

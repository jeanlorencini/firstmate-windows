#!/usr/bin/env bash
# Focused journal-reader cases for the in-process projection journal snapshot.
# Keeps the full fm-backend-herdr suite out of the hot path for this change.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-projection-journal-read)
mkdir -p "$TMP_ROOT"

write_v1() {  # <path> <task-id> <projection-id>
  printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$2" "$3" > "$1"
}

write_v2() {  # <path> <task-id> <projection-id> <home>
  local path=$1 id=$2 token=$3 home=$4 label
  label=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_workspace_label "$1" "$2"
  ' "$ROOT" "$id" "$token")
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
    printf 'home=%s\n' "$home"
    printf 'session=%s\n' "lab-session"
    printf 'workspace_id=%s\n' "w2"
    printf 'tab_id=%s\n' "w2:t2"
    printf 'pane_id=%s\n' "w2:p2"
    printf 'parent_workspace_id=%s\n' "w1"
    printf 'parent_label=%s\n' "firstmate"
    printf 'workspace_label=%s\n' "$label"
    printf 'task_label=%s\n' "fm-$id"
  } > "$path"
}

test_journal_reader_valid_v1() {
  local dir journal out
  dir="$TMP_ROOT/v1"; mkdir -p "$dir"
  journal="$dir/task-v1.herdr-presentation"
  write_v1 "$journal" task-v1 "AAAAAAAAAAAAAAAAAAAAAA"
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_snapshot "$1" task-v1 || exit 1
    printf "%s|%s|%s" \
      "$FM_BACKEND_HERDR_JOURNAL_VERSION" \
      "$FM_BACKEND_HERDR_JOURNAL_TASK_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID"
  ' "$ROOT" "$journal") || fail "valid version 1 journal must snapshot"
  [ "$out" = "1|task-v1|AAAAAAAAAAAAAAAAAAAAAA" ] \
    || fail "version 1 snapshot globals mismatch: $out"
  pass "journal reader: valid version 1 snapshot"
}

test_journal_reader_valid_v2() {
  local dir home home_real journal out token
  dir="$TMP_ROOT/v2"; home="$dir/home"; mkdir -p "$home"
  home_real=$(cd "$home" && pwd -P)
  token="BBBBBBBBBBBBBBBBBBBBBB"
  journal="$dir/task-v2.herdr-presentation"
  write_v2 "$journal" task-v2 "$token" "$home_real"
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_snapshot "$1" task-v2 || exit 1
    printf "%s|%s|%s|%s|%s" \
      "$FM_BACKEND_HERDR_JOURNAL_VERSION" \
      "$FM_BACKEND_HERDR_JOURNAL_HOME" \
      "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_SESSION" \
      "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL"
  ' "$ROOT" "$journal") || fail "valid version 2 journal must snapshot"
  [ "$out" = "2|$home_real|w2:p2|lab-session|fm-task-v2" ] \
    || fail "version 2 snapshot globals mismatch: $out"
  pass "journal reader: valid version 2 snapshot"
}

test_journal_reader_missing_key() {
  local dir journal
  dir="$TMP_ROOT/missing"; mkdir -p "$dir"
  journal="$dir/task-miss.herdr-presentation"
  printf 'version=1\ntask_id=task-miss\n' > "$journal"
  if bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_snapshot "$1" task-miss
  ' "$ROOT" "$journal"; then
    fail "missing projection_id must reject"
  fi
  if bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_field "$1" projection_id
  ' "$ROOT" "$journal"; then
    fail "field reader must reject a missing key"
  fi
  pass "journal reader: missing key rejects snapshot and field"
}

test_journal_reader_duplicated_key() {
  local dir home home_real journal token
  dir="$TMP_ROOT/dup"; home="$dir/home"; mkdir -p "$home"
  home_real=$(cd "$home" && pwd -P)
  token="CCCCCCCCCCCCCCCCCCCCCC"
  journal="$dir/task-dup.herdr-presentation"
  write_v2 "$journal" task-dup "$token" "$home_real"
  printf 'pane_id=duplicate\n' >> "$journal"
  if bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_snapshot "$1" task-dup
  ' "$ROOT" "$journal"; then
    fail "duplicated pane_id must reject"
  fi
  if bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_field "$1" pane_id
  ' "$ROOT" "$journal"; then
    fail "field reader must reject a duplicated key"
  fi
  pass "journal reader: duplicated key rejects snapshot and field"
}

test_journal_reader_value_contains_equals() {
  local dir home home_real journal out token label
  dir="$TMP_ROOT/eq"; home="$dir/home"; mkdir -p "$home"
  home_real=$(cd "$home" && pwd -P)
  token="DDDDDDDDDDDDDDDDDDDDDD"
  journal="$dir/task-eq.herdr-presentation"
  label=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_workspace_label task-eq "$1"
  ' "$ROOT" "$token")
  {
    printf 'version=2\n'
    printf 'task_id=task-eq\n'
    printf 'projection_id=%s\n' "$token"
    printf 'home=%s\n' "$home_real"
    printf 'session=lab-session\n'
    printf 'workspace_id=w2\n'
    printf 'tab_id=w2:t2\n'
    printf 'pane_id=w2:p2\n'
    printf 'parent_workspace_id=w1\n'
    printf 'parent_label=a=b=c\n'
    printf 'workspace_label=%s\n' "$label"
    printf 'task_label=fm-task-eq\n'
  } > "$journal"
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_snapshot "$1" task-eq || exit 1
    printf "%s\n" "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL"
    fm_backend_herdr_projection_journal_field "$1" parent_label
    printf "\n"
  ' "$ROOT" "$journal") || fail "value containing = must still snapshot"
  [ "$out" = $'a=b=c\na=b=c' ] || fail "value after first = was not preserved: $out"
  pass "journal reader: value containing = keeps bytes after the first ="
}

test_journal_reader_valid_v1
test_journal_reader_valid_v2
test_journal_reader_missing_key
test_journal_reader_duplicated_key
test_journal_reader_value_contains_equals

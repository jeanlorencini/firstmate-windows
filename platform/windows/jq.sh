# shellcheck shell=bash
# Sourced by env.sh and bash-env.sh with the overlay's bin directory.
#
# bin/jq adds -b to every jq call, but it is a script, so each call starts one
# more bash, and a spawn makes over a hundred jq calls. A bash that finds a
# real jq on PATH gets this function instead, which adds the same -b without
# that bash. With no real jq on PATH no function is defined, so `command -v jq`
# still answers as it would. Scanning PATH costs about 18 ms here, so the
# answer and the PATH it came from are exported for every child with the same
# PATH to reuse.
#
# A candidate that carries FM_WIN_JQ_SHIM, or the historical header
# "jq on Windows writes CRLF", is another copy of the overlay bash shim,
# never a real jq. Skipping those keeps two shim directories on PATH
# (including a pre-marker home copy) from resolving each other into a loop.

_FM_WIN_JQ_SELF=$1

_fm_win_jq_is_shim() {  # <path> -> 0 when path is this overlay's bash shim
  # Skip this overlay's wrapper, marked or unmarked. FM_WIN_JQ_SHIM is the
  # current marker; "jq on Windows writes CRLF" is the historical header still
  # present on pre-marker home copies. Without the historical match, a mixed
  # PATH (new worktree + old home) mutual-execs until ARG_MAX.
  local f=$1 line n=0
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *FM_WIN_JQ_SHIM*) return 0 ;;
      *'jq on Windows writes CRLF'*) return 0 ;;
    esac
    n=$((n + 1))
    [ "$n" -lt 16 ] || break
  done <"$f"
  return 1
}

_fm_win_jq_resolve() {
  local d dirs
  FM_WIN_JQ_BIN=
  FM_WIN_JQ_PATH=$PATH
  IFS=: read -r -a dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    [ -x "$d/jq" ] || continue
    [ ! "$d" -ef "$_FM_WIN_JQ_SELF" ] || continue
    _fm_win_jq_is_shim "$d/jq" && continue
    FM_WIN_JQ_BIN=$d/jq
    break
  done
  export FM_WIN_JQ_BIN FM_WIN_JQ_PATH
}

[ "$PATH" = "${FM_WIN_JQ_PATH-}" ] || _fm_win_jq_resolve
if [ -n "$FM_WIN_JQ_BIN" ]; then
  jq() {
    [ "$PATH" = "$FM_WIN_JQ_PATH" ] || _fm_win_jq_resolve
    [ -n "$FM_WIN_JQ_BIN" ] || { echo "jq: not found on PATH" >&2; return 127; }
    "$FM_WIN_JQ_BIN" -b "$@"
  }
  # Keep jq local to this shell. export -f would skip bin/jq's bash spawn in
  # child bash processes, but on native Windows the exported function body
  # plus a large --argjson argv tips CreateProcess ARG_MAX (seen in
  # fm-fleet-snapshot --contribution-input). FM_WIN_JQ_BIN stays exported so
  # bin/jq can exec the real binary without a PATH walk.
fi

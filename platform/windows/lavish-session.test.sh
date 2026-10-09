#!/usr/bin/env bash
# Lavish on Windows saves a board's session under its drive spelling,
# C:\Users\...\board.html, while the Lavish listener resolves the board it was
# armed for as /c/Users/.../board.html. The listener must still find that one
# session, and only that one.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
T=$(mktemp -d /tmp/fm-win-lavish-session.XXXXXX)
trap 'rm -rf "$T"' EXIT

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  case $3 in *"$2"*) ok "$1" ;; *) not_ok "$1 (got: $3)" ;; esac
}

mkdir -p "$T/bin" "$T/home" "$T/lavish"
printf '<h1>board</h1>\n' > "$T/board.html"
printf '<h1>other</h1>\n' > "$T/other.html"
cat > "$T/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'reached %s:%s\n' "$LAVISH_AXI_HOST" "$LAVISH_AXI_PORT"
printf 'session:\n  status: ended\n  ended_by: user\n'
SH
chmod +x "$T/bin/lavish-axi"

store() {  # <saved file>
  perl -MJSON::PP -e 'print encode_json({sessions => {"0123456789abcdef" => {
    key => "0123456789abcdef", file => $ARGV[0], status => "open",
    url => "http://127.0.0.1:14387/session/0123456789abcdef"}}})' "$1" > "$T/lavish/state.json"
}
poll() {
  (. platform/windows/env.sh; PATH=$T/bin:$PATH LAVISH_AXI_STATE_DIR=$T/lavish FM_HOME=$T/home \
    timeout 20 bash bin/fm-procevent-lavish.sh poll "$T/board.html" 2>&1)
}

# Lavish's spelling of the real path: drive letter, backslashes, and a case
# that differs from the one this shell resolves.
saved=$(cygpath -w "$(cd -P "$T" && builtin pwd -P)/board.html")
store "${saved^^}"
expect "a drive-spelled saved session routes the MSYS-spelled board" "reached 127.0.0.1:14387" "$(poll)"

store "$(cygpath -w "$T/other.html")"
expect "a drive-spelled session for another file does not match the board" \
  "board must have one saved Lavish session" "$(poll)"

[ "$fails" -eq 0 ]

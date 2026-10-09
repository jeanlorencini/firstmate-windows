#!/usr/bin/env bash
# The ps shim asked for pgid, comm or args of a process whose MSYS parent has
# exited, which is how every detached procevent runner and owner guard starts,
# answers from /proc without starting pwsh; only ppid still walks Win32 parents.
# A fake pwsh first on PATH records each start.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1

T=$(mktemp -d /tmp/fm-win-proc.XXXXXX)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$T/bin"
cat > "$T/bin/pwsh" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$FAKE_DIR/pwsh.calls"
SH
chmod +x "$T/bin/pwsh"
cat > "$T/probe.sh" <<'SH'
i=0
until [ "$(cat "/proc/$$/ppid")" = 1 ] || [ "$i" -ge 200 ]; do sleep 0.05; i=$((i + 1)); done
printf 'self\t%s\t%s\n' "$$" "$(cat "/proc/$$/ppid")" >> "$FAKE_DIR/results"
for f in pgid comm args ppid; do
  rm -f "$FAKE_DIR/pwsh.calls"
  out=$("$PS" -o "$f=" -p "$$")
  started=no
  [ ! -e "$FAKE_DIR/pwsh.calls" ] || started=yes
  printf '%s\t%s\t%s\n' "$f" "$out" "$started" >> "$FAKE_DIR/results"
done
printf 'end\n' >> "$FAKE_DIR/results"
SH

PATH="$T/bin:$PATH" TMPDIR="$T" FAKE_DIR="$T" PS="$ROOT/platform/windows/bin/ps" \
  perl -e 'defined(my $pid = fork) or exit 1; if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 1 } exit 0' \
  bash "$T/probe.sh"
deadline=$((SECONDS + 30))
until grep -qx end "$T/results" 2> /dev/null || [ "$SECONDS" -ge "$deadline" ]; do sleep 0.2; done

row() { awk -F'\t' -v k="$1" '$1 == k { print $2 "\t" $3; exit }' "$T/results" 2> /dev/null; }
IFS=$'\t' read -r self parent <<< "$(row self)"
if [ "${parent:-}" != 1 ]; then
  not_ok "the probe's MSYS parent never exited (ppid ${parent:-unknown})"
else
  IFS=$'\t' read -r pgid started <<< "$(row pgid)"
  if [ "$pgid" = "$self" ] && [ "$started" = no ]; then ok "pgid answers from /proc without pwsh"
  else not_ok "pgid gave '$pgid' (want $self), pwsh started: $started"; fi
  IFS=$'\t' read -r comm started <<< "$(row comm)"
  if [ "$comm" = /usr/bin/bash ] && [ "$started" = no ]; then ok "comm answers from /proc without pwsh"
  else not_ok "comm gave '$comm', pwsh started: $started"; fi
  IFS=$'\t' read -r args started <<< "$(row args)"
  if [[ $args == *"$T/probe.sh"* ]] && [ "$started" = no ]; then ok "args answers from /proc without pwsh"
  else not_ok "args gave '$args', pwsh started: $started"; fi
  IFS=$'\t' read -r _ started <<< "$(row ppid)"
  if [ "$started" = yes ]; then ok "ppid still walks the Win32 parents"
  else not_ok "ppid did not walk the Win32 parents"; fi
fi

[ "$fails" -eq 0 ]

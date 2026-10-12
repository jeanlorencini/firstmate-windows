#!/usr/bin/env bash
# The herdr presentation lock namespace is private here by ACL, not by mode:
# on a noacl drive mkdir -m 700 sets nothing and stat answers the umask. A
# namespace the adapter creates must come out private, and one that already
# exists open must be refused, as upstream refuses an existing 755 one. Needs
# no herdr: the session's socket is stubbed.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=platform/windows/env.sh
. platform/windows/env.sh
# shellcheck source=bin/backends/herdr.sh
. bin/backends/herdr.sh
# At 022 upstream's stat reads every directory here as 755.
umask 022

T=$(mktemp -d /tmp/fm-win-herdr-lock.XXXXXX)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }

NS=$T/ns
fm_backend_herdr_presentation_lock_namespace() { printf '%s' "$NS"; }
fm_backend_herdr_presentation_session_socket_path() { printf '%s' "$T/herdr.sock"; }
acl() { MSYS2_ARG_CONV_EXCL='*' icacls "$(cygpath -w "$1")" | grep -c ':(' ; }

if lock=$(fm_backend_herdr_presentation_session_lock_path s1) && [ "${lock%/*}" = "$NS" ]; then
  ok "a namespace the adapter creates resolves a lock path under it"
  if bash platform/windows/private-root.sh check "$NS" >/dev/null 2>&1 && [ "$(acl "$NS")" = 3 ]; then
    ok "that namespace is private by ACL: this user, SYSTEM and Administrators only"
  else
    not_ok "that namespace is private by ACL (got: $(bash platform/windows/private-root.sh check "$NS" 2>&1))"
  fi
else
  not_ok "a namespace the adapter creates resolves a lock path (got: $lock; private-root.sh: $(bash platform/windows/private-root.sh check "$NS" 2>&1))"
fi
[ -e "$NS" ] || ok "a namespace whose ACL could not be applied is not left behind"

mkdir -p "$NS"
MSYS2_ARG_CONV_EXCL='*' icacls "$(cygpath -w "$NS")" /grant '*S-1-1-0:(OI)(CI)F' >/dev/null
if lock=$(fm_backend_herdr_presentation_session_lock_path s1); then
  not_ok "an existing namespace open to Everyone is refused (got: $lock)"
else
  ok "an existing namespace open to Everyone is refused"
fi
if [ -d "$NS" ]; then
  ok "the refused namespace is left as found, not repaired"
else
  not_ok "the refused namespace is left as found"
fi

[ "$fails" -eq 0 ]

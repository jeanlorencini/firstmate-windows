#!/usr/bin/env bash
# Usage: platform/windows/private-root.sh check|apply <dir>...
#
# On Windows a firstmate file is private because of its directory's ACL, not
# its POSIX mode: Git Bash mounts drives noacl, so chmod changes nothing and
# stat reports the mode the reader's umask implies (see env.sh). A root is
# private when every entry of its ACL names this user, SYSTEM or
# Administrators, the same set that can read a 0700 directory on Linux.
#
# icacls prints account names in the interface language, so the check reads
# the DACL as SDDL (icacls /save), where every principal is a SID: SY is
# SYSTEM, BA is Administrators and the user is the S-1-5-21-... whoami reports.
#
# check prints "private <dir>" or "open <dir>: <sid> <ace>..." and exits 1 when
# any root is open. apply replaces an open root's ACL with that set, inherited
# by everything beneath it, which needs no admin because the user owns it.
set -u

mode=${1:-}
case $mode in check | apply) shift ;; *) echo "usage: $0 check|apply <dir>..." >&2; exit 2 ;; esac
[ $# -gt 0 ] || { echo "usage: $0 check|apply <dir>..." >&2; exit 2; }

# /usr/bin/whoami is GNU's; the SID comes from the Windows one.
me=$(MSYS2_ARG_CONV_EXCL='*' "$(cygpath -u -- "$SYSTEMROOT")/System32/whoami.exe" /user /fo csv /nh 2>/dev/null)
me=${me##*,\"}; me=${me%%\"*}

acl_outsiders() {
  local sddl ace sid entries=0 tmp
  tmp=$(mktemp) || { echo unreadable-acl; return 0; }
  # /save writes "<path>\r\n<sddl>\r\n" in UTF-16LE; the SDDL is ASCII, so
  # dropping the NULs decodes it.
  sddl=$(MSYS2_ARG_CONV_EXCL='*' icacls "$1" /save "$(cygpath -w -- "$tmp")" >/dev/null 2>&1 \
    && tr -d '\0\r' < "$tmp" | sed -n 2p)
  rm -f "$tmp"
  case $sddl in D:*'('*) sddl=${sddl#*(}; sddl=${sddl%)} ;; *) sddl= ;; esac
  while IFS= read -r ace; do
    [ -n "$ace" ] || continue
    entries=$((entries + 1))
    sid=${ace##*;}
    case $sid in SY | S-1-5-18 | BA | S-1-5-32-544 | "$me") continue ;; esac
    printf '%s %s\n' "$sid" "${ace%;;;*}"
  done <<< "${sddl//)(/$'\n'}"
  [ "$entries" -gt 0 ] || echo unreadable-acl
}

rc=0
for dir in "$@"; do
  [ -d "$dir" ] || { echo "missing $dir" >&2; rc=1; continue; }
  win=$(cygpath -w -- "$dir")
  open=$(acl_outsiders "$win")
  if [ -n "$open" ] && [ "$mode" = apply ]; then
    if ! { MSYS2_ARG_CONV_EXCL='*' icacls "$win" /reset >/dev/null \
      && MSYS2_ARG_CONV_EXCL='*' icacls "$win" /inheritance:r /grant:r \
        "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*$me:(OI)(CI)F" >/dev/null; }; then
      rc=1
      continue
    fi
    open=$(acl_outsiders "$win")
  fi
  if [ -n "$open" ]; then
    printf 'open %s: %s\n' "$dir" "$(printf '%s' "$open" | tr '\n' ';')"
    rc=1
  else
    printf 'private %s\n' "$dir"
  fi
done
exit "$rc"

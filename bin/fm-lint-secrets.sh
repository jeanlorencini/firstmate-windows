#!/usr/bin/env bash
# fm-lint-secrets.sh - owner of firstmate's secret scan.
#
# Runs pinned gitleaks over git history so a committed password or key fails
# the local and no-mistakes lint lane before it is pushed. bin/fm-lint.sh
# invokes this owner on its default (no explicit-path) path, which CI and
# commands.lint both use. A missing or wrong-version gitleaks fails the run;
# the scan is never skipped. Known fake fixtures are allowlisted by
# fingerprint in the committed .gitleaksignore, never by disabling rules.
#
# With a merge-base the scan covers only the commits it adds (<base>..HEAD);
# without one (CI, main, merge-base-less) it covers the whole history.
# With a merge-base, a change to .gitleaksignore, a gitleaks config file, or this script in
# that range also fails, because an automated allowlist edit must not get a
# finding through; the captain approves such a change.
#
# Usage:
#   fm-lint-secrets.sh [<merge-base>]
#   fm-lint-secrets.sh --required-version
#   fm-lint-secrets.sh --help
set -eu

REQUIRED_GITLEAKS=8.30.1

case "${1:-}" in
  --required-version)
    printf '%s\n' "$REQUIRED_GITLEAKS"
    exit 0
    ;;
  --help|-h)
    sed -n '2,20{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"

command -v gitleaks >/dev/null 2>&1 || {
  printf 'fm-lint-secrets.sh: gitleaks %s is required and was not found on PATH (bin/fm-install-gitleaks.sh installs it).\n' \
    "$REQUIRED_GITLEAKS" >&2
  exit 1
}
actual=$(gitleaks version 2>/dev/null | tr -d '[:space:]') || actual=
[ "${actual#v}" = "$REQUIRED_GITLEAKS" ] || {
  printf 'fm-lint-secrets.sh: gitleaks %s is required, found %s.\n' "$REQUIRED_GITLEAKS" "${actual:-unknown}" >&2
  exit 1
}

cd "$ROOT"
rc=0
log_opts=()
if [ -n "${1:-}" ]; then
  log_opts=(--log-opts "$1..HEAD")
  # An allowlist, config, or gate-script edit in the scanned range could silence a real
  # finding, so it fails the lint until the captain approves it.
  changed=$(git diff --name-only "$1..HEAD" -- .gitleaksignore .gitleaks.toml gitleaks.toml bin/fm-lint-secrets.sh) || changed=
  if [ -n "$changed" ]; then
    printf 'fm-lint-secrets.sh: this branch changes the gitleaks allowlist, config, or this gate script:\n%s\n' "$changed" >&2
    printf 'An allowlist change needs the captain to approve this lint finding. Do not edit .gitleaksignore, gitleaks config, or bin/fm-lint-secrets.sh, or rewrite commits to silence gitleaks; escalate instead.\n' >&2
    rc=1
  fi
fi
gitleaks git --no-banner --redact ${log_opts[@]+"${log_opts[@]}"} . || rc=1
exit "$rc"

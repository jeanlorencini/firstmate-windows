#!/usr/bin/env bash
# Drives the real bin/fm-lint.sh / bin/fm-lint-secrets.sh against a disposable clone.
set -u
WT=/c/Users/loren/.no-mistakes/worktrees/be9d69754c83/01M4WP5C7PB8YQ872K2PY1TYZV
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-gitleaks-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
step() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; rc=$?; printf '[exit %s]\n' "$rc"; return 0; }
fake_token() { printf 'ghp_%s' "$(printf 'Zq8xR2mN7vK4wP1tY6uL3sD9fH5jB0cE2gA7')"; }

git clone -q "$WT" "$LAB/repo" && cd "$LAB/repo" || exit 1
git -c advice.detachedHead=false checkout -q "$(git -C "$WT" rev-parse HEAD)"
git checkout -q -b fm/demo
git config user.email lab@example.invalid; git config user.name lab
BASE_PRE=55d16697e4cdb8010f937b017b1ad600ae03cef0
git update-ref refs/remotes/origin/main "$BASE_PRE"
unset CI GITHUB_ACTIONS

step "S1 clean branch: real fm-lint-secrets.sh over this branch's commits (merge-base $BASE_PRE)"
run bin/fm-lint-secrets.sh "$BASE_PRE"

step "S1b clean whole history reachable from HEAD (CI/main mode, no merge-base)"
run bin/fm-lint-secrets.sh

# From here the base already contains the gate (as after this PR merges).
git update-ref refs/remotes/origin/main HEAD
BASE=$(git rev-parse HEAD)

step "S2 commit a fake GitHub token, run full lint entry point bin/fm-lint.sh (pre-push lint lane)"
printf 'deploy_token = "%s"\n' "$(fake_token)" > config.txt
git add config.txt && git commit -qm "add config"
run bin/fm-lint.sh

step "S2b same, owner script directly"
run bin/fm-lint-secrets.sh "$BASE"

step "S3 attempt to silence via uncommitted .gitleaksignore fingerprint (guard must still fail)"
fp=$(gitleaks git --no-banner --redact --log-opts "$BASE..HEAD" --report-format json --report-path "$LAB/r.json" . >/dev/null 2>&1; sed -n 's/.*"Fingerprint": *"\([^"]*\)".*/\1/p' "$LAB/r.json" | head -1)
echo "fingerprint: $fp"; echo "$fp" >> .gitleaksignore
run bin/fm-lint-secrets.sh "$BASE"
step "S3b same allowlist edit committed (guard must still fail)"
git commit -qam "allowlist" ; run bin/fm-lint-secrets.sh "$BASE"
git reset -q --hard HEAD~2

step "S4 leak exists only on another branch; whole-history scan of HEAD must not report it"
git checkout -q -b other
printf 'k = "%s"\n' "$(fake_token)" > other.txt; git add other.txt; git commit -qm other
git checkout -q fm/demo
git update-ref -d refs/remotes/origin/main
run env CI=true bin/fm-lint-secrets.sh
step "S4b control: gitleaks default (all refs) does see it"
run gitleaks git --no-banner --redact .
git update-ref refs/remotes/origin/main "$BASE"

step "S5 unresolvable merge-base must fail closed, not pass with 0 commits"
run bin/fm-lint-secrets.sh deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

step "S6 gitleaks missing from PATH must fail the lint, not skip"
run env PATH="/usr/bin:/mingw64/bin" bin/fm-lint-secrets.sh "$BASE"
step "S6b wrong gitleaks version must fail"
mkdir -p "$LAB/fakebin"; printf '#!/bin/sh\necho 8.0.0\n' > "$LAB/fakebin/gitleaks"; chmod +x "$LAB/fakebin/gitleaks"
run env PATH="$LAB/fakebin:/usr/bin:/mingw64/bin" bin/fm-lint-secrets.sh "$BASE"

step "S7 explicit-path lint does not run the secret scan; default path does"
printf 'deploy_token = "%s"\n' "$(fake_token)" > config.txt; git add config.txt; git commit -qm again
run bin/fm-lint.sh bin/fm-lint-secrets.sh

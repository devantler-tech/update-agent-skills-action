#!/usr/bin/env bash
# Check the actual release consumer boundary and prove its unsafe mutations are refused.
# Releases get their token from the GitHub token broker (devantler-tech/monorepo ADR 0020): the
# shared release job proves its identity with an OIDC token, so this caller grants only
# id-token: write and forwards no App key. The broker issues a botantler App token, the identity
# the release-tag creation ruleset trusts (devantler-tech/.github#933, #1001).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/release.yaml" >"$work/release.json"
check_release() {
  jq -e '
    .permissions == {} and (.jobs | keys) == ["release"] and
    .on.workflow_dispatch.inputs["dry-run"].type == "boolean" and
    .on.workflow_dispatch.inputs["dry-run"].default == false and
    .jobs.release.with["dry-run"] == "${{ inputs.dry-run || false }}" and
    (.jobs.release.uses | test("^devantler-tech/\\.github/\\.github/workflows/create-release\\.yaml@[0-9a-f]{40}$")) and
    (.jobs.release.with | has("protected-release") | not) and
    .jobs.release.with["disable-issue-side-effects"] == true and
    .jobs.release.permissions == {"id-token":"write"} and
    (.jobs.release | has("secrets") | not)
  ' "$1" >/dev/null
}
check_release "$work/release.json" || { echo 'FAIL: release does not take its token from the GitHub token broker' >&2; exit 1; }
for mutation in retired-mode inherit retired-key app-key no-oidc mutable live-preview side-effects; do
  # shellcheck disable=SC2016 # Literal GitHub expressions in boundary controls.
  case "$mutation" in
    live-preview) change='.on.workflow_dispatch.inputs["dry-run"].default=true' ;;
    retired-mode) change='.jobs.release.with["protected-release"]=true' ;;
    inherit) change='.jobs.release.secrets="inherit"' ;;
    retired-key) change='.jobs.release.secrets={RELEASE_APP_PRIVATE_KEY:"${{ secrets.RELEASE_APP_PRIVATE_KEY }}"}' ;;
    app-key) change='.jobs.release.secrets={APP_PRIVATE_KEY:"${{ secrets.APP_PRIVATE_KEY }}"}' ;;
    no-oidc) change='del(.jobs.release.permissions["id-token"])' ;;
    mutable) change='.jobs.release.uses="devantler-tech/.github/.github/workflows/create-release.yaml@main"' ;;
    side-effects) change='.jobs.release.with["disable-issue-side-effects"]=false' ;;
  esac
  jq "$change" "$work/release.json" >"$work/mutated.json"
  if check_release "$work/mutated.json"; then echo "FAIL: accepted $mutation release boundary" >&2; exit 1; fi
done
echo 'PASS: actual release consumer uses the GitHub token broker and rejects eight unsafe changes'

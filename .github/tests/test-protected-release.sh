#!/usr/bin/env bash
# Check the actual consumer boundary and prove its unsafe mutations are refused.
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
    .jobs.release.with["protected-release"] == true and
    .jobs.release.with["disable-issue-side-effects"] == true and
    .jobs.release.secrets == {RELEASE_APP_PRIVATE_KEY:"${{ secrets.RELEASE_APP_PRIVATE_KEY }}"}
  ' "$1" >/dev/null
}
check_release "$work/release.json" || { echo 'FAIL: release is not bound to protected environment credentials' >&2; exit 1; }
for mutation in mode inherit legacy mutable missing live-preview; do
  case "$mutation" in
    live-preview) change='.on.workflow_dispatch.inputs["dry-run"].default=true' ;;
    mode) change='.jobs.release.with["protected-release"]=false' ;;
    inherit) change='.jobs.release.secrets="inherit"' ;;
    legacy) change='.jobs.release.secrets={APP_PRIVATE_KEY:"${{ secrets.APP_PRIVATE_KEY }}"}' ;;
    mutable) change='.jobs.release.uses="devantler-tech/.github/.github/workflows/create-release.yaml@main"' ;;
    missing) change='del(.jobs.release.secrets)' ;;
  esac
  jq "$change" "$work/release.json" >"$work/mutated.json"
  if check_release "$work/mutated.json"; then echo "FAIL: accepted $mutation release boundary" >&2; exit 1; fi
done
echo 'PASS: actual protected release consumer rejects six unsafe changes'

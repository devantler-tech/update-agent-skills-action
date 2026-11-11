#!/usr/bin/env bash
# Contract test for the per-skill update description (devantler-tech/.github#745): each per-skill
# pull request states the upstream repository and path, the old and new trees with the commits that
# hold them and a compare link, the upstream commits touching the path with their subjects as inert
# text, the licence at both commits, and whether the upstream is archived or renamed. A changed
# licence, an archived or renamed upstream and an unresolved range put a warning at the top, and an
# unresolved fact is stated as unknown.
#
# The upstream is a local bare repository fetched over file://, and every forge read goes through a
# stub `gh`. The workflow's own describe step is extracted from the workflow and run, never
# transcribed, and the per-skill PR must take its body from what that step wrote.
# shellcheck disable=SC2016 # literal ${{ }} expressions and Markdown backticks on purpose
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
describe="$repo_root/.github/scripts/describe-skill-update.sh"
workflow="$repo_root/.github/workflows/update-agent-skills.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export DESCRIBE_SKILL_UPSTREAM_BASE="file://$work/forge"

# ── the upstream: acme/skills with a skill at skills/demo ────────────────────────────────────
src="$work/src"
git init -q -b main "$src"
git -C "$src" config user.name "Upstream"
git -C "$src" config user.email "upstream@example.com"
git -C "$src" config commit.gpgsign false
commit() { # <subject>
  git -C "$src" add -A
  git -C "$src" commit -q --allow-empty -m "$1"
  git -C "$src" rev-parse HEAD
}
tree_of() { git -C "$src" rev-parse "$1:skills/demo"; }

mkdir -p "$src/skills/demo"
printf 'MIT License\n' >"$src/LICENSE"
printf -- '---\nname: demo\n---\nv1\n' >"$src/skills/demo/SKILL.md"
c1="$(commit "feat: add demo")"
printf 'readme\n' >"$src/README.md"
commit "docs: unrelated readme" >/dev/null
printf -- '---\nname: demo\n---\nv2\n' >"$src/skills/demo/SKILL.md"
# A hostile subject: closing keywords and every reference form, a mention, a fence-breaking backtick
# run, HTML, a Markdown link, an escape character and a very long tail.
long="$(printf 'x%.0s' $(seq 1 1000))"
hostile="$(printf "\033")[31mFixes #1, closes acme/other#2, resolves GH-3 and https://github.com/acme/skills/issues/4 and www.github.com/acme/skills/issues/5 @devantler \`\`\`\`\`\` </details><img src=x onerror=alert(1)> [click](https://evil.example) ${long}"
commit "$hostile" >/dev/null
printf -- '---\nname: demo\n---\nv3\n' >"$src/skills/demo/SKILL.md"
c4="$(commit "fix(demo): tighten wording")"
t1="$(tree_of "$c1")"
t4="$(tree_of "$c4")"
# A licence change in the same range, as its own state of the upstream.
printf 'Apache License 2.0\n' >"$src/LICENSE"
printf -- '---\nname: demo\n---\nv4\n' >"$src/skills/demo/SKILL.md"
c5="$(commit "chore: relicense")"
t5="$(tree_of "$c5")"
# A licence file beside the skill changes its text without changing what GitHub detects at the root.
printf 'Skill notice v1\n' >"$src/skills/demo/LICENSE.txt"
c6="$(commit "docs(demo): add a notice")"
t6="$(tree_of "$c6")"
printf 'Skill notice v2\n' >"$src/skills/demo/LICENSE.txt"
c7="$(commit "docs(demo): change the notice")"
t7="$(tree_of "$c7")"
# GitHub reads the same licence files differently at the next commit.
printf -- "---\nname: demo\n---\nv5\n" >"$src/skills/demo/SKILL.md"
c8="$(commit "docs(demo): reword")"
t8="$(tree_of "$c8")"

mkdir -p "$work/forge/acme"
git clone -q --bare "$src" "$work/forge/acme/skills.git"
git -C "$work/forge/acme/skills.git" config uploadpack.allowFilter true

# ── the stub forge ───────────────────────────────────────────────────────────────────────────
mkdir -p "$work/bin" "$work/gh"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_STUB/calls"
[[ "$1" == api && $# -eq 2 ]] || { echo "unexpected gh call: $*" >&2; exit 64; }
case "$2" in
  repos/acme/skills)
    [[ -f "$GH_STUB/repo.json" ]] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    cat "$GH_STUB/repo.json" ;;
  repos/acme/skills/license\?ref=*)
    ref="${2#*ref=}"
    [[ ! -f "$GH_STUB/license-$ref.fail" ]] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    if [[ -f "$GH_STUB/license-$ref.json" ]]; then cat "$GH_STUB/license-$ref.json"
    else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_STUB="$work/gh"
licence() { printf '{"path":"LICENSE","license":{"spdx_id":"%s"}}\n' "$2" >"$GH_STUB/license-$1.json"; }
for c in "$c1" "$c4" "$c6" "$c7"; do licence "$c" MIT; done
licence "$c5" Apache-2.0
licence "$c8" GPL-3.0-only
active() { printf '{"full_name":"acme/skills","archived":false}\n' >"$GH_STUB/repo.json"; }

# ── the caller: one skill moved from <old tree> to <new tree> ────────────────────────────────
skill_md() { # <tree> [repo] [path]
  printf -- '---\nname: demo\nmetadata:\n    github-path: %s\n    github-ref: %s\n    github-repo: %s\n    github-tree-sha: %s\n---\nbody\n' \
    "${3:-skills/demo}" "${REF:-refs/heads/main}" "${2:-https://github.com/acme/skills}" "$1"
}
caller="$work/caller"
describe_update() { # <old tree> <new tree> [new repo]: prints the body
  rm -rf "$caller"
  git init -q -b main "$caller"
  git -C "$caller" config user.name "Caller"
  git -C "$caller" config user.email "caller@example.com"
  git -C "$caller" config commit.gpgsign false
  mkdir -p "$caller/plugins/p/skills/demo"
  REF="${OLD_REF:-}" skill_md "$1" >"$caller/plugins/p/skills/demo/SKILL.md"
  git -C "$caller" add -A
  git -C "$caller" commit -q -m base
  REF="${NEW_REF:-}" skill_md "$2" "${3:-}" "${NEW_PATH:-}" >"$caller/plugins/p/skills/demo/SKILL.md"
  (cd "$caller" && bash "$describe" plugins/p/skills/demo)
}
has() { grep -qF -- "$2" <<<"$1" || fail "$3: expected '$2' in:"$'\n'"$1"; }
lacks() { if grep -qF -- "$2" <<<"$1"; then fail "$3: unexpected '$2' in:"$'\n'"$1"; fi; }
warning_block() { awk '/^> \[!WARNING\]$/ { on = 1 } on && !/^>/ { exit } on' <<<"$1"; }

# ── unchanged licence: every fact, no warning ────────────────────────────────────────────────
active
body="$(describe_update "$t1" "$t4")"
[[ -z "$(warning_block "$body")" ]] || fail "an unchanged, active upstream must carry no warning:"$'\n'"$body"
[[ "$(head -n 1 <<<"$body")" == 'Automated update of the agent skill at `plugins/p/skills/demo` to its latest version.' ]] ||
  fail "the body must open with the skill it updates:"$'\n'"$body"
has "$body" "| Repository | https://github.com/acme/skills |" "repository"
has "$body" '| Path | `skills/demo` |' "path"
has "$body" "| Repository state | active |" "state"
has "$body" "| Old tree | \`$t1\` in [\`${c1:0:12}\`](https://github.com/acme/skills/tree/$c1/skills/demo) |" "old tree"
has "$body" "| New tree | \`$t4\` in [\`${c4:0:12}\`](https://github.com/acme/skills/tree/$c4/skills/demo) |" "new tree"
has "$body" "| Compare | https://github.com/acme/skills/compare/$c1...$c4 |" "compare"
has "$body" "| Commits touching the path | 2 |" "count (the unrelated readme commit is not counted)"
has "$body" "fix(demo): tighten wording" "subjects"
lacks "$body" "docs: unrelated readme" "subjects outside the path"
has "$body" "| Licence at the old commit | MIT; \`LICENSE\` (\`$(git -C "$src" rev-parse "$c1:LICENSE" | cut -c1-12)\`) |" "old licence"
has "$body" "| Licence at the new commit | MIT; \`LICENSE\` (" "new licence"
lacks "$body" "(**changed**)" "an unchanged licence"
echo "ok: an unchanged licence states every fact and no warning"

# ── the hostile subject is inert ─────────────────────────────────────────────────────────────
subjects="$(awk '/^`{3,}text$/ { on = 1; fence = substr($0, 1, length($0) - 4); next } on && $0 == fence { exit } on' <<<"$body")"
has "$subjects" "Fixes ＃1" "the neutralised closing keyword"
for bad in '#1' '#2' 'GH-3' '://' 'www.github' '@devantler' $'\033'; do
  lacks "$subjects" "$bad" "an upstream reference, mention or control character"
done
grep -qE '#[0-9]|@[A-Za-z]' <<<"$body" && fail "the body still holds a reference or mention:"$'\n'"$body"
fence="$(grep -E '^`{3,}text$' <<<"$body" | sed 's/text$//')"
longest="$(awk '{ s = $0; while (match(s, /`+/)) { if (RLENGTH > n) n = RLENGTH; s = substr(s, RSTART + RLENGTH) } } END { print n + 0 }' <<<"$subjects")"
((${#fence} > longest)) || fail "the subject fence (${#fence}) does not outlast the subjects' backtick run ($longest)"
[[ "$(grep -cxF -- "$fence" <<<"$body")" == 1 ]] || fail "the subjects must close their own fence exactly once"
while IFS= read -r line; do
  (($(printf '%s' "$line" | wc -c) <= 200)) || fail "a subject line is longer than the cap: ${#line}"
done <<<"$subjects"
echo "ok: an upstream subject cannot link, close, notify, escape its fence or run long"

# ── a changed licence ────────────────────────────────────────────────────────────────────────
body="$(describe_update "$t4" "$t5")"
has "$(warning_block "$body")" "The upstream licence changed between the old and the new commit." "changed licence warning"
has "$body" "| Licence at the old commit | MIT;" "old licence"
has "$body" "| Licence at the new commit | Apache-2.0;" "new licence"
has "$body" "(**changed**) |" "changed licence flag"
body="$(describe_update "$t6" "$t7")"
has "$(warning_block "$body")" "The upstream licence changed" "a changed licence text under the same identifier"
has "$body" '`skills/demo/LICENSE.txt`' "the skill's own licence file"
body="$(describe_update "$t7" "$t8")"
has "$(warning_block "$body")" "The upstream licence changed" "a changed licence identifier over the same files"
has "$body" "| Licence at the new commit | GPL-3.0-only;" "the new identifier"
touch "$GH_STUB/license-$c1.fail"
body="$(describe_update "$t1" "$t4")"
rm -f "$GH_STUB/license-$c1.fail"
lacks "$body" "licence changed" "a licence read that failed at one end, over the same files"
has "$body" "| Licence at the old commit | unknown; \`LICENSE\` (" "an unknown identifier beside the known file"
echo "ok: a changed licence, by identifier or by text, is flagged at the top"

# ── an archived repository ───────────────────────────────────────────────────────────────────
printf '{"full_name":"acme/skills","archived":true}\n' >"$GH_STUB/repo.json"
body="$(describe_update "$t1" "$t4")"
has "$(warning_block "$body")" 'The upstream repository `acme/skills` is archived.' "archived warning"
has "$body" "| Repository state | archived |" "archived state"
echo "ok: an archived upstream is flagged at the top"

# ── a renamed repository that now redirects ──────────────────────────────────────────────────
printf '{"full_name":"acme-labs/agent-skills","archived":false}\n' >"$GH_STUB/repo.json"
body="$(describe_update "$t1" "$t4")"
has "$(warning_block "$body")" 'The upstream repository was renamed: `acme/skills` now redirects to `acme-labs/agent-skills`.' "renamed warning"
has "$body" '| Repository state | active; redirects to `acme-labs/agent-skills` after a rename |' "renamed state"
printf '{"full_name":"ACME/Skills","archived":false}\n' >"$GH_STUB/repo.json"
body="$(describe_update "$t1" "$t4")"
[[ -z "$(warning_block "$body")" ]] || fail "a difference in letter case only is not a rename:"$'\n'"$body"
printf '{"full_name":"acme/x`y](https://evil)","archived":false}\n' >"$GH_STUB/repo.json"
body="$(describe_update "$t1" "$t4")"
lacks "$body" "evil" "an unusable repository name from the forge"
has "$(warning_block "$body")" "Whether the upstream repository is archived or renamed is unknown." "an unusable repository name"
echo "ok: a redirecting upstream is flagged, and only a name that passes the pattern is shown"

# ── a tree that cannot be resolved ───────────────────────────────────────────────────────────
active
missing=0123456789abcdef0123456789abcdef01234567
body="$(describe_update "$missing" "$t4")"
has "$(warning_block "$body")" "The upstream range could not be resolved: no upstream commit" "unresolved tree warning"
has "$(warning_block "$body")" "The licence at the old and the new commit could not be compared." "unknown licence warning"
has "$body" "| Old tree | \`$missing\` in an unknown commit |" "unresolved old tree"
has "$body" "| Compare | unknown: no upstream commit within the last 2000 that touch the path holds the old tree |" "unknown compare"
has "$body" "| Commits touching the path | unknown |" "unknown count"
has "$body" "| Licence at the old commit | unknown |" "unknown old licence"
echo "ok: a tree that cannot be resolved is stated as unknown, with a warning"

# ── nothing upstream can be read ─────────────────────────────────────────────────────────────
rm -f "$GH_STUB/repo.json"
mv "$work/forge/acme/skills.git" "$work/forge/acme/gone.git"
body="$(describe_update "$t1" "$t4")"
has "$body" "| Repository state | unknown (the repository could not be read) |" "unreadable repository"
has "$body" "| Compare | unknown: the upstream repository could not be fetched |" "unfetchable upstream"
has "$(warning_block "$body")" "Whether the upstream repository is archived or renamed is unknown." "unreadable warning"
mv "$work/forge/acme/gone.git" "$work/forge/acme/skills.git"
active
body="$(describe_update "$t1" "$t4" 'https://github.com/acme/skills`](https://evil)')"
lacks "$body" "evil" "invalid repository metadata"
has "$body" "| Repository | unknown |" "an invalid new repository is not replaced by the previous one"
has "$body" "| Previous source |" "a changed source"
has "$(warning_block "$body")" "the skill's upstream source changed" "a changed source warning"
echo "ok: an unreadable forge, an unfetchable upstream and invalid metadata are stated as unknown"

# ── pinned tags: the old tag's own commit changed only the licence ───────────────────────────
printf 'Apache License 2.0\n' >"$src/LICENSE"
c_tag1="$(commit "chore: relicense to Apache")"
git -C "$src" tag v1
printf 'MIT License\n' >"$src/LICENSE"
printf -- '---\nname: demo\n---\nv6\n' >"$src/skills/demo/SKILL.md"
c_tag2="$(commit "feat(demo): v6 under MIT")"
git -C "$src" tag v2
licence "$c_tag1" Apache-2.0
licence "$c_tag2" MIT
git -C "$work/forge/acme/skills.git" fetch -q "$src" '+refs/heads/main:refs/heads/main' '+refs/tags/*:refs/tags/*'
body="$(OLD_REF=refs/tags/v1 NEW_REF=refs/tags/v2 describe_update "$t8" "$(tree_of "$c_tag2")")"
has "$body" "| Old tree | \`$t8\` in [\`${c_tag1:0:12}\`]" "the old tag's own commit"
has "$body" "| Licence at the old commit | Apache-2.0;" "the licence at the old tag"
has "$(warning_block "$body")" "The upstream licence changed" "a licence changed between two tags"
has "$body" "| Commits touching the path | 1 |" "the tag range"
echo "ok: a pinned tag is read at its own commit, so a licence-only tag commit is not missed"

# ── the size cap ─────────────────────────────────────────────────────────────────────────────
for i in $(seq 1 45); do
  printf 'v%s\n' "$i" >>"$src/skills/demo/SKILL.md"
  commit "feat(demo): step $i $(printf '\140%.0s' $(seq 1 40)) $(printf 'y%.0s' $(seq 1 5000))" >/dev/null
done
c_last="$(git -C "$src" rev-parse HEAD)"
licence "$c_last" MIT
git -C "$work/forge/acme/skills.git" fetch -q "$src" '+refs/heads/main:refs/heads/main'
body="$(describe_update "$(tree_of "$c_tag2")" "$(tree_of "$c_last")")"
(($(printf '%s' "$body" | wc -c) < 60000)) || fail "the body is not bounded: $(printf '%s' "$body" | wc -c) bytes"
has "$body" "| Commits touching the path | 45 |" "the full count"
has "$body" "And 15 more; see the compare link." "the remainder note"
echo "ok: at most 30 capped subjects keep the body far below GitHub's limit"

# ── a moved upstream path, and a bounded licence-file list ───────────────────────────────────
git -C "$src" mv skills/demo skills/renamed
for i in $(seq 1 12); do printf 'extra %s\n' "$i" >"$src/LICENSE.part$i"; done
for i in 1 2 3; do printf 'long %s\n' "$i" >"$src/LICENSE.$(printf '%0150d' "$i")"; done
c_move="$(commit "refactor: move the demo skill")"
licence "$c_move" MIT
git -C "$work/forge/acme/skills.git" fetch -q "$src" '+refs/heads/main:refs/heads/main'
moved_tree="$(git -C "$src" rev-parse "$c_move:skills/renamed")"
body="$(NEW_PATH=skills/renamed describe_update "$(tree_of "$c_last")" "$moved_tree")"
has "$body" "](https://github.com/acme/skills/tree/$c_last/skills/demo) |" "the old tree linked at its own path"
has "$body" "](https://github.com/acme/skills/tree/$c_move/skills/renamed) |" "the new tree linked at its own path"
has "$body" '| Previous source | `acme/skills` at `skills/demo` |' "the previous path"
has "$body" ", and 7 more" "the capped licence-file list"
lacks "$body" "LICENSE.000" "an over-long licence file name"
echo "ok: each tree links at its own path, and the licence-file list is capped"

# ── the workflow describes every split skill and opens each PR with its description ──────────
q() { yq -r "$1" "$workflow"; }
keep="$(q '.jobs.update-agent-skills.steps[] | select(.name == "📋 Keep the per-skill splitter") | .run')"
grep -qF '.github/scripts/describe-skill-update.sh' <<<"$keep" ||
  fail "the describer must be copied out of this workflow's own commit with the splitter"
step='.jobs.update-agent-skills.steps[] | select(.name == "📝 Describe each skill'\''s update")'
[[ "$(q "$step | .if")" == "\${{ steps.split.outputs.skills != '' && steps.split.outputs.skills != '[]' }}" ]] ||
  fail "the describe step must run whenever a per-skill patch exists"
index_of() { q ".jobs.update-agent-skills.steps | to_entries[] | select(.value.name == \"$1\") | .key"; }
if ! (($(index_of "🧩 Split the update per skill") < $(index_of "📝 Describe each skill's update"))) ||
  ! (($(index_of "📝 Describe each skill's update") < $(index_of "📤 Upload the per-skill patches"))); then
  fail "the descriptions must be written after the split and before the upload"
fi
per_skill='.jobs.open-skill-pull-requests.steps[] | select(.name == "📦 Create pull request")'
[[ "$(q "$per_skill | .with.body-path")" == '${{ runner.temp }}/skill-updates/${{ matrix.skill.slug }}.md' ]] ||
  fail "each per-skill PR must take its body from its own description"
[[ "$(q "$per_skill | .with.body")" == null ]] || fail "a fixed body must not shadow the description"
q "$step | .run" >"$work/describe-step.sh"

run_step() { # <manifest> <describer>
  mkdir -p "$work/runner/skill-updates"
  cp "$2" "$work/runner/describe-skill-update.sh"
  (cd "$caller" && RUNNER_TEMP="$work/runner" SKILLS="$1" bash "$work/describe-step.sh")
}
describe_update "$t1" "$t4" >/dev/null
run_step '[{"slug":"p-skills-demo","path":"plugins/p/skills/demo"}]' "$describe" >/dev/null
has "$(cat "$work/runner/skill-updates/p-skills-demo.md")" "| Compare | https://github.com/acme/skills/compare/$c1...$c4 |" "the step's description"
printf '#!/usr/bin/env bash\nexit 3\n' >"$work/broken.sh"
run_step '[{"slug":"p-skills-demo","path":"plugins/p/skills/demo"}]' "$work/broken.sh" >/dev/null 2>&1 ||
  fail "a describer failure must not stop the update"
body="$(cat "$work/runner/skill-updates/p-skills-demo.md")"
has "$(warning_block "$body")" "could not be described" "a describer failure"
has "$body" "Automated update of this agent skill to its latest version." "the fallback body"
echo "ok: the workflow describes each split skill, falls back visibly, and each PR uses its description"

echo "PASS: per-skill update PRs state the upstream range, licence and repository state of each skill"

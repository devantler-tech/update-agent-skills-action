#!/usr/bin/env bash

# Describe one skill's update for its per-skill pull request (devantler-tech/.github#745), so a
# reviewer does not have to reconstruct the upstream range by hand (devantler-tech/agent-plugins#583).
#
# usage: describe-skill-update.sh <skill-path>
#
# Run from the root of the caller's checkout after the update: HEAD holds the old copy of
# <skill-path>/SKILL.md and the working tree the new one. stdout is the Markdown body. It states the
# upstream repository and path, the old and new tree SHAs with the upstream commits that hold them
# and a compare link, the upstream commits that touch the path in that range, the licence at both
# commits, and whether the upstream is archived or now redirects after a rename. A fact that cannot
# be resolved is stated as unknown, never left out; a changed licence, an archived or renamed
# upstream and an unresolved range or licence put a warning at the top.
#
# Everything read from upstream or from the skill's metadata is hostile: values are only rendered
# after they match a strict pattern, and commit subjects only inside a fence they cannot close, with
# controls stripped, `@` and `#` replaced by look-alikes and the length capped, so nothing in them
# can link, close, notify or restructure anything in the consuming repository. Upstream code is never
# checked out or run: a blobless fetch reads commits and trees only.
#
# Reads: `gh api` for the repository state and GitHub's licence detection; `git fetch` of the public
# upstream. DESCRIBE_SKILL_UPSTREAM_BASE replaces https://github.com as the fetch base, for tests only.

# shellcheck disable=SC2016 # backticks in single quotes are Markdown, not command substitution
set -euo pipefail

max_commits=2000      # path history searched for each tree
max_subjects=30       # subjects listed in the body
max_subject_bytes=200 # per subject, after sanitising
max_licence_files=10  # licence files listed per commit
max_body_bytes=60000  # GitHub refuses a body over 65536 characters
fetch_seconds=300

usage() {
  echo "usage: describe-skill-update.sh <skill-path>" >&2
  exit 2
}
[[ $# -eq 1 ]] || usage
skill="${1%/}"
[[ "$skill" =~ ^[A-Za-z0-9._/-]+$ && "$skill" != /* && "/$skill/" != */../* ]] ||
  usage
command -v jq >/dev/null || {
  echo "describe-skill-update: jq is unavailable" >&2
  exit 2
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

warnings=()
warn() { warnings+=("$1"); }

# ── the skill's metadata, old (HEAD) and new (working tree) ──────────────────────────────────
# metadata <file> <key>: the value of `metadata.<key>` in the file's front matter, or nothing.
metadata() {
  head -c 1048576 "$1" | awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^metadata:[[:space:]]*$/ { inmeta = 1; next }
    /^[^[:space:]]/ { inmeta = 0 }
    inmeta && $1 == key ":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 ~ /^".*"$/ || $0 ~ /^'\''.*'\''$/) $0 = substr($0, 2, length($0) - 2)
      print
      exit
    }'
}

: >"$work/old.md"
: >"$work/new.md"
git show "HEAD:./$skill/SKILL.md" >"$work/old.md" 2>/dev/null || : >"$work/old.md"
if [[ -f "$skill/SKILL.md" && ! -L "$skill/SKILL.md" ]]; then
  cp "$skill/SKILL.md" "$work/new.md"
fi

valid_repo() { [[ "$1" =~ ^https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ && "$1" != */. && "$1" != */.. ]]; }
valid_path() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && ${#1} -le 400 && "$1" != /* && "/$1/" != */../* && "/$1/" != */./* ]]; }
valid_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
valid_ref() {
  valid_sha "$1" && return 0
  [[ "$1" =~ ^refs/(heads|tags)/[A-Za-z0-9._/-]{1,200}$ ]] && git check-ref-format "$1" 2>/dev/null
}

# field <file> <key> <validator>: the metadata value when it passes the validator, else nothing.
field() {
  local value
  value="$(metadata "$1" "$2")"
  case "$2" in
    github-repo) value="${value%.git}" ;;
    github-path) value="${value%/}" ;;
  esac
  if "$3" "$value"; then printf '%s\n' "$value"; fi
  return 0
}
old_repo="$(field "$work/old.md" github-repo valid_repo)"
old_path="$(field "$work/old.md" github-path valid_path)"
old_tree="$(field "$work/old.md" github-tree-sha valid_sha)"
old_ref="$(field "$work/old.md" github-ref valid_ref)"
new_repo="$(field "$work/new.md" github-repo valid_repo)"
new_path="$(field "$work/new.md" github-path valid_path)"
new_tree="$(field "$work/new.md" github-tree-sha valid_sha)"
new_ref="$(field "$work/new.md" github-ref valid_ref)"

# The source of this update is the new copy. Only a removed skill falls back to its old source; an
# invalid new field stays unknown rather than borrowing the previous source's value.
repo="$new_repo"
path="$new_path"
if [[ ! -s "$work/new.md" ]]; then
  repo="$old_repo"
  path="$old_path"
fi
same_source=true
if [[ "$old_repo" != "$new_repo" || "$old_path" != "$new_path" ]]; then
  same_source=false
fi

owner=""
name=""
if [[ -n "$repo" ]]; then
  slug="${repo#https://github.com/}"
  owner="${slug%%/*}"
  name="${slug#*/}"
fi

# ── the repository: archived, or redirecting after a rename ──────────────────────────────────
state="unknown (the repository could not be read)"
if [[ -z "$owner" || -z "$path" ]]; then
  state="unknown (the skill's metadata names no valid upstream repository and path)"
  warn "The skill's metadata names no valid upstream repository and path, so nothing upstream could be checked."
else
  if gh api "repos/$owner/$name" >"$work/repo.json" 2>"$work/repo.err" &&
    jq -r '[(.full_name // ""), (if has("archived") then (.archived | tostring) else "unknown" end)] | @tsv' "$work/repo.json" \
      >"$work/repo.tsv" 2>/dev/null; then
    IFS=$'\t' read -r full_name archived <"$work/repo.tsv" || true
    lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
    case "$archived" in
      true) state="archived" ;;
      false) state="active" ;;
      *) state="unknown (GitHub did not say whether it is archived)" ;;
    esac
    if [[ ! "$full_name" =~ ^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$ ]]; then
      state="unknown (GitHub returned no usable name)"
    elif [[ "$(lower "$full_name")" != "$(lower "$owner/$name")" ]]; then
      state="$state; redirects to \`$full_name\` after a rename"
      warn "The upstream repository was renamed: \`$owner/$name\` now redirects to \`$full_name\`."
    fi
    [[ "$archived" != true ]] || warn "The upstream repository \`$owner/$name\` is archived."
  fi
  [[ "$state" != unknown* ]] || warn "Whether the upstream repository is archived or renamed is unknown."
fi

# ── fetch commits and trees only, then find the commits that hold each tree ──────────────────
bounded() { # <seconds> <command...>
  local seconds="$1" pid watcher rc=0
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@" || rc=$?
    return "$rc"
  fi
  "$@" &
  pid=$!
  (sleep "$seconds" && kill -TERM "$pid" 2>/dev/null) &
  watcher=$!
  wait "$pid" || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# An isolated git: no inherited repository selectors, config, URL rewrites, credential helpers or
# prompts can redirect this public read or run a helper on the host, only https may be fetched (file
# too under the test base), and a missing blob is never fetched behind the reader's back.
git_cmd=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY
  -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG
  -u GIT_ASKPASS -u SSH_ASKPASS
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
  GIT_NO_LAZY_FETCH=1
  git -c core.hooksPath=/dev/null -c credential.helper= -c protocol.allow=never
  -c protocol.https.allow=always)
if [[ -n "${DESCRIBE_SKILL_UPSTREAM_BASE:-}" ]]; then git_cmd+=(-c protocol.file.allow=always); fi
git_cmd+=(-C "$work/upstream.git")
upstream_git() { "${git_cmd[@]}" "$@"; }

fetched=false
old_commit=""
new_commit=""
range_note=""
if [[ -n "$owner" && -n "$path" ]]; then
  base="${DESCRIBE_SKILL_UPSTREAM_BASE:-https://github.com}"
  git init --quiet --bare "$work/upstream.git"
  refspecs=()
  add_ref() { # <ref> <local name>
    local ref="${1:-HEAD}"
    refspecs+=("+$ref:refs/describe/$2")
  }
  add_ref "$new_ref" new
  [[ "$old_ref" == "$new_ref" ]] || add_ref "$old_ref" old
  if bounded "$fetch_seconds" "${git_cmd[@]}" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    fetch --quiet --no-tags --filter=blob:none "$base/$owner/$name.git" "${refspecs[@]}" \
    >"$work/fetch.log" 2>&1; then
    fetched=true
  else
    # One missing ref (an old tag deleted upstream) must not hide the other.
    for spec in "${refspecs[@]}"; do
      if bounded "$fetch_seconds" "${git_cmd[@]}" fetch --quiet --no-tags --filter=blob:none \
        "$base/$owner/$name.git" "$spec" >>"$work/fetch.log" 2>&1; then
        fetched=true
      fi
    done
  fi
fi

# holder <tree> <path> <tip...>: the commit that holds <tree> at <path>. A tip that holds it
# is that commit itself, so a pinned tag whose own commit changed only the licence is read at the tag;
# otherwise the newest commit in the path's history, on the first tip that has one. Prints nothing
# when none is found within the bound.
holder() {
  local tree="$1" p="$2" tip commit
  shift 2
  for tip in "$@"; do
    commit="$(upstream_git rev-parse -q --verify "$tip^{commit}" 2>/dev/null)" || continue
    if [[ "$(upstream_git rev-parse -q --verify "$commit:$p" 2>/dev/null)" == "$tree" ]]; then
      printf '%s\n' "$commit"
      return 0
    fi
    while IFS= read -r commit; do
      if [[ "$(upstream_git rev-parse -q --verify "$commit:$p" 2>/dev/null)" == "$tree" ]]; then
        printf '%s\n' "$commit"
        return 0
      fi
    done < <(upstream_git rev-list --max-count="$max_commits" "$tip" -- "$p" 2>/dev/null)
  done
  return 0
}

if $fetched; then
  tips=(refs/describe/new refs/describe/old)
  [[ -z "$new_tree" ]] || new_commit="$(holder "$new_tree" "$new_path" "${tips[@]}")"
  [[ -z "$old_tree" ]] || old_commit="$(holder "$old_tree" "$old_path" refs/describe/old refs/describe/new)"
fi

# ── the range ────────────────────────────────────────────────────────────────────────────────
count=""
: >"$work/subjects"
if ! $same_source; then
  range_note="the skill's upstream source changed, so there is no single range"
elif [[ -z "$old_tree" || -z "$new_tree" ]]; then
  range_note="a tree SHA is missing or invalid in the skill's metadata"
elif ! $fetched; then
  range_note="the upstream repository could not be fetched"
elif [[ -z "$old_commit" || -z "$new_commit" ]]; then
  range_note="no upstream commit within the last $max_commits that touch the path holds the $([[ -z "$old_commit" ]] && echo old || echo new) tree"
elif ! upstream_git merge-base --is-ancestor "$old_commit" "$new_commit" 2>/dev/null; then
  range_note="the old commit is not an ancestor of the new one"
else
  count="$(upstream_git rev-list --count "$old_commit..$new_commit" -- "$path")"
  upstream_git log --no-show-signature --format='%h %s' --max-count="$max_subjects" \
    "$old_commit..$new_commit" -- "$path" >"$work/subjects"
fi
[[ -z "$range_note" ]] || warn "The upstream range could not be resolved: $range_note."

# ── the licence at each commit ───────────────────────────────────────────────────────────────
# licence_files <commit> <path>: licence-like files at the repository root and in every directory
# down to the skill's own, as `<path> <blob>` lines. Only names matching a fixed pattern are kept,
# so none can carry markup, and a blob SHA tells a changed text apart without reading it.
licence_files() {
  local dir="" rest="$2/" part
  while :; do
    upstream_git ls-tree "$1:$dir" 2>/dev/null |
      awk -v prefix="$dir" -F '\t' 'tolower($2) ~ /^(licen[cs]e|copying|notice)([._-][a-z0-9._-]*)?$/ {
        split($1, meta, " ")
        if (meta[2] == "blob") print prefix $2 " " substr(meta[3], 1, 12)
      }'
    [[ -n "$rest" ]] || break
    part="${rest%%/*}"
    rest="${rest#*/}"
    dir="$dir$part/"
  done
}
# licence_name <commit>: GitHub's SPDX identifier for the root licence, `none detected`, or nothing.
licence_name() {
  local id
  if gh api "repos/$owner/$name/license?ref=$1" >"$work/licence.json" 2>"$work/licence.err"; then
    id="$(jq -r '.license.spdx_id // empty' "$work/licence.json" 2>/dev/null || true)"
    if [[ "$id" =~ ^[A-Za-z0-9.+-]{1,64}$ ]]; then printf '%s\n' "$id"; fi
  elif grep -qF 'HTTP 404' "$work/licence.err"; then
    echo "none detected"
  fi
  return 0
}
# describe_licence <commit> <path> <side>: writes <side>.files and <side>.id, prints the rendering.
describe_licence() {
  local id files
  licence_files "$1" "$2" >"$work/$3.files"
  id="$(licence_name "$1")"
  printf '%s\n' "$id" >"$work/$3.id"
  # At most $max_licence_files are listed, each name at most 100 bytes, so the list stays bounded.
  files="$(awk -v max="$max_licence_files" '
    length($1) > 100 { long++; next }
    shown < max { printf "%s`%s` (`%s`)", (shown > 0 ? ", " : ""), $1, $2; shown++; next }
    { more++ }
    END { if (more + long > 0) printf "%sand %d more", (shown > 0 ? ", " : ""), more + long }' "$work/$3.files")"
  printf '%s; %s\n' "${id:-unknown}" "${files:-no licence file found}"
}
old_licence="unknown"
new_licence="unknown"
licence_changed=""
[[ -z "$old_commit" ]] || old_licence="$(describe_licence "$old_commit" "$old_path" old)"
[[ -z "$new_commit" ]] || new_licence="$(describe_licence "$new_commit" "$new_path" new)"
if [[ -z "$old_commit" || -z "$new_commit" ]]; then
  warn "The licence at the old and the new commit could not be compared."
elif ! cmp -s "$work/old.files" "$work/new.files"; then
  licence_changed=true
elif [[ -n "$(cat "$work/old.id")" && -n "$(cat "$work/new.id")" ]] && ! cmp -s "$work/old.id" "$work/new.id"; then
  licence_changed=true
elif [[ ! -s "$work/old.files" ]] && [[ -z "$(cat "$work/old.id")" || -z "$(cat "$work/new.id")" ]]; then
  # No licence file to compare by content, and GitHub's reading is missing at one end.
  warn "The licence at the old and the new commit could not be compared."
fi
[[ -z "$licence_changed" ]] || warn "The upstream licence changed between the old and the new commit."

# ── render ───────────────────────────────────────────────────────────────────────────────────
code() { if [[ -n "$1" ]]; then printf '`%s`' "$1"; else printf 'unknown'; fi; }
commit_link() { # <tree> <commit> <upstream path at that commit>
  if [[ -z "$1" ]]; then
    printf 'unknown'
  elif [[ -n "$2" ]]; then
    printf '`%s` in [`%s`](https://github.com/%s/%s/tree/%s/%s)' "$1" "${2:0:12}" "$owner" "$name" "$2" "$3"
  else
    printf '`%s` in an unknown commit' "$1"
  fi
}
# sanitise: one subject per line in, inert text out. Control characters go first, then `@`, `#`,
# `GH-` references and URL schemes become look-alikes, then each line is capped.
sanitise() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' |
    LC_ALL=C sed -e 's/@/＠/g' -e 's/#/＃/g' -e 's/[Gg][Hh]-/GH‐/g' -e 's#://#:∕∕#g' \
      -e 's/[Ww][Ww][Ww]\./www․/g' |
    LC_ALL=C cut -b "1-$max_subject_bytes" |
    valid_utf8
}
# valid_utf8: drops byte sequences that are not UTF-8, such as a character the cap cut in half.
valid_utf8() {
  if command -v iconv >/dev/null 2>&1; then
    iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
  else
    LC_ALL=C tr -d '\200-\377'
  fi
}
fence_for() { # <file>: a backtick fence longer than any backtick run in the file
  local longest
  longest="$(LC_ALL=C awk '{ s = $0; while (match(s, /`+/)) { if (RLENGTH > n) n = RLENGTH; s = substr(s, RSTART + RLENGTH) } } END { print n + 0 }' "$1")"
  ((longest >= 3)) || longest=2
  printf '%*s' "$((longest + 1))" '' | tr ' ' '`'
}

sanitise <"$work/subjects" >"$work/subjects.safe"

# The body stays far below GitHub's limit by construction: every table value is pattern-bounded or
# capped, and at most $max_subjects subjects of at most $max_subject_bytes bytes are listed. The size
# is still checked at the end: an oversized body fails, so the caller's fallback body is used.
{
  if ((${#warnings[@]} > 0)); then
    echo "> [!WARNING]"
    for entry in "${warnings[@]}"; do echo "> - $entry"; done
    echo
  fi
  echo "Automated update of the agent skill at \`$skill\` to its latest version."
  echo
  echo "Each changed skill gets its own pull request, so one blocked update does not hold back the others."
  echo
  echo "## Upstream"
  echo
  echo "| Fact | Value |"
  echo "| --- | --- |"
  if [[ -n "$owner" ]]; then echo "| Repository | https://github.com/$owner/$name |"; else echo "| Repository | unknown |"; fi
  echo "| Path | $(code "$path") |"
  if ! $same_source; then
    echo "| Previous source | $(code "${old_repo#https://github.com/}") at $(code "$old_path") |"
  fi
  echo "| Repository state | $state |"
  echo "| Old tree | $(commit_link "$old_tree" "$old_commit" "$old_path") |"
  echo "| New tree | $(commit_link "$new_tree" "$new_commit" "$new_path") |"
  if [[ -z "$range_note" ]]; then
    echo "| Compare | https://github.com/$owner/$name/compare/$old_commit...$new_commit |"
    echo "| Commits touching the path | $count |"
  else
    echo "| Compare | unknown: $range_note |"
    echo "| Commits touching the path | unknown |"
  fi
  echo "| Licence at the old commit | $old_licence |"
  echo "| Licence at the new commit | $new_licence$([[ -z "$licence_changed" ]] || echo " (**changed**)") |"
  if [[ -z "$range_note" && -s "$work/subjects.safe" ]]; then
    shown="$(wc -l <"$work/subjects.safe" | tr -d ' ')"
    fence="$(fence_for "$work/subjects.safe")"
    echo
    echo "### Upstream commit subjects"
    echo
    echo "Untrusted upstream text, shown as data. At signs, hash signs, GH- references and link schemes are replaced with look-alikes, so nothing in it links, closes or notifies anything here."
    echo
    echo "${fence}text"
    cat "$work/subjects.safe"
    echo "$fence"
    if ((count > shown)); then
      echo
      echo "And $((count - shown)) more; see the compare link."
    fi
  fi
} >"$work/body.md"
if (($(wc -c <"$work/body.md") > max_body_bytes)); then
  echo "describe-skill-update: the description exceeds $max_body_bytes bytes" >&2
  exit 3
fi
cat "$work/body.md"

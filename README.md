# Update Agent Skills

Run [`gh skill update --all`](https://github.blog/changelog/2026-04-16-manage-agent-skills-with-github-cli/) against installed skills and report any changes. Pairs with [`setup-agent-skills`](https://github.com/devantler-tech/setup-agent-skills-action).

The `github-*` frontmatter that `gh skill install` injects into each `SKILL.md` (github-repo, github-path, github-ref, github-tree-sha) is the source of truth — this action asks the CLI to refresh those skills against their upstreams, then reports whether any file in a skill's directory changed. It is agent-neutral: it operates on the `SKILL.md` files in `dir`, so it refreshes skills installed for any agent (Copilot, Claude Code, …). No lockfile.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `dir` | Directory to scan for installed skills. The action finds every `SKILL.md` under this path, uses its immediate parent (the directory containing individual skill subdirectories, e.g. `skills/`) as the `--dir` argument, and runs `gh skill update --all --dir <skills-dir>` for each unique `<skills-dir>`. This supports both the standard layout (`.agents/skills/`) and nested layouts like `plugins/<plugin>/skills/<skill>/`. | ❌ | `.` |
| `dry-run` | When `true`, pass `--dry-run` (report without modifying files) | ❌ | `false` |
| `unpin` | When `true`, pass `--unpin` (clear pinned versions and include pinned skills) | ❌ | `false` |
| `mark-internal` | When `true`, set `metadata.internal: true` on every `SKILL.md` under `dir` after updating. Tools that honour the flag, such as `npx skills`, then stop offering vendored development skills as if the repository published them. It runs on every update because an upstream change replaces the whole file, leaves already-marked files untouched, and is skipped with `dry-run`. Requires mikefarah `yq` v4 (preinstalled on GitHub-hosted runners). | ❌ | `false` |
| `pins` | Skills to hold at a reviewed upstream commit, one per line as `<skill-dir> <40-character commit>`. See [Holding a skill at a commit](#holding-a-skill-at-a-commit). Cannot be combined with `unpin`. | ❌ | `""` |
| `gh-version` | Minimum required `gh` version (must support `gh skill`) | ❌ | `2.90.0` |
| `github-token` | GitHub token exposed to `gh` as `GH_TOKEN` | ❌ | `${{ github.token }}` |

Set `dir` to a directory containing skills, such as `.agents/skills`, rather than an individual
skill directory. An input that itself contains `SKILL.md` is refused before any update or pin is
applied, so its sibling skills cannot be changed outside the requested scope.

## Outputs

| Name | Description |
|------|-------------|
| `changed` | `true` when any file in an installed skill's directory (the directory holding its `SKILL.md`) was added, removed or modified — content, executable bit or symlink target — so an update that touches only a bundled script, reference or template still counts; `false` otherwise |
| `updated-skills` | Cleaned stdout from `gh skill update --all`, or `No installed skills found.` for an empty scan. Use `changed` to detect changes. |

## Usage

### Scheduled update PR

When using `GITHUB_TOKEN` to open the pull request, enable **Allow GitHub Actions to create and approve pull requests** in the repository's [Actions settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository). The job permissions below do not enable that repository setting.

```yaml
name: 🔄 Update Agent Skills

on:
  schedule:
    - cron: "0 6 * * *"
  workflow_dispatch:

permissions: {}

jobs:
  update:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@<full-commit-sha> # vX.Y.Z
        with:
          persist-credentials: false

      - id: update
        uses: devantler-tech/update-agent-skills-action@<full-commit-sha> # vX.Y.Z
        with:
          dir: .agents/skills

      - if: steps.update.outputs.changed == 'true'
        uses: peter-evans/create-pull-request@<full-commit-sha> # vX.Y.Z
        with:
          sign-commits: true
          token: ${{ github.token }}
          branch-token: ${{ github.token }}
          commit-message: "chore(deps): update agent skills"
          title: "chore(deps): update agent skills"
          body: |
            ```
            ${{ steps.update.outputs.updated-skills }}
            ```
          branch: deps/agent-skills-update
          labels: dependencies,automation
```

For scheduled, signed update PRs, use the [reusable update workflow](docs/update-workflow.md), including its inputs and credential requirements.

### Plugin directory layout

For repositories that organise skills into subdirectories (e.g. a plugin marketplace):

```yaml
# plugins/
#   go/skills/golang-pro/SKILL.md
#   github/skills/github-issues/SKILL.md
#   ...

- id: update
  uses: devantler-tech/update-agent-skills-action@<full-commit-sha> # vX.Y.Z
  with:
    dir: plugins   # discovers plugins/go/skills, plugins/github/skills, … and updates each
```

### Holding a skill at a commit

When a new upstream version of one skill is unsafe for your repository, hold that skill at the commit you already reviewed and let every other skill keep updating:

```yaml
- id: update
  uses: devantler-tech/update-agent-skills-action@<full-commit-sha> # vX.Y.Z
  with:
    dir: .agents/skills
    pins: |
      # Remove once owner/repo#123 is fixed upstream.
      .agents/skills/git-commit 0123456789abcdef0123456789abcdef01234567
```

Each line names an installed skill directory under `dir` and a full 40-character upstream commit; blank lines and `#` comments are ignored. Before updating, the action reinstalls each listed skill from the repository and path in its own `github-*` metadata with `gh skill install --pin`, replacing the whole skill directory with the content of that commit and recording `metadata.github-pinned`. `gh skill update --all` then skips it, so the pin arrives in the normal update pull request. A run with the same pins changes nothing. A short or malformed commit, a directory that is not an installed skill, a skill outside `dir` or a repeated skill fails the run before any skill changes; it never falls back to an unpinned update. With `dry-run` the pins are validated and reported, not applied. `mark-internal` still applies to a pinned skill.

A pin is a temporary hold, not a fork: name the issue that tracks its removal in a comment, and remove the line once the upstream problem is fixed. Removing the line does not release the skill by itself, because its `metadata.github-pinned` stays; reinstall the skill without `--pin`, or run once with `unpin: true`, which clears every pin under `dir`, to release it.

## Requirements

- A trusted runner-provided `gh` with `gh attestation` support. Same bootstrap behaviour as `setup-agent-skills`: if it is older than **2.90.0**, the action downloads the required GitHub CLI release archive on Linux or macOS (amd64/arm64) and verifies its GitHub artifact attestation before installation. Windows runners must pre-install `gh >= 2.90.0`.

## Release recovery

Releases run from protected `main`. To preview the next release without writing
anything, dispatch the `Release` workflow on `main` with `dry-run` enabled:

```sh
gh workflow run release.yaml --ref main -f dry-run=true
```

A dry run previews semantic-release's next version or reports that no release is
needed. It does not recreate a missing GitHub release for an existing tag.
If a release fails before creating its tag, repair the failure and rerun the
workflow from `main`.

If the tag was pushed but its GitHub release is missing, first verify that the
existing tag resolves to the intended reviewed commit on protected `main` and
that its CI passed. In the repository's **Releases** page, choose **Draft a new
release**, select that **existing tag**, generate and review its release notes,
and publish. Select **Publish this Action to the GitHub Marketplace** if the
release also needs to be listed there. Confirm the published release's source
commit and Marketplace version afterward. Do not move or delete the tag, or
try to edit an immutable release; use a new patch release at the same reviewed
commit if a published immutable release needs a separate Marketplace listing.

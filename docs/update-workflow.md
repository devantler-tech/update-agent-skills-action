<a name="workflow-update-agent-skills"></a>

### 🔄 Update Agent Skills

This reusable workflow runs on GitHub.com, using its self repository references and workflow identity contexts.

<details>
<summary>Purpose, interface and usage</summary>

[.github/workflows/update-agent-skills.yaml](../.github/workflows/update-agent-skills.yaml) is a workflow used to keep installed agent skills (Copilot, Claude Code, …) up-to-date via [`gh skill update --all`](https://github.blog/changelog/2026-04-16-manage-agent-skills-with-github-cli/), opening a PR with any changes. Each installed `SKILL.md`'s `metadata.github-*` frontmatter is the source of truth — no lockfile is required. Works with any mix of `gh skill`-compatible upstreams.

#### Usage

```yaml
on:
  schedule:
    - cron: "0 6 * * *"
  workflow_dispatch:

jobs:
  update-agent-skills:
    uses: devantler-tech/update-agent-skills-action/.github/workflows/update-agent-skills.yaml@<full-commit-sha> # vX.Y.Z
    permissions:
      contents: write
      pull-requests: write
    with:
      dir: .agents/skills
      # Optional: keep vendored skills out of `npx skills add <owner>/<repo>` listings.
      mark-internal: true
```

The workflow assumes skills were previously installed with [`devantler-tech/setup-agent-skills-action`](https://github.com/devantler-tech/setup-agent-skills-action) (or `gh skill install` directly) — the committed `SKILL.md` files carry the upstream pointers.

With the default `GITHUB_TOKEN`, enable **Allow GitHub Actions to create and approve pull requests** in the repository's [Actions settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository). Job permissions alone do not enable it.

To use a GitHub App instead, configure the caller's `APP_CLIENT_ID` variable and forward its private-key secret explicitly:

```yaml
jobs:
  update-agent-skills:
    uses: devantler-tech/update-agent-skills-action/.github/workflows/update-agent-skills.yaml@<full-commit-sha> # vX.Y.Z
    permissions:
      contents: write
      pull-requests: write
    with:
      dir: .agents/skills
      use-app-token: true
    secrets:
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```

#### Secrets and Inputs

| Key              | Type            | Default                              | Required | Description                                                            |
|------------------|-----------------|--------------------------------------|----------|------------------------------------------------------------------------|
| `dir`            | Input (string)  | `.`                                  | No       | Directory to scan for installed skills (passed to `gh skill update --dir`) |
| `unpin`          | Input (boolean) | `false`                              | No       | When `true`, pass `--unpin` (clear pinned versions)                    |
| `mark-internal`  | Input (boolean) | `false`                              | No       | When `true`, set `metadata.internal: true` on every `SKILL.md` under `dir` after updating, so `npx skills` stops offering vendored skills as the repository's own |
| `pins`           | Input (string)  | `""`                                 | No       | Skills to hold at a reviewed upstream commit, one per line as `<skill-dir> <40-character commit>` (`#` comments allowed). Each is reinstalled at that commit with `gh skill install --pin` before updating, so the update PR carries the pin and every other skill keeps updating. Any invalid line fails the run; cannot be combined with `unpin` |
| `gh-version`     | Input (string)  | `2.90.0`                             | No       | Minimum required `gh` version (must support `gh skill`)                |
| `pr-per-skill`   | Input (boolean) | `false`                              | No       | When `true`, open one PR per changed skill (from `<pr-branch>-<skill>`, titled `<pr-title> (<skill path>)`) so a blocked skill holds back only itself; a change outside every skill fails the run. Opt in only once any follow-up job, auto-merge rule or review exemption matching the exact `pr-branch` also accepts the per-skill branches. The `skills` output lists each skill and its branch suffix |
| `pr-branch`      | Input (string)  | `deps/agent-skills-update`           | No       | Branch the update PR is opened from                                    |
| `pr-title`       | Input (string)  | `chore(deps): update agent skills`   | No       | Title of the update PR                                                 |
| `pr-labels`      | Input (string)  | `dependencies,automation`            | No       | Comma-separated labels for the update PR                               |
| `commit-message` | Input (string)  | `chore(deps): update agent skills`   | No       | Commit message for the update PR                                       |
| `dry-run`        | Input (boolean) | `false`                              | No       | Skip update and PR creation (validate workflow interface only)         |
| `use-app-token` | Input (boolean) | `false` | No | Create the update PR with a GitHub App token so it triggers the caller's CI |
| `APP_PRIVATE_KEY` | Secret | - | When `use-app-token` is true | GitHub App private key, paired with the `APP_CLIENT_ID` variable |

> **Note:** The calling workflow must grant `contents: write` and `pull-requests: write` permissions.

</details>

### GitHub CLI digest maintenance

This repository refreshes its declared GitHub CLI release digests weekly and on demand through
[the reviewed digest updater](../.github/workflows/refresh-gh-digests.yaml). It resolves the shared
installer version, validates every supported platform, then opens or returns to draft a signed PR
containing only the digest manifest. No-change runs mint no write token. The draft must pass normal
review and CI before its digests become installer authority; unsupported custom versions retain
their warning and existing verification behavior.


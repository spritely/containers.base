# containers.base

Creates a base devcontainer with various rudimentary tools preinstalled like apply-templates, zsh, and AI tools like claude code and codex.

Published container is available from: https://hub.docker.com/repository/docker/spritelydev/base-devcontainer

## Testing

### Automated tests

Open the repo in the devcontainer (VS Code > "Reopen in Container" or `devcontainer up --workspace-folder .`), then run:

```bash
bats ./tests/
```

Tests verify that all installed tools match their pinned versions and that developer tools are present and environment configuration is correct.

## Renovate schedule

Renovate runs on a tiered schedule to support cascading dependency updates across repos. Each tier runs twice — once to create PRs and again to automerge after CI passes.

This repo is **tier 0** (root dependency):

| Time (UTC) | What happens |
| ---------- | ------------ |
| 5:00 | Run 1: Create PRs |
| 5:10 | Run 2: Automerge after CI passes |

Downstream repos should offset their schedules by another 10+ minutes to ensure this repo has completed its automerge.

| Tier | Run 1 | Run 2 | Example repos |
| ---- | ----- | ----- | ------------- |
| 0 | 5:00 | 5:10 | containers.base |
| 1 | 5:20 | 5:30 | (repos that depend on containers.base) |
| 2 | 5:40 | 5:50 | (repos that depend on tier 1) |

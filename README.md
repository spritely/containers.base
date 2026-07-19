# containers.base

Creates a base devcontainer with various rudimentary tools preinstalled like apply-templates, zsh, and AI tools like claude code and codex.

This image is a least-common-denominator base shared by both Ubuntu- and Debian-based downstream containers, most of which run privileged — this repo's own devcontainer does not. Setup logic should degrade gracefully rather than assume either trait; avoid adding packages or privileges here just to support one downstream case.

Published container is available from: https://hub.docker.com/repository/docker/spritelydev/base-devcontainer

## Testing

### Automated tests

Open the repo in the devcontainer (VS Code > "Reopen in Container" or `devcontainer up --workspace-folder .`), then run:

```bash
bats ./tests/
```

Tests verify that all installed tools match their pinned versions and that developer tools are present and environment configuration is correct.

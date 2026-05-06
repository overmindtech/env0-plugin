# Overmind env0 Plugin

This plugin integrates [Overmind](https://www.overmind.tech/) with env0 to track infrastructure changes and deployments.

## Overview

The Overmind plugin installs the Overmind CLI (and GitHub CLI) and executes one of four actions:

- **submit-plan**: Submits a Terraform plan to Overmind for analysis
- **start-change**: Marks the beginning of a change in Overmind
- **end-change**: Marks the completion of a change in Overmind
- **wait-for-simulation**: Retrieves simulation output from Overmind and comments on the relevant GitHub PR or GitLab MR

## Inputs

| Input              | Description                                                                                                                                                                                                 | Required |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `action`           | The action to perform. Must be one of: `submit-plan`, `start-change`, `end-change`, `wait-for-simulation`                                                                                                   | Yes      |
| `api_key`          | Overmind API key for authentication. Must have the following scopes: `account:read`, `changes:write`, `config:write`, `request:receive`, `sources:read`, `source:write`                                     | Yes      |
| `tags`             | A comma-separated list of key=value tags to attach to the change (only used with `submit-plan` action)                                                                                                      | No       |
| `post_comment`     | Whether `wait-for-simulation` should post the Overmind markdown to GitHub PR or GitLab MR. Defaults to `true` when running against a PR/MR, otherwise `false`. When `true`, `comment_provider` must be set. | No       |
| `comment_provider` | Where `wait-for-simulation` should post comments when `post_comment=true`. Must be one of: `github`, `gitlab`.                                                                                              | No       |
| `on_failure`       | Behavior when the plugin step errors. `fail` (default) fails the step and blocks the deployment; `pass` allows the deployment to continue even if this step errors. Must be one of: `fail`, `pass`.         | No       |
| `skip_after_approval` | When `true` (default), `submit-plan` exits early once a deployment has been approved (`ENV0_REVIEWER_NAME` is set), avoiding duplicate analysis from the post-approval re-plan. Set to `false` to submit on every plan. | No       |

## Usage

### Submit Plan (after terraformPlan)

Submit a Terraform plan to Overmind for analysis:

```yaml
version: 2
deploy:
  steps:
    terraformPlan:
      after:
        - name: Submit Plan to Overmind
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: submit-plan
            api_key: ${OVERMIND_API_KEY}
```

You can optionally attach tags to the change:

```yaml
version: 2
deploy:
  steps:
    terraformPlan:
      after:
        - name: Submit Plan to Overmind
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: submit-plan
            api_key: ${OVERMIND_API_KEY}
            tags: environment=production,team=platform
```

### Start Change (before terraformApply)

Mark the beginning of a change in Overmind:

```yaml
version: 2
deploy:
  steps:
    terraformApply:
      before:
        - name: Mark Change Started
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: start-change
            api_key: ${OVERMIND_API_KEY}
```

### End Change (after terraformApply)

Mark the completion of a change in Overmind:

```yaml
version: 2
deploy:
  steps:
    terraformApply:
      after:
        - name: Mark Change Finished
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: end-change
            api_key: ${OVERMIND_API_KEY}
```

### Wait for Simulation (any step after Overmind run)

Fetch the latest Overmind simulation summary for the current env0 deployment and (optionally) comment on the matching GitHub pull request or GitLab merge request. By default the plugin posts comments whenever the deployment runs in the context of a PR/MR; set `post_comment: false` to skip commenting. When `post_comment=true`, you must set `comment_provider` to `github` or `gitlab`. When posting to GitHub, make sure `GH_TOKEN` is set. When posting to GitLab, make sure `GITLAB_TOKEN` is set.

```yaml
version: 2
deploy:
  steps:
    terraformPlan:
      after:
        - name: Post Overmind Simulation
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: wait-for-simulation
            api_key: ${OVERMIND_API_KEY}
            post_comment: false # optional override
```

If you want to post a comment, set `comment_provider` explicitly:

```yaml
version: 2
deploy:
  steps:
    terraformPlan:
      after:
        - name: Post Overmind Simulation (GitHub)
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: wait-for-simulation
            api_key: ${OVERMIND_API_KEY}
            post_comment: true
            comment_provider: github
```

```yaml
version: 2
deploy:
  steps:
    terraformPlan:
      after:
        - name: Post Overmind Simulation (GitLab)
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: wait-for-simulation
            api_key: ${OVERMIND_API_KEY}
            post_comment: true
            comment_provider: gitlab
```

On GitLab, the plugin **updates** the merge-request comment on each run instead of adding a new comment every time (see [GitLab MR comments](#gitlab-merge-request-comments) below). On GitHub, each run still adds a **new** PR comment via `gh pr comment`; update-in-place for GitHub is not implemented in this plugin yet.

### Self-Hosted GitLab

For self-hosted GitLab environments where `ENV0_PR_SOURCE_REPOSITORY` is not available, the plugin falls back to `ENV0_TEMPLATE_REPOSITORY` to derive the GitLab API URL for posting merge request comments.

For authentication, the plugin uses `GITLAB_TOKEN` if set, otherwise falls back to `ENV0_VCS_ACCESS_TOKEN`.

**GitLab token scopes:** The plugin calls `GET /api/v4/user` (needs **`read_user`**, or a broader scope that includes it) and lists/creates/updates merge request notes (needs **`api`** or equivalent project access with comment permissions). A classic personal access token with the **`api`** scope satisfies both. Narrower token setups must include at least `read_user` plus whatever GitLab requires for MR note read/write on your instance.

```yaml
version: 2
deploy:
  steps:
    terraformPlan:
      after:
        - name: Submit Plan to Overmind
          use: https://github.com/overmindtech/env0-plugin
          inputs:
            action: submit-plan
            api_key: ${OVERMIND_API_KEY}

    terraformApply:
      after:
        - name: Post Overmind Simulation (Self-Hosted GitLab)
          use: https://github.com/overmindtech/env0-plugin
          inputs:
            action: wait-for-simulation
            api_key: ${OVERMIND_API_KEY}
            post_comment: true
            comment_provider: gitlab
```

No `GITLAB_TOKEN` is needed if `ENV0_VCS_ACCESS_TOKEN` is already available in your env0 environment.

### Fail-safe: allow deployment to continue on plugin errors

By default, if the plugin step fails (e.g. Overmind API error, missing env var, network issue), env0 treats the step as failed and can block the deployment. To allow the deployment to continue even when this step errors, set `on_failure: pass`:

```yaml
- name: Submit Plan to Overmind
  use: https://github.com/your-org/env0-plugin
  inputs:
    action: submit-plan
    api_key: ${OVERMIND_API_KEY}
    on_failure: pass # deployment continues even if this step fails
```

Use `on_failure: pass` when the Overmind integration is optional and you do not want plugin failures to block deployments.

### Complete Example

Here's a complete example that uses the plan/change lifecycle actions:

```yaml
version: 2
deploy:
  steps:
    terraformPlan:
      after:
        - name: Submit Plan to Overmind
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: submit-plan
            api_key: ${OVERMIND_API_KEY}

    terraformApply:
      before:
        - name: Mark Change Started
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: start-change
            api_key: ${OVERMIND_API_KEY}
      after:
        - name: Mark Change Finished
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: end-change
            api_key: ${OVERMIND_API_KEY}
```

> **Note:** By default, `submit-plan` runs only on the first plan (typically the PR/MR plan). The post-approval re-plan is automatically skipped to avoid duplicate Overmind analysis. Set `skip_after_approval: false` to submit on every plan.

## How It Works

1. **Installation**: The plugin automatically installs the latest version of the Overmind CLI and GitHub CLI (for GitHub support) to a writable directory in your PATH. GitLab support uses `curl` which is typically available on most systems.

2. **Supply-chain verification**: Every binary the plugin downloads is cryptographically verified against the producer workflow's GitHub Artifact Attestation (SLSA build provenance v1) before it is executed. See [Supply-chain verification](#supply-chain-verification) below.

3. **Authentication**: The API key provided in the `api_key` input is set as the `OVERMIND_API_KEY` environment variable.

4. **Action Execution**: Based on the `action` input, the plugin executes the corresponding Overmind/GitHub/GitLab workflow:
   - `submit-plan`: Uses `$ENV0_TF_PLAN_JSON` to submit the Terraform plan
   - `start-change`: Marks the beginning of a change with a ticket link to the env0 deployment
   - `end-change`: Marks the completion of a change with a ticket link to the env0 deployment
   - `wait-for-simulation`: Retrieves Overmind simulation results as Markdown and (when `post_comment=true`) posts them to the GitHub PR or GitLab MR per `comment_provider` (GitLab updates the comment in place).

5. **Ticket Links**: When `ENV0_PR_NUMBER` is set (i.e., the deployment is triggered by a PR/MR), the plugin constructs a stable merge request URL from `ENV0_PR_SOURCE_REPOSITORY` (or `ENV0_TEMPLATE_REPOSITORY` as a fallback) and `ENV0_PR_NUMBER`. This ensures multiple plans for the same MR update the same Overmind change. For non-PR deployments, the ticket link falls back to the env0 deployment URL.

6. **Post-Approval Re-Plan Gating**: env0 always re-runs `terraformPlan` between approval and apply, even when the code hasn't changed. By default (`skip_after_approval: true`), the plugin detects this by checking `ENV0_REVIEWER_NAME` (set by env0 after a reviewer approves) and skips the redundant `submit-plan`. This avoids duplicate Overmind analysis and prevents `start-change` from waiting on a second analysis that no human will review. Set `skip_after_approval: false` if you need both submissions (e.g. auto-deploy environments with no prior PR plan).

## Supply-chain verification

The plugin downloads two binaries from public GitHub Releases at runtime — the Overmind CLI from [`overmindtech/cli`](https://github.com/overmindtech/cli) and (only for `wait-for-simulation` with `comment_provider: github`) the GitHub CLI from [`cli/cli`](https://github.com/cli/cli). Both releases publish [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds) carrying [SLSA build provenance v1](https://slsa.dev/spec/v1.0/provenance). The plugin verifies the attestation of each archive **before** extracting and executing the binary inside it.

### What the plugin checks

For every downloaded archive:

- The archive's SHA-256 digest is signed by Sigstore's public-good infrastructure (Fulcio cert + Rekor transparency log).
- The signing certificate's Subject Alternative Name matches `https://github.com/<owner>/<repo>/.github/workflows/release.yml@refs/tags/v*`. This binds the artifact to the producer workflow in the producer repository, so a release built from a fork (or from any other workflow file) fails verification.
- The OIDC issuer is `https://token.actions.githubusercontent.com`. This binds the workflow to a real GitHub Actions run.

Specifically, the producer identities pinned by the plugin are:

| Archive            | Repo               | Signer workflow                       |
|--------------------|--------------------|---------------------------------------|
| Overmind CLI       | `overmindtech/cli` | `.github/workflows/release.yml` on a `v*` tag |
| GitHub CLI (`gh`)  | `cli/cli`          | `.github/workflows/release.yml` on a `v*` tag |

### Verification path

The plugin tries the cheaper path first and falls back to the heavier one only when needed:

1. **`gh attestation verify` (preferred)** — if `gh` is already on `PATH` and supports `attestation verify` (GitHub CLI 2.49+), the plugin runs a single `gh attestation verify <archive> --repo <owner>/<repo> --signer-workflow <owner>/<repo>/.github/workflows/release.yml --cert-oidc-issuer https://token.actions.githubusercontent.com` and is done. No new binaries are introduced on the runner.
2. **`cosign` fallback** — if `gh` is missing or too old, the plugin downloads a pinned version of [Sigstore `cosign`](https://github.com/sigstore/cosign), checks it against a pinned SHA-256 (the bootstrap trust anchor; bumped via Renovate), fetches the attestation bundle from `https://api.github.com/repos/<owner>/<repo>/attestations/sha256:<digest>`, and verifies it with `cosign verify-blob-attestation --new-bundle-format ...` against the same signer-workflow identity.

The cosign fallback works on Linux/Darwin amd64+arm64 and Windows amd64 (the platforms cosign publishes binaries for). On other platforms (e.g. Linux i386), the plugin requires `gh` 2.49+ to be pre-installed on the runner and fails loudly otherwise.

### Network requirements

For verification to succeed, the env0 runner needs outbound HTTPS to:

- `api.github.com` (attestation index, GitHub CLI release metadata)
- `github.com` and `objects.githubusercontent.com` (release archive + cosign download)
- `tuf-repo-cdn.sigstore.dev` and `rekor.sigstore.dev` (Sigstore trust root + transparency log)

Setting `GH_TOKEN` (or `GITHUB_TOKEN`) raises GitHub API rate limits but is not required for verification of public-repo attestations.

### Failure mode

A verification failure causes the plugin to exit non-zero with a clear error message and the binary is **never** executed. **`on_failure: pass` does not bypass this** — it is reserved for runtime / API errors (e.g. Overmind unreachable), not supply-chain failures. The exit code reserved for supply-chain failures is `99`.

If you see a verification failure on a clean runner, the most common causes are:

1. The runner cannot reach the Sigstore endpoints listed above.
2. A new Overmind CLI release has been published without attestations (regression on the producer side — please file an issue).
3. The cosign SHA-256 pin in the plugin is stale relative to the cosign version it tries to download (Renovate is responsible for keeping these in sync; manual fix is `sh scripts/update-cosign-pins.sh` after bumping `COSIGN_VERSION`).

## Requirements

- The plugin requires env0 environment variables to be available:
  - `ENV0_PROJECT_ID`
  - `ENV0_ENVIRONMENT_ID`
  - `ENV0_DEPLOYMENT_LOG_ID`
  - `ENV0_ORGANIZATION_ID`
  - `ENV0_TF_PLAN_JSON` (for submit-plan action)
  - `ENV0_PR_NUMBER` (only when `wait-for-simulation` posts comments, i.e., running against a PR/MR)
  - `ENV0_PR_SOURCE_REPOSITORY` (only when `wait-for-simulation` posts comments to GitHub; for GitLab, falls back to `ENV0_TEMPLATE_REPOSITORY`)

- A valid Overmind API key with the following required scopes:
  - `account:read`
  - `changes:write`
  - `config:write`
  - `request:receive`
  - `sources:read`
  - `source:write`

- GitHub authentication for the CLI when `wait-for-simulation` posts to GitHub (set `GH_TOKEN`).
- GitLab authentication when `wait-for-simulation` posts to GitLab (set `GITLAB_TOKEN`, or rely on `ENV0_VCS_ACCESS_TOKEN` which is automatically available in self-hosted GitLab environments). See [Self-Hosted GitLab](#self-hosted-gitlab) for minimum scopes (`api` on a classic PAT is sufficient).

### Creating a `GH_TOKEN`

`wait-for-simulation` calls `gh pr comment` for GitHub repositories, which requires a GitHub personal access token. To create one:

1. Sign in to GitHub and open https://github.com/settings/tokens/new (or the fine-grained token wizard).
2. Choose **Classic** token, set an expiry that matches your security policy, and select the **repo** scope (read/write is needed to comment on PRs).
3. Generate the token and copy it immediately—GitHub will not show it again.
4. Store the token securely in env0 (for example as an environment variable or secret) and expose it to the plugin as `GH_TOKEN`.

### Creating a `GITLAB_TOKEN`

`wait-for-simulation` uses the GitLab API to post comments on merge requests for GitLab repositories. To create a GitLab personal access token:

1. Sign in to GitLab and navigate to your user settings (or group/project settings for project/group tokens).
2. Go to **Access Tokens** (or **Preferences** > **Access Tokens** for user tokens).
3. Create a new token with the `api` scope (covers `GET /api/v4/user` and merge request note APIs used by this plugin).
4. Generate the token and copy it immediately—GitLab will not show it again.
5. Store the token securely in env0 (for example as an environment variable or secret) and expose it to the plugin as `GITLAB_TOKEN`.

**Note**: When `post_comment=true`, you must set `comment_provider` to `github` or `gitlab`.

### GitLab merge request comments

To **update** the same MR note on each deployment, the plugin looks for a non-system note authored by the token’s user whose body contains the HTML marker `<!-- overmind-change-summary -->`. Overmind’s default markdown includes this marker; if it is missing, the plugin **warns**, **appends** the marker to the posted body, and subsequent runs can match and update that note.

### Pinning plugin version (rollback)

env0 resolves `use: https://github.com/org/env0-plugin` to the default branch unless you pin a revision. To avoid picking up breaking changes—or to roll back after an upgrade—append **`@<ref>`** to the URL (tag, branch, or commit SHA), per [env0’s plugin documentation](https://docs.env0.com/docs/plugins):

```yaml
use: https://github.com/overmindtech/env0-plugin@v1.2.3
# or: https://github.com/overmindtech/env0-plugin@abc1234deadbeef...
```

## Notes

- The plugin automatically detects the operating system and architecture to download the correct Overmind CLI binary.
- The installation directory is automatically selected from writable directories in your PATH.
- For the `submit-plan` action, the `ENV0_TF_PLAN_JSON` environment variable must be set (this is automatically provided by env0 after a terraform plan step).

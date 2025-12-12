# Overmind env0 Plugin

This plugin integrates [Overmind](https://www.overmind.tech/) with env0 to track infrastructure changes and deployments.

## Overview

The Overmind plugin installs the Overmind CLI (and GitHub CLI) and executes one of four actions:
- **submit-plan**: Submits a Terraform plan to Overmind for analysis
- **start-change**: Marks the beginning of a change in Overmind
- **end-change**: Marks the completion of a change in Overmind
- **wait-for-simulation**: Retrieves simulation output from Overmind and comments on the relevant GitHub PR or GitLab MR

## Inputs

| Input | Description | Required |
|-------|-------------|----------|
| `action` | The action to perform. Must be one of: `submit-plan`, `start-change`, `end-change`, `wait-for-simulation` | Yes |
| `api_key` | Overmind API key for authentication. Must have the following scopes: `account:read`, `changes:write`, `config:write`, `request:receive`, `sources:read`, `source:write` | Yes |
| `tags` | A comma-separated list of key=value tags to attach to the change (only used with `submit-plan` action) | No |
| `post_comment` | Whether `wait-for-simulation` should post the Overmind markdown to GitHub PR or GitLab MR. Defaults to `true` when running against a PR/MR, otherwise `false`. When `true`, `comment_provider` must be set. | No |
| `comment_provider` | Where `wait-for-simulation` should post comments when `post_comment=true`. Must be one of: `github`, `gitlab`. | No |

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
    terraformApply:
      after:
        - name: Post Overmind Simulation
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: wait-for-simulation
            api_key: ${OVERMIND_API_KEY}
            post_comment: false   # optional override
```

If you want to post a comment, set `comment_provider` explicitly:

```yaml
version: 2
deploy:
  steps:
    terraformApply:
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
    terraformApply:
      after:
        - name: Post Overmind Simulation (GitLab)
          use: https://github.com/your-org/env0-plugin
          inputs:
            action: wait-for-simulation
            api_key: ${OVERMIND_API_KEY}
            post_comment: true
            comment_provider: gitlab
```

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

## How It Works

1. **Installation**: The plugin automatically installs the latest version of the Overmind CLI and GitHub CLI (for GitHub support) to a writable directory in your PATH. GitLab support uses `curl` which is typically available on most systems.

2. **Authentication**: The API key provided in the `api_key` input is set as the `OVERMIND_API_KEY` environment variable.

3. **Action Execution**: Based on the `action` input, the plugin executes the corresponding Overmind/GitHub/GitLab workflow:
   - `submit-plan`: Uses `$ENV0_TF_PLAN_JSON` to submit the Terraform plan
   - `start-change`: Marks the beginning of a change with a ticket link to the env0 deployment
   - `end-change`: Marks the completion of a change with a ticket link to the env0 deployment
   - `wait-for-simulation`: Retrieves Overmind simulation results as Markdown and (when `post_comment=true`) posts them to the GitHub PR or GitLab MR (automatically detected based on repository URL)

4. **Ticket Links**: All actions automatically construct a ticket link to the env0 deployment using environment variables (`ENV0_PROJECT_ID`, `ENV0_ENVIRONMENT_ID`, `ENV0_DEPLOYMENT_LOG_ID`, `ENV0_ORGANIZATION_ID`).

## Requirements

- The plugin requires env0 environment variables to be available:
  - `ENV0_PROJECT_ID`
  - `ENV0_ENVIRONMENT_ID`
  - `ENV0_DEPLOYMENT_LOG_ID`
  - `ENV0_ORGANIZATION_ID`
  - `ENV0_TF_PLAN_JSON` (for submit-plan action)
  - `ENV0_PR_NUMBER` (only when `wait-for-simulation` posts comments, i.e., running against a PR/MR)
  - `ENV0_PR_SOURCE_REPOSITORY` (only when `wait-for-simulation` posts comments, used to detect GitHub vs GitLab)

- A valid Overmind API key with the following required scopes:
  - `account:read`
  - `changes:write`
  - `config:write`
  - `request:receive`
  - `sources:read`
  - `source:write`

- GitHub authentication for the CLI when `wait-for-simulation` posts to GitHub (set `GH_TOKEN`).
- GitLab authentication when `wait-for-simulation` posts to GitLab (set `GITLAB_TOKEN`).

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
3. Create a new token with the `api` scope (read/write is needed to comment on merge requests).
4. Generate the token and copy it immediately—GitLab will not show it again.
5. Store the token securely in env0 (for example as an environment variable or secret) and expose it to the plugin as `GITLAB_TOKEN`.

**Note**: When `post_comment=true`, you must set `comment_provider` to `github` or `gitlab`.
## Notes

- The plugin automatically detects the operating system and architecture to download the correct Overmind CLI binary.
- The installation directory is automatically selected from writable directories in your PATH.
- For the `submit-plan` action, the `ENV0_TF_PLAN_JSON` environment variable must be set (this is automatically provided by env0 after a terraform plan step).


# Overmind env0 Plugin

This plugin integrates [Overmind](https://www.overmind.tech/) with env0 to track infrastructure changes and deployments.

## Overview

The Overmind plugin installs the Overmind CLI (and GitHub CLI) and executes one of four actions:
- **submit-plan**: Submits a Terraform plan to Overmind for analysis
- **start-change**: Marks the beginning of a change in Overmind
- **end-change**: Marks the completion of a change in Overmind
- **wait-for-simulation**: Retrieves simulation output from Overmind and comments on the relevant GitHub PR

## Inputs

| Input | Description | Required |
|-------|-------------|----------|
| `action` | The action to perform. Must be one of: `submit-plan`, `start-change`, `end-change`, `wait-for-simulation` | Yes |
| `api_key` | Overmind API key for authentication. Must have the following scopes: `account:read`, `changes:write`, `config:write`, `request:receive`, `sources:read`, `source:write` | Yes |
| `tags` | A comma-separated list of key=value tags to attach to the change (only used with `submit-plan` action) | No |

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

Fetch the latest Overmind simulation summary for the current env0 deployment and comment on the matching GitHub pull request. Requires `ENV0_PR_NUMBER`, `ENV0_PR_SOURCE_REPOSITORY`, and valid GitHub CLI credentials (for example `GH_TOKEN`).

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

1. **Installation**: The plugin automatically installs the latest version of both the Overmind CLI and GitHub CLI to a writable directory in your PATH.

2. **Authentication**: The API key provided in the `api_key` input is set as the `OVERMIND_API_KEY` environment variable.

3. **Action Execution**: Based on the `action` input, the plugin executes the corresponding Overmind/GitHub workflow:
   - `submit-plan`: Uses `$ENV0_TF_PLAN_JSON` to submit the Terraform plan
   - `start-change`: Marks the beginning of a change with a ticket link to the env0 deployment
   - `end-change`: Marks the completion of a change with a ticket link to the env0 deployment
   - `wait-for-simulation`: Retrieves Overmind simulation results as Markdown and posts them to the GitHub PR

4. **Ticket Links**: All actions automatically construct a ticket link to the env0 deployment using environment variables (`ENV0_PROJECT_ID`, `ENV0_ENVIRONMENT_ID`, `ENV0_DEPLOYMENT_LOG_ID`, `ENV0_ORGANIZATION_ID`).

## Requirements

- The plugin requires env0 environment variables to be available:
  - `ENV0_PROJECT_ID`
  - `ENV0_ENVIRONMENT_ID`
  - `ENV0_DEPLOYMENT_LOG_ID`
  - `ENV0_ORGANIZATION_ID`
  - `ENV0_TF_PLAN_JSON` (for submit-plan action)
  - `ENV0_PR_NUMBER` and `ENV0_PR_SOURCE_REPOSITORY` (for wait-for-simulation action)

- A valid Overmind API key with the following required scopes:
  - `account:read`
  - `changes:write`
  - `config:write`
  - `request:receive`
  - `sources:read`
  - `source:write`

- GitHub authentication for the CLI when using `wait-for-simulation` (e.g., `GH_TOKEN` or `gh auth login`).

## Notes

- The plugin automatically detects the operating system and architecture to download the correct Overmind CLI binary.
- The installation directory is automatically selected from writable directories in your PATH.
- For the `submit-plan` action, the `ENV0_TF_PLAN_JSON` environment variable must be set (this is automatically provided by env0 after a terraform plan step).


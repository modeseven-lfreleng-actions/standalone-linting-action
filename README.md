<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# ⛔️ Standalone Linting Action

This action runs linting checks as a standalone step, which is helpful
for tools that do not run well (or cannot run) under the GitHub marketplace
pre-commit.ci application.

## standalone-linting-action

## Usage Example

An example workflow job using this action:

```yaml
jobs:
  linting:
    name: "Standalone linting checks"
    runs-on: "ubuntu-24.04"
    permissions:
      contents: read
    steps:
      # yamllint disable-line rule:line-length
      - uses: lfreleng-actions/standalone-linting-action@main
```

## Inputs

<!-- markdownlint-disable MD013 -->

| Variable Name    | Required | Description                                                    | Default                                                                                                                                                                     |
| ---------------- | -------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| config_url       | False    | Download location for pre-commit configuration                 | [pre-commit-config.yaml](https://raw.githubusercontent.com/lfreleng-actions/standalone-linting-action/refs/heads/main/pre-commit-config.yaml) |
| dependencies_url | False    | Download location for Python dependencies                      | None                                                                                                                                                                        |
| remote_config    | False    | Ignore local linting configuration; always install from remote | true                                                                                                                                                                        |
| python-version   | False    | Python version used to run linting tools                       | 3.12                                                                                                                                                                        |
| path_prefix   | False    | Directory location containing project code                        | .                                                                                                                                                                           |
| no_checkout   | False    | Don't perform a checkout of the local repository                  | false                                                                                                                                                                       |

<!-- markdownlint-enable MD013 -->

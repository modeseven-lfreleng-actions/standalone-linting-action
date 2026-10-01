#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the 'Validate inputs' step in action.yaml.
#
# The rejection cases in .github/workflows/testing.yaml can assert
# only that the action FAILED. A composite action exposes no inner
# step outcomes, so its caller cannot tell 'validation refused this'
# from 'something later fell over'. A case whose input also breaks a
# later step therefore keeps passing after the guard it targets is
# deleted (standalone-linting-action#171).
#
# This suite runs the validate step ON ITS OWN and asserts the refusal
# it prints, so deleting a guard fails here even where the action
# would still fail further on. It covers every rejection case that
# testing.yaml sends to this step.
#
# The step is EXTRACTED from action.yaml, never copied, so these
# fixtures exercise the code the action runs. Its environment is the
# step's own 'env' block with each input at its declared default, and
# a case layers VAR=VALUE pairs over that. A missing step, or an env
# entry that is not a plain input reference, fails the suite rather
# than letting it test nothing.
#
# Usage: tests/test-validate-inputs.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
action="${repo_root}/action.yaml"

if [ ! -f "${action}" ]; then
    echo "ERROR: action not found: ${action}" >&2
    exit 1
fi

# An interpreter that can import yaml, to read action.yaml.
#
# Prefer one that already has PyYAML. The prek hook environment
# supplies it, and pre-commit.ci's sandbox has no network to fetch it
# with, so asking uv first would fail there. uv is the fallback for a
# direct invocation.
#
# Finding neither is a FAILURE, never a skip: a skip would report
# success having checked nothing.
#
# '-I' because the extractor arrives on stdin, which puts the current
# directory on sys.path. '--no-config' because uv otherwise discovers
# a 'uv.toml' in the checkout, which could redirect the index PyYAML
# installs from.
if python3 -I -c 'import yaml' > /dev/null 2>&1; then
    PY_RUN=(python3 -I)
elif command -v uv > /dev/null 2>&1; then
    PY_RUN=(uv run --no-project --no-config --with pyyaml==6.0.2
        python -I)
else
    echo 'ERROR: no interpreter with PyYAML available' >&2
    echo '       Install uv (https://docs.astral.sh/uv/), or run' >&2
    echo '       this through the prek hook, which supplies PyYAML.' >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
step="${workdir}/validate.sh"
defaults="${workdir}/defaults"
runner_temp="${workdir}/runner-temp"
mkdir "${runner_temp}"

"${PY_RUN[@]}" - "${action}" "${step}" > "${defaults}" <<'PYEOF'
import re
import sys

import yaml

with open(sys.argv[1], encoding='utf-8') as handle:
    action = yaml.safe_load(handle)
inputs = action.get('inputs') or {}
steps = [
    step
    for step in (action.get('runs') or {}).get('steps') or []
    if isinstance(step, dict) and step.get('id') == 'validate'
]
if len(steps) != 1:
    sys.exit(f"expected one step with id 'validate', found {len(steps)}")
step = steps[0]
if step.get('shell') != 'bash' or not isinstance(step.get('run'), str):
    sys.exit("the 'validate' step is not a bash run step")
with open(sys.argv[2], 'w', encoding='utf-8') as handle:
    handle.write(step['run'])

# Each env entry must pass one input straight through. Anything else
# needs a value this suite cannot supply, so refuse it rather than
# run the step with the variable unset.
reference = re.compile(r'\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}')
for name, value in (step.get('env') or {}).items():
    match = reference.fullmatch(str(value))
    if match is None or match.group(1) not in inputs:
        sys.exit(f'env {name} is not an input reference: {value!r}')
    default = (inputs[match.group(1)] or {}).get('default', '')
    if isinstance(default, bool):
        default = 'true' if default else 'false'
    # NUL-terminated, so a default may hold any character.
    sys.stdout.write(f'{name}={default}\0')
PYEOF

base_env=()
known=' '
while IFS= read -r -d '' entry; do
    base_env+=("${entry}")
    known="${known}${entry%%=*} "
done < "${defaults}"

if [ ! -s "${step}" ] || [ "${#base_env[@]}" -eq 0 ]; then
    echo "ERROR: the 'validate' step in ${action}" >&2
    echo '       has no script, or reads no inputs.' >&2
    exit 1
fi

# The step resolves paths with 'realpath -e', which is GNU. macOS
# ships a BSD realpath without it; Homebrew's coreutils installs the
# GNU one as 'grealpath'.
if ! realpath -e / > /dev/null 2>&1; then
    if ! command -v grealpath > /dev/null 2>&1; then
        echo "ERROR: the validate step needs GNU 'realpath -e'" >&2
        echo '       On macOS: brew install coreutils' >&2
        exit 1
    fi
    mkdir "${workdir}/bin"
    ln -s "$(command -v grealpath)" "${workdir}/bin/realpath"
    PATH="${workdir}/bin:${PATH}"
fi

passed=0
failed=0
status=0

# Run the step as the runner does: from the workspace root, under
# 'bash --noprofile --norc -eo pipefail', in a clean environment.
# Every input starts at its default and the arguments, VAR=VALUE
# pairs, override them. Sets 'status'; the output lands in
# ${workdir}/out.
run_step() {
    local pair
    for pair in "$@"; do
        case "${known}" in
            *" ${pair%%=*} "*) ;;
            *)
                echo "ERROR: the step does not read ${pair%%=*}" >&2
                exit 1
                ;;
        esac
    done
    status=0
    (
        cd "${repo_root}"
        env -i PATH="${PATH}" \
            GITHUB_WORKSPACE="${repo_root}" \
            RUNNER_TEMP="${runner_temp}" \
            "${base_env[@]}" "$@" \
            bash --noprofile --norc -eo pipefail "${step}"
    ) > "${workdir}/out" 2>&1 || status=$?
}

pass() {
    passed=$((passed + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    failed=$((failed + 1))
    printf 'FAIL: %s\n      expected %s; exit status %s, output:\n' \
        "$1" "$2" "${status}"
    sed 's/^/        /' "${workdir}/out"
}

# $1 describes the case, the rest are VAR=VALUE pairs.
accept() {
    local desc="$1"
    shift
    run_step "$@"
    if [ "${status}" -eq 0 ] &&
        ! grep -q '^::error::' "${workdir}/out"; then
        pass "${desc}"
    else
        fail "${desc}" 'acceptance'
    fi
}

# $1 describes the case and $2 is the refusal its guard prints, minus
# the '::error::' prefix and the trailing mark. The rest are VAR=VALUE
# pairs. Matched as a whole line, so another check refusing the same
# input does not stand in for the guard under test.
reject() {
    local desc="$1" expected="$2" line found=0
    shift 2
    run_step "$@"
    while IFS= read -r line; do
        case "${line}" in
            "::error::${expected} ❌") found=1 ;;
        esac
    done < "${workdir}/out"
    if [ "${status}" -eq 1 ] && [ "${found}" -eq 1 ]; then
        pass "${desc}"
    else
        fail "${desc}" "refusal '${expected}'"
    fi
}

config_url='https://raw.githubusercontent.com/lfreleng-actions/'
config_url="${config_url}test-python-project/refs/heads/main/"
config_url="${config_url}resources/pre-commit-config.yaml"
zero_digest="$(printf '%064d' 0)"

# --- Accepted ----------------------------------------------------------

# A guard refusing EVERYTHING would satisfy every rejection below, so
# well-formed values for the same inputs must still pass.

accept 'the action defaults'

accept 'prek_version at the floor' INPUT_PREK_VERSION='0.2.20'

accept 'a pinned https config_url' \
    INPUT_CONFIG_URL="${config_url}" \
    INPUT_CONFIG_SHA256="${zero_digest}"

accept 'hook ids in hooks and skip_hooks' \
    INPUT_HOOKS='check-yaml, end-of-file-fixer' \
    INPUT_SKIP_HOOKS='aislop'

accept 'a workspace config_path with per_hook_runs' \
    INPUT_CONFIG_PATH='.pre-commit-config.yaml' \
    INPUT_HOOKS='check-yaml' \
    INPUT_PER_HOOK_RUNS='true'

# --- Refused -----------------------------------------------------------

# One per rejection case in testing.yaml that this step refuses, with
# the same input.

reject 'config_path traversal' \
    "config_path must not contain '..'" \
    INPUT_CONFIG_PATH='../.pre-commit-config.yaml'

reject 'plaintext http config_url' \
    'config_url must be an https:// URL' \
    INPUT_CONFIG_URL='http://example.org/config.yaml'

reject 'hook id that is a prek option' \
    'invalid hook id: --help' \
    INPUT_HOOKS='--help'

# Run from the repository root, so an unquoted expansion would turn
# '*' into file names that pass the id check.
reject 'glob as a hook id' \
    'invalid hook id: *' \
    INPUT_HOOKS='*'

reject 'option-shaped id in skip_hooks' \
    'invalid hook id in skip_hooks: --help' \
    INPUT_RUN_ALL_HOOKS='true' INPUT_SKIP_HOOKS='--help'

reject 'glob in skip_hooks' \
    'invalid hook id in skip_hooks: *' \
    INPUT_RUN_ALL_HOOKS='true' INPUT_SKIP_HOOKS='*'

reject 'non-boolean per_hook_runs' \
    "per_hook_runs must be 'true' or 'false'" \
    INPUT_PER_HOOK_RUNS='yes'

# The two #159 guards. Each input fails without its guard as well --
# uvx refuses the version, sha256sum the extra digest record -- so
# testing.yaml alone cannot show that the guard fired.
reject 'multi-line prek_version' \
    'prek_version must not contain control characters' \
    INPUT_RUN_ALL_HOOKS='true' INPUT_PREK_VERSION=$'0.4.14\njunk'

reject 'multi-line config_sha256' \
    'config_sha256 must not contain control characters' \
    INPUT_CONFIG_URL="${config_url}" \
    INPUT_CONFIG_SHA256="${zero_digest}"$'\n'"${zero_digest}"

reject 'prek_version below the floor' \
    'prek_version must be 0.2.20 or newer' \
    INPUT_PREK_VERSION='0.2.19'

# Fails later regardless -- no such prek release exists -- so only
# the step's own refusal shows the comparison caught it.
reject 'prek_version colliding under a packed radix' \
    'prek_version must be 0.2.20 or newer' \
    INPUT_PREK_VERSION='0.1.100020'

# --- Result ------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
    exit 1
fi

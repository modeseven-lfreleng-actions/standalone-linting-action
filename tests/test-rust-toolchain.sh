#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the 'Prepare Rust toolchain' step in action.yaml.
#
# The step decides whether a repository is a Rust project, asks rustup
# which toolchain it selects, installs a missing one and adds the
# components the cargo hooks need. testing.yaml runs it for real, but
# a runner cannot show WHICH rustup calls it made, nor reach its
# refusals cheaply. This suite runs the step on its own against a
# stand-in rustup that records every call, and asserts the calls, the
# 'toolchains' output and the refusals.
#
# The step is EXTRACTED from action.yaml by tests/lib/action-step.sh,
# never copied. Workspaces are real git repositories, since detection
# asks git which files are tracked.
#
# Usage: tests/test-rust-toolchain.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
action="${repo_root}/action.yaml"

# shellcheck source=tests/lib/action-step.sh
. "${script_dir}/lib/action-step.sh"

if [ ! -f "${action}" ]; then
    echo "ERROR: action not found: ${action}" >&2
    exit 1
fi

action_step_python

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
step="${workdir}/rust.sh"
defaults="${workdir}/defaults"

action_step_extract "${action}" rust "${step}" "${defaults}"

base_env=()
known=' '
while IFS= read -r -d '' entry; do
    base_env+=("${entry}")
    known="${known}${entry%%=*} "
done < "${defaults}"

if [ ! -s "${step}" ] || [ "${#base_env[@]}" -eq 0 ]; then
    echo "ERROR: the 'rust' step in ${action}" >&2
    echo '       has no script, or reads no inputs.' >&2
    exit 1
fi

bash_bin="$(command -v bash)"

# The step's PATH holds links to the tools it may call and nothing
# else, so 'rustup is absent' is true whatever the machine running
# this suite has installed. A tool the step starts to need without
# being listed here fails a case, loudly.
toolbin="${workdir}/toolbin"
mkdir "${toolbin}"
for tool in git sed tr; do
    ln -s "$(command -v "${tool}")" "${toolbin}/${tool}"
done

# The stand-in rustup. It records '<cwd>|<RUSTUP_AUTO_INSTALL>|<args>'
# per call, and its behaviour comes from FAKE_* variables:
#
#   FAKE_ACTIVE          what 'show active-toolchain' prints; a
#                        '.fake-toolchain' file in the working
#                        directory takes precedence
#   FAKE_MISSING         'show' fails until 'toolchain install' ran
#   FAKE_INSTALL_FAIL    'toolchain install' fails
#   FAKE_COMPONENT_FAIL  'component add' fails
#   FAKE_RUN_FAIL        'run' fails
fakebin="${workdir}/fakebin"
mkdir "${fakebin}"
cat > "${fakebin}/rustup" <<EOF
#!${bash_bin}
set -u
printf '%s|%s|%s\n' "\$PWD" "\${RUSTUP_AUTO_INSTALL-unset}" "\$*" \\
    >> "\$FAKE_RUSTUP_LOG"
case "\$1 \${2-}" in
    'show active-toolchain')
        if [ -n "\${FAKE_MISSING-}" ] &&
            [ ! -e "\$FAKE_RUSTUP_STATE/installed" ]; then
            echo 'error: toolchain is not installed' >&2
            exit 1
        fi
        if [ -f "\$PWD/.fake-toolchain" ]; then
            IFS= read -r line < "\$PWD/.fake-toolchain"
            printf '%s\n' "\$line"
        else
            printf '%s\n' "\$FAKE_ACTIVE"
        fi
        ;;
    'toolchain install')
        [ -z "\${FAKE_INSTALL_FAIL-}" ] || exit 1
        : > "\$FAKE_RUSTUP_STATE/installed"
        ;;
    'component add')
        [ -z "\${FAKE_COMPONENT_FAIL-}" ] || exit 1
        ;;
    run\ *)
        [ -z "\${FAKE_RUN_FAIL-}" ] || exit 1
        echo 'rustc 1.85.0 (4d91de4e4 2025-02-17)'
        ;;
    *)
        echo "stand-in rustup: unexpected call: \$*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "${fakebin}/rustup"

# Workspaces. git runs with an empty HOME and no system config, so
# the configuration of the machine running the suite cannot leak in.
export HOME="${workdir}/home" GIT_CONFIG_NOSYSTEM=1
mkdir "${HOME}"
new_repo() {
    mkdir -p "$1"
    git -C "$1" init -q
}

# Nothing Rust is tracked. The untracked Cargo.toml must not count.
ws_plain="${workdir}/ws-plain"
new_repo "${ws_plain}"
touch "${ws_plain}/README.md" "${ws_plain}/Cargo.toml"
git -C "${ws_plain}" add README.md

# A tracked Cargo.toml at the top level.
ws_root="${workdir}/ws-root"
new_repo "${ws_root}"
touch "${ws_root}/Cargo.toml"
git -C "${ws_root}" add Cargo.toml

# A tracked Cargo.toml in a nested directory only.
ws_nested="${workdir}/ws-nested"
new_repo "${ws_nested}"
mkdir -p "${ws_nested}/crates/app"
touch "${ws_nested}/crates/app/Cargo.toml"
git -C "${ws_nested}" add crates/app/Cargo.toml

# Rust in a subdirectory, linted with path_prefix 'rust'. Hooks run
# from the top level, so both places select a toolchain.
ws_mono="${workdir}/ws-mono"
new_repo "${ws_mono}"
mkdir "${ws_mono}/rust"
touch "${ws_mono}/rust/Cargo.toml"
git -C "${ws_mono}" add rust/Cargo.toml

# The same, with the subdirectory selecting a different toolchain.
ws_split="${workdir}/ws-split"
new_repo "${ws_split}"
mkdir "${ws_split}/rust"
touch "${ws_split}/rust/Cargo.toml"
git -C "${ws_split}" add rust/Cargo.toml
echo 'nightly-x86_64-unknown-linux-gnu (overridden by a file)' \
    > "${ws_split}/rust/.fake-toolchain"

# A Cargo.toml in a directory git does not manage.
ws_nogit="${workdir}/ws-nogit"
mkdir "${ws_nogit}"
touch "${ws_nogit}/Cargo.toml"

# Real paths, as the step resolves them with 'pwd -P' and git does.
for ws in ws_plain ws_root ws_nested ws_mono ws_split ws_nogit; do
    printf -v "${ws}" '%s' "$(cd "${!ws}" && pwd -P)"
done

stable='stable-x86_64-unknown-linux-gnu'
pinned='1.85.0-x86_64-unknown-linux-gnu'
nightly='nightly-x86_64-unknown-linux-gnu'

passed=0
failed=0
status=0
errors=()

# run_step <workspace> <with rustup: yes|no> [VAR=VALUE...]
#
# Runs the step as the runner does, from the workspace root, under
# 'bash --noprofile --norc -eo pipefail', in a clean environment.
# Every input starts at its default; INPUT_* pairs override inputs,
# FAKE_* pairs configure the stand-in, and RUSTUP_HOME passes through
# as rustup's own.
run_step() {
    local workspace="$1" with_rustup="$2" pair path="${toolbin}"
    shift 2
    for pair in "$@"; do
        case "${pair}" in
            FAKE_*=* | RUSTUP_HOME=*) ;;
            *)
                case "${known}" in
                    *" ${pair%%=*} "*) ;;
                    *)
                        echo "ERROR: the step does not read ${pair%%=*}" >&2
                        exit 1
                        ;;
                esac
                ;;
        esac
    done
    if [ "${with_rustup}" = 'yes' ]; then
        path="${fakebin}:${toolbin}"
    fi
    rm -rf "${workdir}/case"
    mkdir -p "${workdir}/case/state"
    : > "${workdir}/case/rustup.log"
    : > "${workdir}/case/output"
    : > "${workdir}/case/summary"
    status=0
    (
        cd "${workspace}"
        env -i PATH="${path}" HOME="${HOME}" GIT_CONFIG_NOSYSTEM=1 \
            GITHUB_WORKSPACE="${workspace}" \
            GITHUB_OUTPUT="${workdir}/case/output" \
            GITHUB_STEP_SUMMARY="${workdir}/case/summary" \
            FAKE_RUSTUP_LOG="${workdir}/case/rustup.log" \
            FAKE_RUSTUP_STATE="${workdir}/case/state" \
            "${base_env[@]}" "$@" \
            "${bash_bin}" --noprofile --norc -eo pipefail "${step}"
    ) > "${workdir}/case/out" 2>&1 || status=$?
}

check() {
    errors+=("$1")
}

expect_status() {
    [ "${status}" -eq "$1" ] ||
        check "exit status ${status}, expected $1"
}

# A whole line of the step's output, exactly.
expect_line() {
    grep -qxF -- "$1" "${workdir}/case/out" ||
        check "no output line: $1"
}

# The 'toolchains' output, or '<unset>' when the step wrote none.
expect_toolchains() {
    local got='<unset>'
    if grep -q '^toolchains=' "${workdir}/case/output"; then
        got="$(sed -n 's/^toolchains=//p' "${workdir}/case/output")"
    fi
    [ "${got}" = "$1" ] ||
        check "toolchains output '${got}', expected '$1'"
}

# The stand-in's call log, exactly, one '<cwd>|<auto>|<args>' per
# argument. No arguments means rustup was never called.
expect_calls() {
    local expected=''
    if [ "$#" -gt 0 ]; then
        expected="$(printf '%s\n' "$@")"
    fi
    [ "$(cat "${workdir}/case/rustup.log")" = "${expected}" ] ||
        check 'unexpected rustup calls'
}

expect_summary() {
    grep -qF -- "$1" "${workdir}/case/summary" ||
        check "summary lacks: $1"
}

expect_no_summary() {
    [ ! -s "${workdir}/case/summary" ] ||
        check 'wrote a job summary'
}

verdict() {
    if [ "${#errors[@]}" -eq 0 ]; then
        passed=$((passed + 1))
        printf 'PASS: %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL: %s\n' "$1"
        printf '      %s\n' "${errors[@]}"
        echo '      output:'
        sed 's/^/        /' "${workdir}/case/out"
        echo '      rustup calls:'
        sed 's/^/        /' "${workdir}/case/rustup.log"
    fi
    errors=()
}

# --- Not a Rust project, or turned off ----------------------------------

# The estate-wide case: existing callers must see no change at all.
run_step "${ws_plain}" yes FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_line 'No tracked Cargo.toml under path_prefix; not preparing Rust 💬'
expect_toolchains '<unset>'
expect_calls
expect_no_summary
verdict 'auto, nothing Rust tracked: rustup never called'

run_step "${ws_nogit}" yes FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_toolchains '<unset>'
expect_calls
verdict 'auto, not a git repository: rustup never called'

run_step "${ws_root}" yes INPUT_RUST_TOOLCHAIN_SETUP='false' \
    FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_toolchains '<unset>'
expect_calls
expect_no_summary
verdict 'false, Rust project: rustup never called'

# --- Prepared -------------------------------------------------------------

run_step "${ws_root}" yes FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_toolchains "${stable}"
expect_calls \
    "${ws_root}|0|show active-toolchain" \
    "${ws_root}|0|component add --toolchain ${stable} -- rustfmt clippy" \
    "${ws_root}|0|run ${stable} rustc --version"
expect_summary '✅ Prepared 1 toolchain(s)'
expect_summary "| \`${stable}\` | ✅ rustc 1.85.0 (4d91de4e4 2025-02-17) |"
verdict 'auto, installed toolchain: components added, nothing installed'

# The runner case: a pinned channel rustup has never installed.
run_step "${ws_nested}" yes FAKE_MISSING=1 \
    FAKE_ACTIVE="${pinned} (overridden by '${ws_nested}/rust-toolchain.toml')"
expect_status 0
expect_toolchains "${pinned}"
expect_calls \
    "${ws_nested}|0|show active-toolchain" \
    "${ws_nested}|0|toolchain install --no-self-update" \
    "${ws_nested}|0|show active-toolchain" \
    "${ws_nested}|0|component add --toolchain ${pinned} -- rustfmt clippy" \
    "${ws_nested}|0|run ${pinned} rustc --version"
verdict 'auto, nested Cargo.toml, missing toolchain: installed first'

run_step "${ws_plain}" yes INPUT_RUST_TOOLCHAIN_SETUP='true' \
    FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_toolchains "${stable}"
verdict 'true, nothing Rust tracked: prepared anyway'

run_step "${ws_nogit}" yes INPUT_RUST_TOOLCHAIN_SETUP='true' \
    FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_toolchains "${stable}"
expect_calls \
    "${ws_nogit}|0|show active-toolchain" \
    "${ws_nogit}|0|component add --toolchain ${stable} -- rustfmt clippy" \
    "${ws_nogit}|0|run ${stable} rustc --version"
verdict 'true, not a git repository: path_prefix alone'

run_step "${ws_root}" yes INPUT_RUST_COMPONENTS='rustfmt,clippy, rust-src' \
    FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_calls \
    "${ws_root}|0|show active-toolchain" \
    "${ws_root}|0|component add --toolchain ${stable} -- rustfmt clippy rust-src" \
    "${ws_root}|0|run ${stable} rustc --version"
verdict 'comma and space separated components'

run_step "${ws_root}" yes INPUT_RUST_COMPONENTS='' \
    FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_toolchains "${stable}"
expect_calls \
    "${ws_root}|0|show active-toolchain" \
    "${ws_root}|0|run ${stable} rustc --version"
verdict 'empty rust_components: no component add'

# Hooks run from the top level, so its toolchain is prepared as well
# as path_prefix's, and once when both select the same one.
run_step "${ws_mono}" yes INPUT_PATH_PREFIX='rust' \
    FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_toolchains "${stable}"
expect_calls \
    "${ws_mono}|0|show active-toolchain" \
    "${ws_mono}|0|component add --toolchain ${stable} -- rustfmt clippy" \
    "${ws_mono}|0|run ${stable} rustc --version" \
    "${ws_mono}/rust|0|show active-toolchain"
verdict 'path_prefix below the top level: both resolved, one prepared'

# 'component add' and 'run' name the toolchain explicitly, so they run
# from the workspace root whichever directory selected it.
run_step "${ws_split}" yes INPUT_PATH_PREFIX='rust' \
    FAKE_ACTIVE="${stable} (default)"
expect_status 0
expect_toolchains "${stable} ${nightly}"
expect_calls \
    "${ws_split}|0|show active-toolchain" \
    "${ws_split}|0|component add --toolchain ${stable} -- rustfmt clippy" \
    "${ws_split}|0|run ${stable} rustc --version" \
    "${ws_split}/rust|0|show active-toolchain" \
    "${ws_split}|0|component add --toolchain ${nightly} -- rustfmt clippy" \
    "${ws_split}|0|run ${nightly} rustc --version"
expect_summary '✅ Prepared 2 toolchain(s)'
verdict 'path_prefix selecting another toolchain: both prepared'

# The output is a single-line record; only the first line of rustup's
# answer may reach it. The second line carries a ' (...)' of its own,
# so stripping the reason alone would leave both lines in the name.
run_step "${ws_root}" yes \
    FAKE_ACTIVE="${stable} (default)"$'\ninjected=1 (x)'
expect_status 0
expect_toolchains "${stable}"
grep -q '^injected' "${workdir}/case/output" &&
    check 'a second line of rustup output reached GITHUB_OUTPUT'
verdict 'multi-line rustup answer: first line only'

# --- Not prepared, without failing -------------------------------------

run_step "${ws_root}" yes \
    FAKE_ACTIVE="/opt/tool chain/rust (overridden by '${ws_root}/rust-toolchain.toml')"
expect_status 0
expect_toolchains ''
expect_line "::warning::the toolchain selected in ${ws_root} is a path; not preparing it: /opt/tool chain/rust"
expect_calls "${ws_root}|0|show active-toolchain"
expect_summary '⚠️ Not prepared: the selected toolchain is a path'
verdict 'path-based toolchain: warned, never run'

# A linked toolchain is a symlink in rustup's home, RUSTUP_HOME or
# else ~/.rustup; rustup refuses 'component add' for one. An installed
# toolchain is a directory there, however it is named.
linked="${workdir}/linked-target"
mkdir -p "${linked}" "${workdir}/rustup-home/toolchains" \
    "${HOME}/.rustup/toolchains/installed-custom"
ln -s "${linked}" "${workdir}/rustup-home/toolchains/custom"
ln -s "${linked}" "${HOME}/.rustup/toolchains/home-custom"

run_step "${ws_root}" yes RUSTUP_HOME="${workdir}/rustup-home" \
    FAKE_ACTIVE="custom (overridden by '${ws_root}/rust-toolchain.toml')"
expect_status 0
expect_toolchains ''
expect_line "::warning::the toolchain selected in ${ws_root} is linked; not preparing it: custom"
expect_calls "${ws_root}|0|show active-toolchain"
expect_summary '⚠️ Not prepared: the selected toolchain is a path or linked'
verdict 'linked toolchain under RUSTUP_HOME: warned, never run'

run_step "${ws_root}" yes FAKE_ACTIVE='home-custom (default)'
expect_status 0
expect_toolchains ''
expect_line "::warning::the toolchain selected in ${ws_root} is linked; not preparing it: home-custom"
expect_calls "${ws_root}|0|show active-toolchain"
verdict 'linked toolchain under ~/.rustup: warned, never run'

run_step "${ws_root}" yes FAKE_ACTIVE='installed-custom (default)'
expect_status 0
expect_toolchains 'installed-custom'
expect_calls \
    "${ws_root}|0|show active-toolchain" \
    "${ws_root}|0|component add --toolchain installed-custom -- rustfmt clippy" \
    "${ws_root}|0|run installed-custom rustc --version"
verdict 'installed toolchain directory: prepared'

run_step "${ws_root}" no
expect_status 0
expect_toolchains '<unset>'
expect_line '::notice::rustup is not on PATH; the Rust toolchain was not prepared'
expect_summary '⚠️ Not prepared: rustup is not on PATH'
verdict 'auto, no rustup: notice, success'

# --- Refused -------------------------------------------------------------

run_step "${ws_root}" no INPUT_RUST_TOOLCHAIN_SETUP='true'
expect_status 1
expect_line "::error::rust_toolchain_setup is 'true' but rustup is not on PATH ❌"
expect_summary '❌ Failed at setup'
verdict 'true, no rustup: refused'

run_step "${ws_root}" yes FAKE_MISSING=1 FAKE_INSTALL_FAIL=1 \
    FAKE_ACTIVE="${pinned} (overridden by a file)"
expect_status 1
expect_toolchains '<unset>'
expect_line "::error::could not install the Rust toolchain selected in ${ws_root} ❌"
expect_summary '❌ Failed at install'
verdict 'failed install: refused'

run_step "${ws_root}" yes FAKE_COMPONENT_FAIL=1 \
    FAKE_ACTIVE="${stable} (default)"
expect_status 1
expect_toolchains '<unset>'
expect_line "::error::could not add rust_components to ${stable} ❌"
expect_summary '❌ Failed at components'
verdict 'failed component add: refused'

run_step "${ws_root}" yes FAKE_RUN_FAIL=1 FAKE_ACTIVE="${stable} (default)"
expect_status 1
expect_line "::error::rustc does not run from ${stable} ❌"
verdict 'rustc that does not run: refused'

# A name reaches rustup as an argument and the output as a record.
# Neither shell syntax nor an option may get through.
# shellcheck disable=SC2016 # the literal, unexpanded, is the point
for bad in '$(touch pwned)' '-help' 'a|b' ''; do
    run_step "${ws_root}" yes FAKE_ACTIVE="${bad} (default)"
    expect_status 1
    expect_line "::error::rustup named a toolchain for ${ws_root} that this action does not accept ❌"
    expect_calls "${ws_root}|0|show active-toolchain"
    expect_toolchains '<unset>'
    verdict "unacceptable toolchain name refused: '${bad}'"
done

# --- Result ------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
    exit 1
fi

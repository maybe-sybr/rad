#!/usr/bin/env bash
#
# If we weren't sourced, re-exec into the current `$SHELL` in such a way that
# we source this file before the users gets a prompt back
#
# zsh
if [ -n "${ZSH_VERSION:-}" ]; then
    [[ "${ZSH_EVAL_CONTEXT:-NOTPRESENT}" =~ ":file" ]] && _RAD_SOURCED=true
    _RAD_SCRIPT_PATH="$(realpath -e "${(%):-%N}")"
fi
# bash
if [ -n "${BASH_VERSION:-}" ]; then
    [[ "${BASH_SOURCE[0]:-${0}}" != "${0}" ]] && _RAD_SOURCED=true
    _RAD_SCRIPT_PATH="$(realpath -e "${BASH_SOURCE[0]}")"
fi
# shell specific re-exec
if ! ${_RAD_SOURCED:-false} && ! ${_RAD_REEXECED:-false} ; then
    declare -a _RAD_EXTRA_REEXEC_ARGS=()
    # common
    _RAD_TMPDIR="$(mktemp -d)"
    if [ $? != 0 ]; then
        echo "Failed to prepare for shell re-exec"
        exit 1
    fi
    # self-source and cleanup
    cat >"${_RAD_TMPDIR}/init.rc" <<EOF
        source "${_RAD_SCRIPT_PATH}"
        rm -rf "${_RAD_TMPDIR}"
EOF
    # zsh
    if ${SHELL} -c 'set -eu; true ${ZSH_VERSION}' 2>/dev/null; then
        _OLD_ZDOTDIR="${ZDOTDIR:-${HOME}}"
        export ZDOTDIR="${_RAD_TMPDIR}"
        cat >"${ZDOTDIR}/.zshrc" <<EOF
            source "${_OLD_ZDOTDIR}/.zshrc"
            export ZDOTDIR="${_OLD_ZDOTDIR}"
            source "${_RAD_TMPDIR}/init.rc"
EOF
    fi
    # bash
    if ${SHELL} -c 'set -eu; true ${BASH_VERSION}' 2>/dev/null; then
        cat >"${_RAD_TMPDIR}/bash-init.rc" <<EOF
            source "${HOME}/.bashrc"
            source "${_RAD_TMPDIR}/init.rc"
EOF
        _RAD_EXTRA_REEXEC_ARGS+=("--rcfile" "${_RAD_TMPDIR}/bash-init.rc")
    fi
    # finally we can re-exec
    _RAD_REEXECED=true exec "${SHELL}" "${_RAD_EXTRA_REEXEC_ARGS[@]}"
fi

# util functions
function query_yn () {
    read -p "$@ -- [y/n]: " -n 2 -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0;
    else
        return 1
    fi
}

# wrap some command in a `repo forall`
BOLD="\033[1m"
RESET="\033[0m"
function _repo_wrap () {
    local -a _RAD_FORALL_INIT=(
        "source \"${_RAD_SCRIPT_PATH}\"" " ; "
    )
    # if we're on a TTY, bold the project header line
    if [ -t 1 ]; then
        _RAD_FORALL_INIT+=(
            "echo -e \"${BOLD}project \${REPO_PATH}/${RESET}\"" " ; "
        )
    else
        _RAD_FORALL_INIT+=(
            "echo -e \"--> project \${REPO_PATH}/\"" " ; "
        )
    fi
    repo forall -ec "${_RAD_FORALL_INIT} ${*}"
}

# find the closest .repo directory
function _rad_find_repo () {
    if [ $# -gt 1 ]; then
        echo "[E] Bad call to _rad_find_repo: $@"
        return 127
    fi
    local CAND_BASE="$(realpath -e "${1:-${PWD}}")"
    while [ ! -z "${CAND_BASE}" ]; do
        local CAND="${CAND_BASE}/.repo"
        if [ -d "${CAND}" ]; then
            echo "${CAND}"
            return 0
        fi
        CAND_BASE="${CAND_BASE%/*}"
    done
    return 1
}

# stage changes interactively
function _repo_add_interactive_each () {
    git add "${@}" || return $?
    for uf in $(git ls-files --others --exclude-standard); do
        if query_yn "Stage untracked file? '${uf}'"; then
            git add "${uf}"
        fi
    done
}
alias ra="_repo_wrap _repo_add_interactive_each"

# reset all staged changes
alias rr="_repo_wrap git reset"

# shorten `repo status` and `repo diff`
alias rst="repo status"
alias rd="repo diff"

# view cached (staged) changes in all repos
alias rds="PAGER= _repo_wrap git diff --color=always --cached | ${PAGER:-cat}"
alias rdc="rds"

# commit changes in each repository using the same message - unfortunately the
# most obvious way to do this means we need to write the commit message prior
# making the actual commits which means using `-p` feels a bit bass-ackwards
IF_ANY_CHANGES="git status -z | grep -qEZ '^\s?[MADRCU]'"
IF_STAGED_CHANGES="git status -z | grep -qEZ '^[MADRCU]'"

function _rad_find_commit_msg_path () {
    local -r REPO_DIR="$(_rad_find_repo)"
    if [ ! -z "${REPO_DIR}" ]; then
        echo "${REPO_DIR}/COMMIT_EDITMSG"
    fi
}
function _rad_edit_commit_msg () {
    if [ $# -ne 1 ]; then
        echo "[E] Bad call to _rad_edit_commit_msg: $@"
        return 127
    fi
    local -r COMMIT_MSG_PATH="${1}"
    # we initially populate the message with a unique change ID which can be
    # used to correlate the commits in each repo later
    local -r CHANGE_ID="I$(date +%s.%N | shasum)"
    cat >"${COMMIT_MSG_PATH}" <<EOF


Change-Id: ${CHANGE_ID}

EOF
    # and also the output of `git status` in each repo, commented of course
    _repo_wrap "${IF_STAGED_CHANGES} && git status || echo -e 'No changes to commit\n'" |  \
    while IFS= read line; do
        if [ ! -z "${line}" ]; then
            echo "# ${line}"
        else
            echo "#"
        fi
    done >>"${COMMIT_MSG_PATH}"
    # jump to the 0th line to be helpful
    ${EDITOR:-vim} -c "0" "${COMMIT_MSG_PATH}"
    # strip out all the comment lines to finalise the message file to be used
    sed -i '/^#/d' "${COMMIT_MSG_PATH}"
}
function _rad_commit_all () {
    # XXX: gross, but enough to let us use `-p` if we don't get exotic with the
    # specified options
    EXTRA_ARGS="${@}"
    if [[ "${EXTRA_ARGS}" =~ "-p" ]]; then
        _repo_wrap _repo_add_interactive_each -p
        EXTRA_ARGS="${EXTRA_ARGS/-p/}"
    fi
    # prep the commit message and then do it
    local -r COMMIT_MSG_PATH="$(_rad_find_commit_msg_path)"
    _rad_edit_commit_msg "${COMMIT_MSG_PATH}" || return $?
    # We only bother trying to commit a project if there are staged changes or
    # if `-a` is provided and there are any changes
    if [[ "${EXTRA_ARGS}" =~ "-a" ]]; then
        CONDITION="${IF_ANY_CHANGES}"
    else
        CONDITION="${IF_STAGED_CHANGES}"
    fi
    _repo_wrap "${CONDITION} && git commit -F \"${COMMIT_MSG_PATH}\" ${EXTRA_ARGS} || echo 'No changes committed'"
}
alias rc="_rad_commit_all"

# check whatchanged for all projects between the upstream and HEAD
function _rad_whatchanged_all () {
    PAGER= _repo_wrap   \
        git whatchanged "@{upstream}.." --patch --color=always "${@}" | \
        ${PAGER:-cat}
}
alias rwc="_rad_whatchanged_all"

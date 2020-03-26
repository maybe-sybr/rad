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

function true_uniq () {
    # this is array magic where lines are only printed if they've not been seen
    # before - it behaves as a true `uniq` which doesn't need to sort its input
    awk '!x[$0]++'
}

# wrap some command in a `repo forall`
BOLD="\033[1m"
RESET="\033[0m"
function _repo_wrap_inner () {
    repo forall -ec "${*}"
}
function _repo_wrap () {
    local -a _RAD_FORALL_INIT=(
        # sometimes this spits out a spurious syntax error...
        "source \"${_RAD_SCRIPT_PATH}\" 2>/dev/null" " ; "
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
    _repo_wrap_inner "${_RAD_FORALL_INIT} ${*}"
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

# find the closest .git directory to a potentially non-existant path
function _rad_find_git () {
    if [ $# -gt 1 ]; then
        echo "[E] Bad call to _rad_find_git: $@"
        return 127
    fi
    local CAND_BASE="$(realpath -m "${1:-${PWD}}")"
    while [ ! -z "${CAND_BASE}" ]; do
        local CAND="${CAND_BASE}/.git"
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
    local -r CHANGE_ID="I$(date +%s.%N | shasum | cut -d ' ' -f1)"
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

# export a unified quilt patch series for commits since branching from upstream
_RAD_QUILT_PATCHDIR=".rad/patches"
# helper functions for extracting and combining patchfiles
function extract_msg () {
    # this drops the leading 'From <hash>` line which is fine because its
    # meaningless after we combine the patches anyway
    sed -n '/From:/,/---/p' "${1}"
}
function extract_diff () {
    # lines between the first `diff ...` and the trailing triple dash line
    sed -n '/^diff/,/^--[^-]/p' "${1}"
}
function combine_diffs () {
    # recursive func which runs `combinediff` from `patchutils` over N files
    if [ $# -eq 0 ]; then
        echo "[E] Bad call to combine_diffs: $@" >&2
        return 127
    elif [ $# -eq 1 ]; then
        extract_diff "${1}"
    elif [ $# -eq  2 ]; then
        combinediff -q <(extract_diff "${1}") <(extract_diff "${2}")
    else
        combinediff -q <(extract_diff "${1}") <(combine_diffs "${@:2}")
    fi
}
# the actual logic for doing a quilt export
function _rad_combine_patches () {
    if [ $# -ne 2 ]; then
        echo "[E] Bad call to _rad_combine_patches: $@"
        return 127
    fi
    local -r sf="${1}"      # the series file to add the patch to
    local -r cid="${2}"     # the change ID
    echo "[I] Combining diffs for Change-Id: I${cid}"
    # the combined patch will be named for change ID and we'll add it to the
    # quilt patch series file now
    local -r cpf_name="${cid}.patch"
    local -r cpf_path="${sf%/*}/${cpf_name}"
    # delete any existing combined patch so we don't get confused
    rm -f -- "${cpf_path}"
    local -a cid_patchfiles=($(
        grep -lr "${cid}" "${sf%/*}"
    ))
    # Get the message from the first patch we found
    extract_msg "${cid_patchfiles[1]}" > "${cpf_path}"
    combine_diffs "${cid_patchfiles[@]}" >> "${cpf_path}"
    # Finally, add the new patch file to the series
    echo "${cpf_name}" >> "${sf}"
}
function _rad_quilt_export () {
    # get all patches since branching from upstream in all projects
    local -ar split_patches=($(
        _repo_wrap_inner git format-patch @{u}..                              \
            --output-directory="${PWD}/${_RAD_QUILT_PATCHDIR}/\${REPO_PATH}"  \
            --src-prefix="a/\${REPO_PATH}/" --dst-prefix="b/\${REPO_PATH}/"
    ))
    if [ -z "${split_patches}" ]; then
        echo "[I] No patches to export :)"
        return 0
    fi
    # get the unique change IDs using `true_uniq` from the patchfile names
    # which are currently in order per-project, resulting in a well enough
    # ordered set of change IDs to be used to build a quilt patch series
    #
    # note that any changes without a Change-Id tag (ie. not committed using
    # `_rad_commit_all` or with the tag removed from the message, will not be
    # included!
    local -ar uniq_change_ids=($(
        grep -Pho '(?<=Change-Id: I)[0-9a-f]+' "${split_patches[@]}" |  \
            true_uniq
    ))
    # for each change ID, combine the per-project patches into a single
    # combined patch with the email content from the first one (they should all
    # be the same since they were committed with `_rad_commit_all`)
    local -r sf="${PWD}/${_RAD_QUILT_PATCHDIR}/series"
    [ -f "${sf}" ] && truncate -s 0 "${sf}" || touch "${sf}"
    for cid in "${uniq_change_ids[@]}"; do
        _rad_combine_patches "${sf}" "${cid}"
    done
}
alias rqe="_rad_quilt_export"

# import a unified quilt patch series and commit the changes into each project
# repository as if we had `git am`ed per-project mbox patches
function _rad_quilt_import () {
    # loop through each patch in the quilt series splitting them up and
    # recommitting using the message header from the original patch file
    local -r sf="${PWD}/${_RAD_QUILT_PATCHDIR}/series"
    if [ ! -f "${sf}" ]; then
        echo "[E] No quilt series file found :("
        return 127
    fi
    local -r spf_dir="${sf%/*}/split"
    local -r rpf_dir="${sf%/*}/recombined"
    local -r patch_file="$(_rad_find_repo)/MBOX_PATCH"
    while read cpf_name; do
        local cpf_path="${sf%/*}/${cpf_name}"
        echo "[I] Applying ${cpf_path##*/}"
        # remove any old recombined patch files
        [ -d "${rpf_dir}" ] && find "${rpf_dir}" -name "${cpf_name}" -delete
        # split the combined patch file into per-target file patches
        local -a split_patches=($(
            splitdiff -a -p 1 -D "${spf_dir}" "${cpf_path}" |   \
                grep -Po '(?<=>).*$'
        ))
        if [ -z "${split_patches}" ]; then
            echo "[I] No patches to import :)"
            return 0
        fi
        # for each of the split patches, work out to which project it applies
        # and add the diff to the project specific recombined patch file
        for spf_path in "${split_patches[@]}"; do
            local tf_path="$(
                # this pattern conveniently filters out `/dev/null` targets
                grep -Po '(?<=[-+]{3} [ab]/).*$' "${spf_path}" | true_uniq
            )"
            if [[ "${tf_path}" =~ $'\n' ]]; then
                echo "[E] Somehow we didn't manage to split up ${cpf_path##*/}"
                echo "[E] ${spf_path##*/} has multiple file targets"
                return 127
            fi
            # find the relative path to the project this patch targets
            local trg_path="$(_rad_find_git "${tf_path}")"
            local prj_path="$(realpath --relative-to="${PWD}" "${trg_path%/.git}")"
            # now strip that path from the split patch file
            mkdir -p "${rpf_dir}/${prj_path}"
            sed "s#${prj_path}/##" "${spf_path}"    \
                >> "${rpf_dir}/${prj_path}/${cpf_name}"
        done
        # finally, for each recombined patch file, work out what project it
        # applies to and `git am` it in that directory
        for rcpf_path in $(find "${rpf_dir}" -name "${cpf_name}"); do
            local prj_path="$(
                realpath --relative-to="${rpf_dir}" "${rcpf_path%/*.patch}"
            )"
            echo "${BOLD}${prj_path}${RESET}"
            cat <(extract_msg "${cpf_path}") "${rcpf_path}" > "${patch_file}"
            git -C "${prj_path}" am "${patch_file}" ||  \
                git -C "${prj_path}" am --abort
        done
    done <"${sf}"
}
alias rqi="_rad_quilt_import"

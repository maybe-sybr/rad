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
    read -p "$* -- [y/n]: " -n 2 -r
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

# finc a suitable path for a file to be edited and used later
function _rad_find_editable_file_path () {
    if [ $# -ne 1 ]; then
        echo "[E] Bad call to _rad_find_editable_file_path: ${*}" >&2
        return 127
    fi
    local -r FILE_NAME="${1}"
    local -r REPO_DIR="$(_rad_find_repo)"
    if [ ! -z "${REPO_DIR}" ]; then
        echo "${REPO_DIR}/${FILE_NAME}"
    else
        echo "${PWD}/.${FILE_NAME}"
    fi
}

# find a directory which is a sibling of the input path or a (grand*)-parent
function _rad_find_auntie_dir_path () {
    if [ $# -gt 2 ] || [ $# -eq 0 ]; then
        echo "[E] Bad call to _rad_find_auntie_dir_path: ${*}"
        return 127
    fi
    local DIR_NAME="${1}"
    # we don't require that the initial path exist since we might be hunting
    # for an auntie for a non-existant file which we want to write to later
    local CAND_BASE="$(realpath -m "${2:-${PWD}}")"
    while [ -n "${CAND_BASE}" ]; do
        local CAND="${CAND_BASE}/${DIR_NAME}"
        if [ -d "${CAND}" ]; then
            echo "${CAND}"
            return 0
        fi
        CAND_BASE="${CAND_BASE%/*}"
    done
    return 1
}

# wrap some command in a `repo forall`
BOLD="\033[1m"
RESET="\033[0m"
function _repo_wrap_inner () {
    repo forall -c "${*}"
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
    _repo_wrap_inner "${_RAD_FORALL_INIT[*]} ${*}"
}

# find the closest .repo directory
function _rad_find_repo () {
    _rad_find_auntie_dir_path ".repo" "${@}"
}
# find the closest .git directory to a potentially non-existant path
function _rad_find_git () {
    _rad_find_auntie_dir_path ".git" "${@}"
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
# make all project trees pristine
alias rpristine="_repo_wrap 'git reset --hard HEAD; git clean -dffx'"

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
    _rad_find_editable_file_path "COMMIT_MSG"

}
function _rad_edit_commit_msg () {
    if [ $# -ne 1 ]; then
        echo "[E] Bad call to _rad_edit_commit_msg: ${*}"
        return 127
    fi
    local -r COMMIT_MSG_PATH="${1}"
    # we initially populate the message with a unique change ID which can be
    # used to correlate the commits in each repo later
    local -r CHANGE_ID="I$(date +%s.%N | shasum | cut -d ' ' -f1)"
    cat >"${COMMIT_MSG_PATH}" <<EOF


Change-Id: ${CHANGE_ID}
# Depends: I...

EOF
    # and also the output of `git status` in each repo, commented of course
    _repo_wrap "${IF_STAGED_CHANGES} && git status || echo -e 'No changes to commit\n'" |  \
    while IFS= read -r line; do
        if [ -n "${line}" ]; then
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
    EXTRA_ARGS="${*}"
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
        echo "[E] Bad call to combine_diffs: ${*}" >&2
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
        echo "[E] Bad call to _rad_combine_patches: ${*}"
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
        grep -lr "Change-Id: I${cid}" "${sf%/*}"
    ))
    # Get the message from the first patch we found
    extract_msg "${cid_patchfiles[1]}" > "${cpf_path}"
    combine_diffs "${cid_patchfiles[@]}" >> "${cpf_path}"
    # Finally, add the new patch file to the series
    echo "${cpf_name}" >> "${sf}"
}
function _rad_quilt_export () {
    if [ $# -gt 1 ]; then
        echo "[E] _rad_quilt_export [series name]"
        return 127
    fi
    local -r series_name="${1:-series}${1:+.series}"
    # get all patches since branching from upstream in all projects
    local -ar split_patches=($(
        _repo_wrap_inner git format-patch '@{u}..'                            \
            --output-directory="${PWD}/${_RAD_QUILT_PATCHDIR}/\${REPO_PATH}"  \
            --src-prefix="a/\${REPO_PATH}/" --dst-prefix="b/\${REPO_PATH}/"
    ))
    if [ -z "${split_patches[*]}" ]; then
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
        for split_patch in "${split_patches[@]}"; do
            # make sure we list dependent changes first
            grep -Pho '(?<=Depends: I)[0-9a-f]+' "${split_patch}"
            # then the actual change in this patch
            grep -Pho '(?<=Change-Id: I)[0-9a-f]+' "${split_patch}"
        done | true_uniq |  \
        grep -xf <(grep -Pho '(?<=Change-Id: I)[0-9a-f]+' "${split_patches[@]}") -
        # select only lines we actually have changes for ^
    ))
    # for each change ID, combine the per-project patches into a single
    # combined patch with the email content from the first one (they should all
    # be the same since they were committed with `_rad_commit_all`)
    local -r sf="${PWD}/${_RAD_QUILT_PATCHDIR}/${series_name}"
    [ -f "${sf}" ] && truncate -s 0 "${sf}" || touch "${sf}"
    for cid in "${uniq_change_ids[@]}"; do
        _rad_combine_patches "${sf}" "${cid}"
    done
}
alias rqe="_rad_quilt_export"

# split a combined patch file into per-project ones for projects which exist in
# the current work tree
function _rad_perproj_recombine_patch () {
    if [ $# -ne 2 ]; then
        echo "[E] Bad call to _rad_perproj_recombine_patch: ${*}"
        return 127
    fi
    local -r cpf_path="${1}"    # combined patch file to split and recombine
    local -r ctx_path="${2}"    # directory to work in (context)
    local -r spf_dir="${ctx_path}/split"
    local -r rpf_dir="${ctx_path}/recombined"
    # remove any old recombined patch files
    [ -d "${rpf_dir}" ] && find "${rpf_dir}" -name "${cpf_name}" -delete
    # split the combined patch file into per-target file patches
    local -a split_patches=($(
        splitdiff -a -p 1 -D "${spf_dir}" "${cpf_path}" | grep -Po '(?<=>).*$'
    ))
    if [ -z "${split_patches[*]}" ]; then
        echo "[I] No patches to import :)"
        return 0
    fi
    # for each of the split patches, work out to which project it applies and
    # add the diff to the project specific recombined patch file
    local -a all_rpf_paths=()
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
        if [ -z "${trg_path}" ]; then
            echo "[W] Skipping diff target '${tf_path}' not in a git repo" >&2
            continue
        fi
        local prj_path="$(realpath --relative-to="${PWD}" "${trg_path%/.git}")"
        # now strip that path from the split patch file
        local rpf_path="${rpf_dir}/${prj_path}/${cpf_name}"
        mkdir -p "${rpf_path%/*}"
        sed "s#${prj_path}/##" "${spf_path}" >> "${rpf_path}"
        all_rpf_paths+=("${rpf_path}")
    done
    # spit out the unique recombined patch file paths
    for rpf_path in "${all_rpf_paths[@]}"; do
        echo "${rpf_path}"
    done | true_uniq
}
# outer loop for splitting and recombining a unified quilt patch series, and
# then running another inner function for whatever we want to do with each of
# those recombined patch files
function _rad_find_mbox_patch_path () {
    _rad_find_editable_file_path "MBOX_PATH"
}
function _rad_quilt_recombine_outer () {
    if [ $# -eq 0 ] || [ $# -gt 2 ]; then
        echo "[E] Bad call to _rad_quilt_recombine_outer: ${*}"
        return 127
    fi
    local -r inner_func="${1}"
    local -r series_name="${2:-series}${2:+.series}"
    # loop through each patch in the quilt series splitting them up and
    # recommitting using the message header from the original patch file
    local -r sf="${PWD}/${_RAD_QUILT_PATCHDIR}/${series_name}"
    if [ ! -f "${sf}" ]; then
        echo "[E] No quilt series file found :("
        return 127
    fi
    local -r ctx_path="${sf%/*}"
    local -r patch_file="$(_rad_find_mbox_patch_path)"
    while read -r cpf_name; do
        local cpf_path="${ctx_path}/${cpf_name}"
        echo "[I] Applying ${cpf_path##*/}"
        # split and recombine this combined patch file for each project repo it
        # touches, then apply those patches using `git am`
        for rcpf_path in $(
            _rad_perproj_recombine_patch "${cpf_path}" "${ctx_path}"
        ); do
            # strip the context path plus one more component, and the filename
            # to determine what project this patch applies to - this is logic
            # coupling between this function and `_rad_perproj_recombine_patch`
            local prj_path="${rcpf_path%/*.patch}"
            prj_path="${prj_path#${ctx_path}/*/}"
            echo -e "${BOLD}project ${prj_path}/${RESET}"
            # we'd like to use substitutions in the `git am` command but for
            # some reason it complains when they're used, so we drop the patch
            # file we're going to apply to a well known path
            cat <(extract_msg "${cpf_path}") "${rcpf_path}" > "${patch_file}"
            # run the args passed to this function
            (cd "${prj_path}"; "${inner_func}" "${patch_file}")
        done
    done <"${sf}"
}
# import a unified quilt patch series and commit the changes into each project
# repository as if we had `git am`ed per-project mbox patches
function _rad_quilt_import_inner () {
    if [ $# -ne 1 ]; then
        echo "[E] Bad call to _rad_quilt_import_inner: ${*}"
        return 127
    fi
    # we expect to be in the repository of interest thanks to the outer loop
    local -r mbox_patch_path="${1}"
    git am "${mbox_patch_path}" || git am --abort
}
alias rqi="_rad_quilt_recombine_outer _rad_quilt_import_inner"
# apply a unified quilt patch series without committing it and without `quilt`!
function _rad_quilt_apply_inner () {
    if [ $# -ne 1 ]; then
        echo "[E] Bad call to __rad_quilt_apply_inner: ${*}"
        return 127
    fi
    # we expect to be in the repository of interest thanks to the outer loop
    local -r mbox_patch_path="${1}"
    git apply --stat --apply "${mbox_patch_path}"
}
alias rqa="_rad_quilt_recombine_outer _rad_quilt_apply_inner"

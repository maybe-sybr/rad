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
    printf "${*} -- [y/n]: "; read -r REPLY
    if [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
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
    # We can't use `forall` to run interactive commands since v2.13 (fbab606
    # specifically) and it's easier to just loop over the paths anyway since it
    # avoids allowing `repo` to choose some level of parallelism > 1.
    IFS=$'\n' declare -ar REPO_PATHS=( $(repo list --path-only --fullpath) )
    for repo_path in "${REPO_PATHS[@]}"; do
        (
            # `repo` provides lots of these so we may need to add more later
            export REPO_PATH="${repo_path}"
            cd "${repo_path}" && "${SHELL:-bash}" -c "${*}"
        )
    done
}
function _repo_wrap_quiet () {
    local -a _RAD_FORALL=(
        # sometimes this spits out a spurious syntax error...
        "source \"${_RAD_SCRIPT_PATH}\" 2>/dev/null" " ; " "${@}"
    )
    _repo_wrap_inner "${_RAD_FORALL[*]}"
}
function _repo_wrap () {
    local -a _RAD_FORALL_INIT=()
    # if we're on a TTY, bold the project header line
    if [ -t 1 ]; then
        _RAD_FORALL_INIT+=(
            "echo -e \"\n${BOLD}project \${REPO_PATH}/${RESET}\"" " ; "
        )
    else
        _RAD_FORALL_INIT+=(
            "echo -e \"\n--> project \${REPO_PATH}/\"" " ; "
        )
    fi
    _repo_wrap_quiet "${_RAD_FORALL_INIT[@]}" "${@}"
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

# push all project trees to their upstream branches
function _rad_push_each () {
    if [ $# -eq 0 ] && ! git rev-parse HEAD@{upstream} &>/dev/null; then
        echo "Nothing to do"
        return 0
    fi
    git push "${@}"
}
alias rp="_repo_wrap _rad_push_each"

# list and manipulate branches
alias rb="repo branch"
alias rbs="repo start"
alias rba="repo abandon"
alias rco="repo checkout"

# commit changes in each repository using the same message - unfortunately the
# most obvious way to do this means we need to write the commit message prior
# making the actual commits which means using `-p` feels a bit bass-ackwards
IF_ANY_CHANGES="git status -z | grep -qEZ '^\s?[MADRCU]'"
IF_STAGED_CHANGES="git status -z | grep -qEZ '^[MADRCU]'"

function _rad_find_git_msg_path () {
    _rad_find_editable_file_path "${1:-GIT_MESSAGE}"

}
function _rad_change_id () {
    echo "I$(date +%s.%N | sha1sum | cut -d ' ' -f1)"
}
function _rad_edit_commit_msg () {
    if [ $# -lt 1 ]; then
        echo "[E] Bad call to _rad_edit_commit_msg: ${*}"
        return 127
    fi
    local -r COMMIT_MSG_PATH="${1}" ; shift
    truncate -s 0 "${COMMIT_MSG_PATH}"
    # `cat` each FD number passed down to this function into the commit message
    eval cat "${@/#/<&}" >>"${COMMIT_MSG_PATH}"
    # and then close all of the FDs
    exec {top}<&-; for i in "${@}"; do eval "exec {i}<&-"; done
    # jump to the 0th line to be helpful
    ${EDITOR:-vim} -c "0" -c "set filetype=gitcommit" "${COMMIT_MSG_PATH}"
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
    local -r COMMIT_MSG_PATH="$(_rad_find_git_msg_path "COMMIT_MSG")"
    # we leave blank lines for the commit message to be written
    exec {top}<> <(echo -en '\n\n')
    # we initially populate the message with a unique change ID which can be
    # used to correlate the commits in each repo later
    exec {change_id}<> <(cat <<EOF
Change-Id: $(_rad_change_id)
# Depends: I...

EOF
)
    # and also the output of `git status` in each repo, commented of course
    exec {staged_changes}<> <(
        _repo_wrap "${IF_STAGED_CHANGES} && git status || echo -e 'No changes to commit\n'" | \
        while IFS= read -r line; do
            echo "# ${line}"
        done | sed 's/\s\+$//'
    )
    # pass the chunks down to populate the file which will then be edited
    local -ar chunks=( "${top}" "${change_id}" "${staged_changes}" )
    _rad_edit_commit_msg "${COMMIT_MSG_PATH}" "${chunks[@]}" || return $?
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

# perform a merge for the name branch into its upstream in all projects in
# which that branch exists
function _rad_upstream_name () {
    local -ar ARGS=( "${@}" )
    git rev-parse --symbolic-full-name "${ARGS[@]/%/@{upstream\}}"
}
function _rad_local_name () {
    sed -E 's#refs/remotes/[^/]+/#refs/heads/#' <<<"${@}"
}
function _rad_merge_offbranch_each () {
    if [ $# -ne 3 ]; then
        echo "[E] Bad call to _rad_merge_offbranch_each: ${*}"
        return 127
    fi
    local -r MERGE_ID="${1}"
    local -r MERGE_MSG_PATH="${2}"
    local -r MERGE_FROM="${3}"
    # first we need to check if the branch in question exists
    git rev-parse "${MERGE_FROM}" &>/dev/null || return 0
    # if so, checkout a merge branch from either the upstream or a local copy
    # of the upstream branch if one already exists
    local UPSTREAM="$(_rad_upstream_name "${MERGE_FROM}")"
    local -r LOCAL_NAME="$(_rad_local_name "${UPSTREAM}")"
    if git rev-parse --verify --quiet "${LOCAL_NAME}" >/dev/null; then
        UPSTREAM="${LOCAL_NAME}"
    fi
    git checkout -b "refs/merge/${MERGE_ID}" --track "${UPSTREAM}"
    git merge --no-ff -F "${MERGE_MSG_PATH}" "${MERGE_FROM}"
}
function _rad_merge_upstream_each () {
    if [ $# -ne 1 ]; then
        echo "[E] Bad call to _rad_merge_upstream_each: ${*}"
        return 127
    fi
    local -r MERGE_ID="${1}"
    # first we need to check if the merge branch exists
    local -r MERGE_BRANCH="refs/merge/${MERGE_ID}"
    git rev-parse "${MERGE_BRANCH}" &>/dev/null || return 0
    # ensure a local copy of the upstream exists
    local -r UPSTREAM="$(_rad_upstream_name "${MERGE_BRANCH}")"
    local -r LOCAL_NAME="$(_rad_local_name "${UPSTREAM}" | sed 's#refs/heads/##')"
    git branch --track "${LOCAL_NAME}" "${UPSTREAM}" 2>/dev/null
    git push "file://${PWD}" "${MERGE_BRANCH}:${LOCAL_NAME}"
}
function _rad_merge_cleanup_each () {
    if [ $# -ne 1 ]; then
        echo "[E] Bad call to _rad_merge_cleanup_each: ${*}"
        return 127
    fi
    local -r MERGE_ID="${1}"
    # first we need to check if the merge branch exists
    local -r MERGE_BRANCH="refs/merge/${MERGE_ID}"
    git rev-parse "${MERGE_BRANCH}" &>/dev/null || return 0
    # return to the last checkout if we're on the merge branch and delete it
    local -r HEAD="$(git rev-parse HEAD)"
    local -r MAYBE_MERGE="$(git rev-parse "${MERGE_BRANCH}")"
    # we only do one checkout onto the merge branch so "@{-1}" is enough
    [ "${MAYBE_MERGE}" = "${HEAD}" ] && git checkout "@{-1}" &>/dev/null
    git branch --delete --force "refs/merge/${MERGE_ID}" >/dev/null
}
function _rad_merge_all () {
    if [ $# -ne 1 ]; then
        echo "[E] No merge source branch specified"
        return 127
    fi
    local -r MERGE_FROM="${1}"
    local -r MERGE_MSG_PATH="$(_rad_find_git_msg_path "MERGE_MESSAGE")"
    local -r MERGE_ID="$(_rad_change_id)"
    echo "Merging ${MERGE_FROM} as merge ID ${MERGE_ID}"
    # we populate an initial merge commit summary
    exec {top}<> <(cat <<EOF
merge: '${MERGE_FROM}'

EOF
)
    # we initially populate the message with a unique change ID which can be
    # used to correlate the commits in each repo later
    exec {merge_id_chunk}<> <(cat <<EOF
Merge-Id: ${MERGE_ID}

EOF
)
    exec {merge_log}<> <(
        PAGER= _repo_wrap git log --oneline --graph --decorate              \
            "${UPSTREAM}~..${MERGE_FROM}"                                   \
        2>/dev/null | sed 's/^/# /'
    )
    # pass the chunks down to populate the file which will then be edited
    local -ar chunks=( "${top}" "${merge_id_chunk}" "${merge_log}" )
    _rad_edit_commit_msg "${MERGE_MSG_PATH}" "${chunks[@]}" || return $?
    if _repo_wrap "_rad_merge_offbranch_each \"${MERGE_ID}\" \"${MERGE_MSG_PATH}\" \"${MERGE_FROM}\"";
    then
        echo "Pushing successful merge to local branch of upstream"
        _repo_wrap "_rad_merge_upstream_each \"${MERGE_ID}\""
    else
        _repo_wrap_quiet "git merge --abort 2>/dev/null"
    fi
    _repo_wrap_quiet "_rad_merge_cleanup_each \"${MERGE_ID}\""
}
alias rmerge="_rad_merge_all"

# check whatchanged for all projects between the upstream and HEAD
function _rad_whatchanged_all () {
    PAGER= _repo_wrap   \
        git whatchanged --patch --color=always                              \
            "@{upstream}..HEAD" "${@}" 2>/dev/null |                        \
        ${PAGER:-cat}
}
alias rwc="_rad_whatchanged_all"

# render a oneline log for all projects between the upstream and HEAD
function _rad_log_oneline_all () {
    PAGER= _repo_wrap   \
        git log --oneline --graph --decorate --color=always "${@}"          \
        2>&1 | ${PAGER:-cat}
}
alias rlog="_rad_log_oneline_all '@{upstream}^!' 'HEAD'"
alias rloga="_rad_log_oneline_all --branches                                \
    '^\$(git show-branch --merge-base \"refs/heads/*\" \"refs/heads/*/*\" \"@{upstream}\" 2>/dev/null)^@'   \
"
alias rlogt="_rad_log_oneline_all '^\$(git describe --tags --always --abbrev=0)^@' 'HEAD'"

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
        echo "[E] Bad call to _rad_perproj_recombine_patch: ${*}" >&2
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
        echo "[I] No patches to import :)" >&2
        return 0
    fi
    # for each of the split patches, work out to which project it applies and
    # add the diff to the project specific recombined patch file
    local -a all_rpf_paths=()
    for spf_path in "${split_patches[@]}"; do
        # We remove any rename destinations so that we don't think that the two
        # paths refer to two different files being diffed
        local rename_tos="$(
            grep -Po '(?<=rename to ).*$' "${spf_path}" | true_uniq |
            sed 's#\n#-e #'
        )"
        local tf_path="$(
            # this pattern conveniently filters out `/dev/null` targets
            grep -Po '(?<=^[-+]{3} [ab]/).*$' "${spf_path}" | true_uniq |
            grep ${rename_tos:+-v} "${rename_tos[@]:-.}"
        )"
        if [[ "${tf_path}" =~ $'\n' ]]; then
            echo "[E] Somehow we didn't manage to split up ${cpf_path##*/}" >&2
            echo "[E] ${spf_path##*/} has multiple file targets" >&2
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

# list the quilt patch series available for import
function _rad_quilt_list_one () {
    if [ $# -ne 1 ]; then
        echo "[E] Bad call to _rad_quilt_list_one: ${*}"
        return 127
    fi
    while read line; do
        cpf_path="${sf%/*}/${line}"
        echo -e "\t${line%.patch} -> $(grep '^Subject:' "${cpf_path}")"
    done <"${1}"
}
function _rad_quilt_list () {
    echo "[I] ${BOLD}Patchset series available:${RESET}"
    for sf in "${PWD}/${_RAD_QUILT_PATCHDIR}/"*series; do
        echo "${sf##*/}"
        _rad_quilt_list_one "${sf}"
    done
}
alias rql="_rad_quilt_list"

# combine named patcheset series into a single file for quilt
function _rad_combine_quilt_series () {
    local -r sf="${PWD}/${_RAD_QUILT_PATCHDIR}/series"
    if [ -f "${sf}" ]; then
        echo "[W] Overwriting the unnamed series file"
        mv -v "${sf}" "${sf}.old"
    fi
    # get an ordered series which respects `Depends:` lines in  patched
    echo "[I] Combining patchset series files"
    local -ar patchfiles=($(
        for series_name in "${@}"; do
            cat "${sf%/*}/${series_name}.series"
        done | while read patchfile_name; do
            echo "${sf%/*}/${patchfile_name}"
        done
    ))
    local -ar uniq_ordered_change_ids=($(
        for patchfile in "${patchfiles[@]}"; do
            # make sure we list dependent changes first
            grep -Pho '(?<=Depends: I)[0-9a-f]+' "${patchfile}"
            # then the actual change in this patch
            grep -Pho '(?<=Change-Id: I)[0-9a-f]+' "${patchfile}"
        done | true_uniq |  \
        grep -xf <(grep -Pho '(?<=Change-Id: I)[0-9a-f]+' "${patchfiles[@]}") -
    ))
    for change_id in "${uniq_ordered_change_ids[@]}"; do
        echo "${change_id}.patch"
    done > "${sf}"
    _rad_quilt_list_one "${sf}"
}
alias rqc="_rad_combine_quilt_series"

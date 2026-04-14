# bash/zsh git prompt support
#
#    Copyright (C) 2022 David Xu
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# This script renders posh-git-style prompt state for bash/zsh shells.
# Use `__posh_git_echo` for the async prompt string or `__posh_git_echo_sync`
# for direct synchronous output. Detailed configuration notes live in README.
#
###############################################################################

# Convenience function to set PS1 to show git status. Must supply exactly
# either two or four arguments that specify the prefix and suffix of the git
# status string.
#
#   __posh_git_ps1 PREFIX SUFFIX
#
#   __posh_git_ps1 PREFIX SUFFIX GIT_PREFIX GIT_SUFFIX
#
# In the four-argument form, uses GIT_PREFIX and GIT_SUFFIX if git status is
# present, effectively as if
#
# ${PREFIX}${GIT_PREFIX}${POSH}${GIT_SUFFIX}${SUFFIX}
#
# This function should be called in PROMPT_COMMAND or similar.
__posh_git_ps1 ()
{
    local ps1pc_prefix=
    local ps1pc_suffix=
    local git_prefix=
    local git_suffix=
    case "$#" in
        2)
            ps1pc_prefix=$1
            ps1pc_suffix=$2
            ;;
        4)
            ps1pc_prefix=$1
            ps1pc_suffix=$2
            git_prefix=$3
            git_suffix=$4
            ;;
        *)
            echo __posh_git_ps1: bad number of arguments >&2
            return
            ;;
        esac
    local gitstring=$(__posh_git_echo_sync)
    if [ -z "$gitstring" ]; then
      PS1=$ps1pc_prefix$ps1pc_suffix
    else
      PS1=$ps1pc_prefix$git_prefix$gitstring$git_suffix$ps1pc_suffix
    fi
}

__posh_color () {
    if [ -n "$ZSH_VERSION" ]; then
        echo %{$1%}
    elif [ -n "$BASH_VERSION" ]; then
        echo \\[$1\\]
    else
        # assume Bash anyway
        echo \\[$1\\]
    fi
}

__posh_git () {
    GIT_OPTIONAL_LOCKS=0 command git "$@"
}

if [ -n "$ZSH_VERSION" ]; then
    : ${POSH_GIT_ASYNC_DISABLE_OMZ_GIT_PROMPT:=true}
    if [ "$POSH_GIT_ASYNC_DISABLE_OMZ_GIT_PROMPT" = true ]; then
        (( $+functions[git_prompt_info] )) && git_prompt_info() { :; }
        (( $+functions[git_prompt_status] )) && git_prompt_status() { :; }
        (( $+functions[git_prompt_ahead] )) && git_prompt_ahead() { :; }
    fi
    zmodload zsh/datetime 2>/dev/null || true
fi

__posh_git_detect_status_features () {
    if [ -z "${_POSH_GIT_STATUS_FEATURES_DETECTED-}" ]; then
        local status_help
        status_help=$(__posh_git status -h 2>&1)

        case "$status_help" in
            *'--[no-]porcelain[=<version>]'*)
                _POSH_GIT_SUPPORTS_STATUS_V2=true
                ;;
            *)
                _POSH_GIT_SUPPORTS_STATUS_V2=false
                ;;
        esac

        case "$status_help" in
            *'--[no-]show-stash'*)
                _POSH_GIT_SUPPORTS_SHOW_STASH=true
                ;;
            *)
                _POSH_GIT_SUPPORTS_SHOW_STASH=false
                ;;
        esac

        _POSH_GIT_STATUS_FEATURES_DETECTED=true
    fi
}

__posh_git_supports_status_v2 () {
    __posh_git_detect_status_features
    [ "$_POSH_GIT_SUPPORTS_STATUS_V2" = true ]
}

__posh_git_supports_show_stash () {
    __posh_git_detect_status_features
    [ "$_POSH_GIT_SUPPORTS_SHOW_STASH" = true ]
}

__posh_git_stash_info () {
    local stash_count

    if stash_count=$(__posh_git rev-list --walk-reflogs --count refs/stash 2>/dev/null); then
        stash_count=${stash_count:-0}
        if [ "$stash_count" -gt 0 ] 2>/dev/null; then
            echo "true:$stash_count"
        else
            echo "false:0"
        fi
        return 0
    fi

    __posh_git rev-parse --verify refs/stash >/dev/null 2>&1 || {
        echo "false:0"
        return 0
    }

    stash_count=$(__posh_git rev-list --walk-reflogs --count refs/stash 2>/dev/null)
    stash_count=${stash_count:-0}
    echo "true:$stash_count"
}

__posh_git_describe_detached () {
    local g=$1
    local branch_oid=$2
    local describe_style=$(__posh_git config --get bash.describeStyle)
    local effective_style=${describe_style:-${GIT_PS1_DESCRIBESTYLE-default}}
    local detached_ref=

    detached_ref=$(
        case "$effective_style" in
        contains)
            __posh_git describe --contains HEAD
            ;;
        branch)
            __posh_git describe --contains --all HEAD
            ;;
        describe)
            __posh_git describe HEAD
            ;;
        * | default)
            __posh_git describe --tags --exact-match HEAD
            ;;
        esac 2>/dev/null
    ) || detached_ref=

    if [ -z "$detached_ref" ]; then
        detached_ref=${branch_oid:-$(__posh_git rev-parse --short HEAD 2>/dev/null)}
    fi
    if [ -z "$detached_ref" ] && [ -n "$g" ]; then
        detached_ref=$(cut -c1-7 "$g/HEAD" 2>/dev/null)
    fi
    detached_ref=${detached_ref:-unknown}
    echo "($detached_ref)"
}

__posh_git_resolve_ref () {
    local g=$1
    local branch_ref=

    branch_ref=$(__posh_git symbolic-ref HEAD 2>/dev/null) || {
        local branch_oid=$(__posh_git rev-parse --short HEAD 2>/dev/null)
        branch_ref=$(__posh_git_describe_detached "$g" "$branch_oid")
    }

    echo "$branch_ref"
}

__posh_git_reset_counters () {
    __POSH_INDEX_ADDED=0
    __POSH_INDEX_MODIFIED=0
    __POSH_INDEX_DELETED=0
    __POSH_INDEX_UNMERGED=0
    __POSH_FILES_ADDED=0
    __POSH_FILES_MODIFIED=0
    __POSH_FILES_DELETED=0
    __POSH_FILES_UNMERGED=0
}

__posh_git_tally_xy () {
    local xy=$1

    case "${xy[1,1]}" in
        A)
            (( __POSH_INDEX_ADDED++ ))
            ;;
        M | T | R | C)
            (( __POSH_INDEX_MODIFIED++ ))
            ;;
        D)
            (( __POSH_INDEX_DELETED++ ))
            ;;
        U)
            (( __POSH_INDEX_UNMERGED++ ))
            ;;
    esac

    case "${xy[2,2]}" in
        A | \?)
            (( __POSH_FILES_ADDED++ ))
            ;;
        M | T)
            (( __POSH_FILES_MODIFIED++ ))
            ;;
        D)
            (( __POSH_FILES_DELETED++ ))
            ;;
        U)
            (( __POSH_FILES_UNMERGED++ ))
            ;;
    esac
}

__posh_git_parse_bool () {
    case "$1" in
        [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn] | 1)
            REPLY=true
            ;;
        [Ff][Aa][Ll][Ss][Ee] | [Nn][Oo] | [Oo][Ff][Ff] | 0)
            REPLY=false
            ;;
        *)
            REPLY=$2
            ;;
    esac
}

__posh_git_load_config () {
    local config_output=
    local config_key=
    local config_value=

    __POSH_CFG_ENABLE_GIT_STATUS=true
    __POSH_CFG_BRANCH_BEHIND_AND_AHEAD_DISPLAY=full
    __POSH_CFG_ENABLE_FILE_STATUS=true
    __POSH_CFG_SHOW_STATUS_WHEN_ZERO=false
    __POSH_CFG_ENABLE_STASH_STATUS=true
    __POSH_CFG_ENABLE_STATUS_SYMBOL=true

    config_output=$(__posh_git config -z --get-regexp '^bash\.(enablegitstatus|branchbehindandaheaddisplay|enablefilestatus|showstatuswhenzero|enablestashstatus|enablestatussymbol)$' 2>/dev/null | tr '\0' '\n')
    while IFS= read -r config_key && IFS= read -r config_value; do
        case "$config_key" in
            bash.enablegitstatus)
                __posh_git_parse_bool "$config_value" true
                __POSH_CFG_ENABLE_GIT_STATUS=$REPLY
                ;;
            bash.branchbehindandaheaddisplay)
                __POSH_CFG_BRANCH_BEHIND_AND_AHEAD_DISPLAY=$config_value
                ;;
            bash.enablefilestatus)
                __posh_git_parse_bool "$config_value" true
                __POSH_CFG_ENABLE_FILE_STATUS=$REPLY
                ;;
            bash.showstatuswhenzero)
                __posh_git_parse_bool "$config_value" false
                __POSH_CFG_SHOW_STATUS_WHEN_ZERO=$REPLY
                ;;
            bash.enablestashstatus)
                __posh_git_parse_bool "$config_value" true
                __POSH_CFG_ENABLE_STASH_STATUS=$REPLY
                ;;
            bash.enablestatussymbol)
                __posh_git_parse_bool "$config_value" true
                __POSH_CFG_ENABLE_STATUS_SYMBOL=$REPLY
                ;;
        esac
    done <<< "$config_output"
}

__posh_git_detect_rebase_state () {
    local g=$1
    local step=''
    local total=''

    __POSH_STATE_REBASE=''
    __POSH_STATE_BRANCH=''
    __POSH_STATE_BRANCH_OID=''

    if [ -d "$g/rebase-merge" ]; then
        __POSH_STATE_BRANCH=$(<"$g/rebase-merge/head-name" 2>/dev/null)
        step=$(<"$g/rebase-merge/msgnum" 2>/dev/null)
        total=$(<"$g/rebase-merge/end" 2>/dev/null)
        if [ -f "$g/rebase-merge/interactive" ]; then
            __POSH_STATE_REBASE='|REBASE-i'
        else
            __POSH_STATE_REBASE='|REBASE-m'
        fi
    elif [ -d "$g/rebase-apply" ]; then
        step=$(<"$g/rebase-apply/next" 2>/dev/null)
        total=$(<"$g/rebase-apply/last" 2>/dev/null)
        if [ -f "$g/rebase-apply/rebasing" ]; then
            __POSH_STATE_REBASE='|REBASE'
        elif [ -f "$g/rebase-apply/applying" ]; then
            __POSH_STATE_REBASE='|AM'
        else
            __POSH_STATE_REBASE='|AM/REBASE'
        fi
    elif [ -f "$g/MERGE_HEAD" ]; then
        __POSH_STATE_REBASE='|MERGING'
    elif [ -f "$g/CHERRY_PICK_HEAD" ]; then
        __POSH_STATE_REBASE='|CHERRY-PICKING'
    elif [ -f "$g/REVERT_HEAD" ]; then
        __POSH_STATE_REBASE='|REVERTING'
    elif [ -f "$g/BISECT_LOG" ]; then
        __POSH_STATE_REBASE='|BISECTING'
    fi

    if [ -n "$step" ] && [ -n "$total" ]; then
        __POSH_STATE_REBASE="$__POSH_STATE_REBASE $step/$total"
    fi
}

__posh_git_detect_repo_context () {
    local repo_state_output=
    local repo_state_value=
    local repo_state_index=0

    __POSH_STATE_INSIDE_GIT_DIR=false
    __POSH_STATE_INSIDE_WORK_TREE=false
    __POSH_STATE_IS_BARE_REPO=false

    repo_state_output=$(__posh_git rev-parse --is-inside-git-dir --is-bare-repository --is-inside-work-tree 2>/dev/null)
    while IFS= read -r repo_state_value; do
        (( repo_state_index++ ))
        case "$repo_state_index:$repo_state_value" in
            1:true)
                __POSH_STATE_INSIDE_GIT_DIR=true
                ;;
            2:true)
                __POSH_STATE_IS_BARE_REPO=true
                ;;
            3:true)
                __POSH_STATE_INSIDE_WORK_TREE=true
                ;;
        esac
    done <<< "$repo_state_output"
}

__posh_git_load_stash_state () {
    local stash_info=

    if ! $__POSH_CFG_ENABLE_STASH_STATUS; then
        return
    fi

    stash_info=$(__posh_git_stash_info)
    __POSH_STATE_HAS_STASH=${stash_info%%:*}
    __POSH_STATE_STASH_COUNT=${stash_info#*:}
}

__posh_git_update_divergence_state () {
    __posh_git_ps1_upstream_divergence
    __POSH_STATE_DIVERGENCE_RETURN_CODE=$?
}

__posh_git_collect_status_v2 () {
    local g=$1
    local status_cmd=(status --porcelain=v2 --branch -z)
    local status_record=
    local branch_head=
    local has_upstream=false

    if $__POSH_CFG_ENABLE_STASH_STATUS && __posh_git_supports_show_stash; then
        status_cmd+=(--show-stash)
    fi

    while IFS= read -r -d '' status_record; do
        case "$status_record" in
            '# branch.head '*)
                branch_head=${status_record#'# branch.head '}
                ;;
            '# branch.oid '*)
                __POSH_STATE_BRANCH_OID=${status_record#'# branch.oid '}
                [ "$__POSH_STATE_BRANCH_OID" = '(initial)' ] && __POSH_STATE_BRANCH_OID=
                ;;
            '# branch.upstream '*)
                has_upstream=true
                ;;
            '# branch.ab '*)
                __POSH_BRANCH_AHEAD_BY=${${status_record#'# branch.ab +'}%% -*}
                __POSH_BRANCH_BEHIND_BY=${status_record##* -}
                __POSH_STATE_DIVERGENCE_RETURN_CODE=0
                has_upstream=true
                ;;
            '# stash '*)
                __POSH_STATE_STASH_COUNT=${status_record#'# stash '}
                __POSH_STATE_HAS_STASH=true
                ;;
            '1 '* | 'u '*)
                __posh_git_tally_xy "${status_record[3,4]}"
                ;;
            '2 '*)
                __posh_git_tally_xy "${status_record[3,4]}"
                IFS= read -r -d '' -u 0 _posh_git_orig_path_unused
                ;;
            \?\ *)
                (( __POSH_FILES_ADDED++ ))
                ;;
        esac
    done < <(__posh_git "${status_cmd[@]}" 2>/dev/null)

    if [ -n "$branch_head" ]; then
        if [ "$branch_head" = '(detached)' ]; then
            __POSH_STATE_BRANCH=$(__posh_git_describe_detached "$g" "$__POSH_STATE_BRANCH_OID")
        else
            __POSH_STATE_BRANCH="refs/heads/$branch_head"
        fi
    fi

    if ! $has_upstream; then
        __POSH_STATE_DIVERGENCE_RETURN_CODE=1
    fi

    if $__POSH_CFG_ENABLE_STASH_STATUS && ! $__POSH_STATE_HAS_STASH && ! __posh_git_supports_show_stash; then
        __posh_git_load_stash_state
    fi
}

__posh_git_collect_status_v1 () {
    local status_record=

    if $__POSH_STATE_INSIDE_WORK_TREE; then
        __posh_git_load_stash_state
        __posh_git_update_divergence_state
    fi

    if ! $__POSH_CFG_ENABLE_FILE_STATUS; then
        return
    fi

    while IFS= read -r -d '' status_record; do
        case "${status_record:0:2}" in
            '??')
                (( __POSH_FILES_ADDED++ ))
                ;;
            *)
                __posh_git_tally_xy "${status_record:0:2}"
                case "${status_record:0:1}" in
                    R | C)
                        IFS= read -r -d '' -u 0 _posh_git_orig_path_unused
                        ;;
                esac
                ;;
        esac
    done < <(__posh_git status --porcelain=v1 -z 2>/dev/null)
}

__posh_git_collect_prompt_state () {
    local g=$1

    __POSH_STATE_HAS_STASH=false
    __POSH_STATE_STASH_COUNT=0
    __POSH_STATE_IS_BARE=''
    __POSH_STATE_DIVERGENCE_RETURN_CODE=1

    __POSH_BRANCH_AHEAD_BY=0
    __POSH_BRANCH_BEHIND_BY=0
    __posh_git_reset_counters

    __posh_git_detect_rebase_state "$g"
    __posh_git_detect_repo_context

    if ! $__POSH_CFG_ENABLE_FILE_STATUS; then
        if $__POSH_STATE_INSIDE_WORK_TREE; then
            __posh_git_load_stash_state
            __posh_git_update_divergence_state
        fi
    elif $__POSH_STATE_INSIDE_WORK_TREE && __posh_git_supports_status_v2; then
        __posh_git_collect_status_v2 "$g"
    else
        __posh_git_collect_status_v1
    fi

    if [ -z "$__POSH_STATE_BRANCH" ]; then
        __POSH_STATE_BRANCH=$(__posh_git_resolve_ref "$g")
    fi

    if $__POSH_STATE_INSIDE_GIT_DIR; then
        if $__POSH_STATE_IS_BARE_REPO; then
            __POSH_STATE_IS_BARE='BARE:'
        else
            __POSH_STATE_BRANCH='GIT_DIR!'
        fi
    fi
}

__posh_git_render_prompt () {
    local Red='\033[0;31m'
    local Green='\033[0;32m'
    local BrightRed='\033[0;91m'
    local BrightGreen='\033[0;92m'
    local BrightYellow='\033[0;93m'
    local BrightCyan='\033[0;96m'

    local DefaultForegroundColor=$(__posh_color '\e[m') # Default no color
    local DefaultBackgroundColor=

    local BeforeText='['
    local BeforeForegroundColor=$(__posh_color $BrightYellow) # Yellow
    local BeforeBackgroundColor=
    local DelimText=' |'
    local DelimForegroundColor=$(__posh_color $BrightYellow) # Yellow
    local DelimBackgroundColor=

    local AfterText=']'
    local AfterForegroundColor=$(__posh_color $BrightYellow) # Yellow
    local AfterBackgroundColor=

    local BranchForegroundColor=$(__posh_color $BrightCyan)  # Cyan
    local BranchBackgroundColor=
    local BranchAheadForegroundColor=$(__posh_color $BrightGreen) # Green
    local BranchAheadBackgroundColor=
    local BranchBehindForegroundColor=$(__posh_color $BrightRed) # Red
    local BranchBehindBackgroundColor=
    local BranchBehindAndAheadForegroundColor=$(__posh_color $BrightYellow) # Yellow
    local BranchBehindAndAheadBackgroundColor=

    local IndexForegroundColor=$(__posh_color $Green) # Dark green
    local IndexBackgroundColor=

    local WorkingForegroundColor=$(__posh_color $Red) # Dark red
    local WorkingBackgroundColor=

    local StashForegroundColor=$(__posh_color $BrightRed) # Red
    local StashBackgroundColor=
    local BeforeStash='('
    local AfterStash=')'

    local LocalDefaultStatusSymbol=''
    local LocalWorkingStatusSymbol=' !'
    local LocalWorkingStatusColor=$(__posh_color "$Red")
    local LocalStagedStatusSymbol=' ~'
    local LocalStagedStatusColor=$(__posh_color "$BrightCyan")

    local RebaseForegroundColor=$(__posh_color '\e[0m') # reset
    local RebaseBackgroundColor=

    local BranchIdenticalStatusSymbol=''
    local BranchAheadStatusSymbol=''
    local BranchBehindStatusSymbol=''
    local BranchBehindAndAheadStatusSymbol=''
    local BranchWarningStatusSymbol=''

    if $__POSH_CFG_ENABLE_STATUS_SYMBOL; then
        BranchIdenticalStatusSymbol=$' \xE2\x89\xA1' # Three horizontal lines
        BranchAheadStatusSymbol=$' \xE2\x86\x91' # Up Arrow
        BranchBehindStatusSymbol=$' \xE2\x86\x93' # Down Arrow
        BranchBehindAndAheadStatusSymbol=$'\xE2\x86\x95' # Up and Down Arrow
        BranchWarningStatusSymbol=' ?'
    fi

    local gitstring=
    local branchstring="$__POSH_STATE_IS_BARE${__POSH_STATE_BRANCH##refs/heads/}"

    gitstring="$BeforeBackgroundColor$BeforeForegroundColor$BeforeText"

    if (( $__POSH_BRANCH_BEHIND_BY > 0 && $__POSH_BRANCH_AHEAD_BY > 0 )); then
        gitstring+="$BranchBehindAndAheadBackgroundColor$BranchBehindAndAheadForegroundColor$branchstring"
        if [ "$__POSH_CFG_BRANCH_BEHIND_AND_AHEAD_DISPLAY" = "full" ]; then
            gitstring+="$BranchBehindStatusSymbol$__POSH_BRANCH_BEHIND_BY$BranchAheadStatusSymbol$__POSH_BRANCH_AHEAD_BY"
        elif [ "$__POSH_CFG_BRANCH_BEHIND_AND_AHEAD_DISPLAY" = "compact" ]; then
            gitstring+=" $__POSH_BRANCH_BEHIND_BY$BranchBehindAndAheadStatusSymbol$__POSH_BRANCH_AHEAD_BY"
        else
            gitstring+=" $BranchBehindAndAheadStatusSymbol"
        fi
    elif (( $__POSH_BRANCH_BEHIND_BY > 0 )); then
        gitstring+="$BranchBehindBackgroundColor$BranchBehindForegroundColor$branchstring"
        if [ "$__POSH_CFG_BRANCH_BEHIND_AND_AHEAD_DISPLAY" = "full" -o "$__POSH_CFG_BRANCH_BEHIND_AND_AHEAD_DISPLAY" = "compact" ]; then
            gitstring+="$BranchBehindStatusSymbol$__POSH_BRANCH_BEHIND_BY"
        else
            gitstring+="$BranchBehindStatusSymbol"
        fi
    elif (( $__POSH_BRANCH_AHEAD_BY > 0 )); then
        gitstring+="$BranchAheadBackgroundColor$BranchAheadForegroundColor$branchstring"
        if [ "$__POSH_CFG_BRANCH_BEHIND_AND_AHEAD_DISPLAY" = "full" -o "$__POSH_CFG_BRANCH_BEHIND_AND_AHEAD_DISPLAY" = "compact" ]; then
            gitstring+="$BranchAheadStatusSymbol$__POSH_BRANCH_AHEAD_BY"
        else
            gitstring+="$BranchAheadStatusSymbol"
        fi
    elif (( $__POSH_STATE_DIVERGENCE_RETURN_CODE )); then
        gitstring+="$BranchBackgroundColor$BranchForegroundColor$branchstring$BranchWarningStatusSymbol"
    else
        gitstring+="$BranchBackgroundColor$BranchForegroundColor$branchstring$BranchIdenticalStatusSymbol"
    fi

    gitstring+="${__POSH_STATE_REBASE:+$RebaseForegroundColor$RebaseBackgroundColor$__POSH_STATE_REBASE}"

    if $__POSH_CFG_ENABLE_FILE_STATUS; then
        local indexCount="$(( __POSH_INDEX_ADDED + __POSH_INDEX_MODIFIED + __POSH_INDEX_DELETED + __POSH_INDEX_UNMERGED ))"
        local workingCount="$(( __POSH_FILES_ADDED + __POSH_FILES_MODIFIED + __POSH_FILES_DELETED + __POSH_FILES_UNMERGED ))"
        local localStatusSymbol=$LocalDefaultStatusSymbol
        local localStatusColor=$DefaultForegroundColor

        if (( indexCount != 0 )) || $__POSH_CFG_SHOW_STATUS_WHEN_ZERO; then
            gitstring+="$IndexBackgroundColor$IndexForegroundColor +$__POSH_INDEX_ADDED ~$__POSH_INDEX_MODIFIED -$__POSH_INDEX_DELETED"
        fi
        if (( $__POSH_INDEX_UNMERGED != 0 )); then
            gitstring+=" $IndexBackgroundColor$IndexForegroundColor!$__POSH_INDEX_UNMERGED"
        fi
        if (( indexCount != 0 && (workingCount != 0 || $__POSH_CFG_SHOW_STATUS_WHEN_ZERO) )); then
            gitstring+="$DelimBackgroundColor$DelimForegroundColor$DelimText"
        fi
        if (( workingCount != 0 )) || $__POSH_CFG_SHOW_STATUS_WHEN_ZERO; then
            gitstring+="$WorkingBackgroundColor$WorkingForegroundColor +$__POSH_FILES_ADDED ~$__POSH_FILES_MODIFIED -$__POSH_FILES_DELETED"
        fi
        if (( $__POSH_FILES_UNMERGED != 0 )); then
            gitstring+=" $WorkingBackgroundColor$WorkingForegroundColor!$__POSH_FILES_UNMERGED"
        fi

        if (( workingCount != 0 )); then
            localStatusSymbol=$LocalWorkingStatusSymbol
            localStatusColor=$LocalWorkingStatusColor
        elif (( indexCount != 0 )); then
            localStatusSymbol=$LocalStagedStatusSymbol
            localStatusColor=$LocalStagedStatusColor
        fi

        gitstring+="$DefaultBackgroundColor$localStatusColor$localStatusSymbol$DefaultForegroundColor"

        if $__POSH_CFG_ENABLE_STASH_STATUS && $__POSH_STATE_HAS_STASH; then
            gitstring+="$DefaultBackgroundColor$DefaultForegroundColor $StashBackgroundColor$StashForegroundColor$BeforeStash$__POSH_STATE_STASH_COUNT$AfterStash"
        fi
    fi

    gitstring+="$AfterBackgroundColor$AfterForegroundColor$AfterText$DefaultBackgroundColor$DefaultForegroundColor"
    echo "$gitstring"
}

# Echoes the git status string.
__posh_git_echo_sync () {
    local g

    __posh_git_load_config
    if ! $__POSH_CFG_ENABLE_GIT_STATUS; then
        return
    fi

    g=$(__posh_gitdir)
    if [ -z "$g" ]; then
        return
    fi

    __posh_git_collect_prompt_state "$g"
    __posh_git_render_prompt
}

# Returns the location of the .git/ directory.
__posh_gitdir ()
{
    # Note: this function is duplicated in git-completion.bash
    # When updating it, make sure you update the other one to match.
    if [ -z "${1-}" ]; then
        if [ -n "${__posh_git_dir-}" ]; then
            echo "$__posh_git_dir"
        elif [ -n "${GIT_DIR-}" ]; then
            test -d "${GIT_DIR-}" || return 1
            echo "$GIT_DIR"
        elif [ -d .git ]; then
            echo .git
        else
            __posh_git rev-parse --git-dir 2>/dev/null
        fi
    elif [ -d "$1/.git" ]; then
        echo "$1/.git"
    else
        echo "$1"
    fi
}

# Updates the global variables `__POSH_BRANCH_AHEAD_BY` and `__POSH_BRANCH_BEHIND_BY`.
__posh_git_ps1_upstream_divergence ()
{
    local key value
    local svn_remote svn_url_pattern
    local upstream=git          # default
    local legacy=''

    svn_remote=()
    local _show_upstream_configured=false
    # get some config options from git-config
    local output="$(__posh_git config -z --get-regexp '^(svn-remote\..*\.url|bash\.showUpstream)$' 2>/dev/null | tr '\0\n' '\n ')"
    while read -r key value; do
        case "$key" in
        bash.showupstream)
            GIT_PS1_SHOWUPSTREAM="$value"
            _show_upstream_configured=true
            ;;
        svn-remote.*.url)
            svn_remote[ $((${#svn_remote[@]} + 1)) ]="$value"
            svn_url_pattern+="\\|$value"
            upstream=svn+git # default upstream is SVN if available, else git
            ;;
        esac
    done <<< "$output"

    if $_show_upstream_configured && [ -z "${GIT_PS1_SHOWUPSTREAM}" ]; then
        return
    fi

    # parse configuration values
    for option in ${=GIT_PS1_SHOWUPSTREAM}; do
        case "$option" in
        git|svn) upstream="$option" ;;
        legacy)  legacy=1  ;;
        esac
    done

    # Find our upstream
    case "$upstream" in
    git)    upstream='@{upstream}' ;;
    svn*)
        # get the upstream from the "git-svn-id: ..." in a commit message
        # (git-svn uses essentially the same procedure internally)
        local svn_upstream=($(__posh_git log --first-parent -1 \
                    --grep="^git-svn-id: \(${svn_url_pattern#??}\)" 2>/dev/null))
        if (( 0 != ${#svn_upstream[@]} )); then
            svn_upstream=${svn_upstream[ ${#svn_upstream[@]} - 2 ]}
            svn_upstream=${svn_upstream%@*}
            local n_stop="${#svn_remote[@]}"
            local n
            for ((n=1; n <= n_stop; n++)); do
                svn_upstream=${svn_upstream#${svn_remote[$n]}}
            done

            if [ -z "$svn_upstream" ]; then
                # default branch name for checkouts with no layout:
                upstream=${GIT_SVN_ID:-git-svn}
            else
                upstream=${svn_upstream#/}
            fi
        elif [ 'svn+git' = "$upstream" ]; then
            upstream='@{upstream}'
        fi
        ;;
    esac

    local return_code=
    __POSH_BRANCH_AHEAD_BY=0
    __POSH_BRANCH_BEHIND_BY=0
    # Find how many commits we are ahead/behind our upstream
    if [ -z "$legacy" ]; then
        local output=
        output=$(__posh_git rev-list --count --left-right "${upstream}...HEAD" 2>/dev/null)
        return_code=$?
        IFS=$' \t\n' read -r __POSH_BRANCH_BEHIND_BY __POSH_BRANCH_AHEAD_BY <<< "$output"
    else
        local output
        output=$(__posh_git rev-list --left-right "${upstream}...HEAD" 2>/dev/null)
        return_code=$?
        # produce equivalent output to --count for older versions of git
        while IFS=$' \t\n' read -r commit; do
            case "$commit" in
            "<"*) (( __POSH_BRANCH_BEHIND_BY++ )) ;;
            ">"*) (( __POSH_BRANCH_AHEAD_BY++ ))  ;;
            esac
        done <<< "$output"
    fi
    : ${__POSH_BRANCH_AHEAD_BY:=0}
    : ${__POSH_BRANCH_BEHIND_BY:=0}
    return "$return_code"
}

# =============================================================================
# Async wrapper
# Replaces synchronous __posh_git_echo with a non-blocking cached version.
# Background job runs __posh_git_echo_sync and signals the main shell on done.
# =============================================================================

_posh_git_result=""
_posh_git_result_key=""
_posh_git_job_pid=0
_posh_git_fd=-1
_posh_git_job_key=""
_posh_git_display_key=""
_posh_git_refresh_pending=false
_posh_git_refresh_deferred=false
typeset -gF _posh_git_job_started_at=0
typeset -gF _posh_git_last_refresh_at=0
typeset -gF _posh_git_last_completed_at=0
_posh_git_last_completed_key=""

: ${POSH_GIT_ASYNC_DEBOUNCE_SECONDS:=0.25}
: ${POSH_GIT_ASYNC_TIMEOUT_SECONDS:=5}

_posh_git_repo_key() {
    local g=$(__posh_gitdir)
    [ -z "$g" ] && return
    print -r -- "${g:A}"
}

_posh_git_now() {
    print -r -- "${EPOCHREALTIME:-0}"
}

_posh_git_cancel_job() {
    if (( _posh_git_job_pid )); then
        kill $_posh_git_job_pid 2>/dev/null
    fi
    if (( _posh_git_fd >= 0 )); then
        zle -F $_posh_git_fd 2>/dev/null
        exec {_posh_git_fd}<&-
    fi
    _posh_git_job_pid=0
    _posh_git_fd=-1
    _posh_git_job_key=""
    _posh_git_refresh_pending=false
    _posh_git_refresh_deferred=false
    _posh_git_job_started_at=0
}

_posh_git_start_job() {
    local job_key=$1
    exec {_posh_git_fd}< <(print -r -- "$job_key"; __posh_git_echo_sync 2>/dev/null; echo)
    _posh_git_job_pid=$!
    _posh_git_job_key=$job_key
    _posh_git_job_started_at=$(_posh_git_now)
    _posh_git_last_refresh_at=$_posh_git_job_started_at
    zle -F $_posh_git_fd _posh_git_on_ready
}

__posh_git_echo() {
    if [ -n "$_posh_git_display_key" ] && [ "$_posh_git_display_key" = "$_posh_git_result_key" ]; then
        echo "$_posh_git_result"
    fi
}

_posh_git_on_ready() {
    local fd=$1
    local result_key
    local next_result
    local now
    local should_reset=false

    IFS= read -r -u $fd result_key
    IFS= read -r -u $fd next_result
    zle -F $fd
    exec {fd}<&-
    # Only clear the job pid when the completed fd matches the current one,
    # preventing a stale callback from zeroing out a newer job's pid.
    if (( fd == _posh_git_fd )); then
        _posh_git_job_pid=0
        _posh_git_fd=-1
        _posh_git_job_key=""
        _posh_git_job_started_at=0
    fi
    now=$(_posh_git_now)
    _posh_git_last_completed_at=$now
    _posh_git_last_completed_key=$result_key

    if [ "$result_key" = "$_posh_git_display_key" ] && [[ $next_result != $_posh_git_result || $result_key != $_posh_git_result_key ]]; then
        _posh_git_result=$next_result
        _posh_git_result_key=$result_key
        if [ "$_posh_git_refresh_pending" = true ]; then
            _posh_git_refresh_deferred=true
        else
            should_reset=true
        fi
    fi

    if [ "$_posh_git_refresh_pending" = true ] && [ "$result_key" = "$_posh_git_display_key" ]; then
        _posh_git_refresh_pending=false
        _posh_git_start_job "$result_key"
    elif [ "$_posh_git_refresh_deferred" = true ] && [ "$result_key" = "$_posh_git_display_key" ]; then
        _posh_git_refresh_deferred=false
        should_reset=true
    fi

    if $should_reset; then
        [[ -o zle ]] && zle reset-prompt
    fi
}

_posh_git_async_refresh() {
    local next_key=$(_posh_git_repo_key)
    local now=$(_posh_git_now)
    _posh_git_display_key=$next_key

    if [ -z "$next_key" ]; then
        _posh_git_cancel_job
        _posh_git_result=""
        _posh_git_result_key=""
        _posh_git_refresh_deferred=false
        return
    fi

    if [ "$next_key" != "$_posh_git_result_key" ]; then
        _posh_git_result=""
    fi

    if (( _posh_git_job_pid )); then
        if (( now > 0 )) && (( _posh_git_job_started_at > 0 )) && (( now - _posh_git_job_started_at >= POSH_GIT_ASYNC_TIMEOUT_SECONDS )); then
            _posh_git_cancel_job
        elif [ "$_posh_git_job_key" = "$next_key" ]; then
            if (( now == 0 )) || (( _posh_git_last_refresh_at == 0 )) || (( now - _posh_git_last_refresh_at >= POSH_GIT_ASYNC_DEBOUNCE_SECONDS )); then
                _posh_git_refresh_pending=true
                _posh_git_last_refresh_at=$now
            fi
            return
        else
            _posh_git_cancel_job
        fi
    fi

    if (( now > 0 )) \
        && (( _posh_git_last_completed_at > 0 )) \
        && [ "$_posh_git_last_completed_key" = "$next_key" ] \
        && (( now - _posh_git_last_completed_at < POSH_GIT_ASYNC_DEBOUNCE_SECONDS )); then
        return
    fi

    _posh_git_start_job "$next_key"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _posh_git_async_refresh

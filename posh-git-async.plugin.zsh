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

# Echoes the git status string.
__posh_git_echo_sync () {
    local config_output=
    local config_key=
    local config_value=
    local EnableGitStatus=true
    local BranchBehindAndAheadDisplay=full
    local EnableFileStatus=true
    local ShowStatusWhenZero=false
    local EnableStashStatus=true
    local EnableStatusSymbol=true

    config_output=$(__posh_git config -z --get-regexp '^bash\.(enablegitstatus|branchbehindandaheaddisplay|enablefilestatus|showstatuswhenzero|enablestashstatus|enablestatussymbol)$' 2>/dev/null | tr '\0' '\n')
    while IFS= read -r config_key && IFS= read -r config_value; do
        case "$config_key" in
            bash.enablegitstatus)
                __posh_git_parse_bool "$config_value" true
                EnableGitStatus=$REPLY
                ;;
            bash.branchbehindandaheaddisplay)
                BranchBehindAndAheadDisplay=$config_value
                ;;
            bash.enablefilestatus)
                __posh_git_parse_bool "$config_value" true
                EnableFileStatus=$REPLY
                ;;
            bash.showstatuswhenzero)
                __posh_git_parse_bool "$config_value" false
                ShowStatusWhenZero=$REPLY
                ;;
            bash.enablestashstatus)
                __posh_git_parse_bool "$config_value" true
                EnableStashStatus=$REPLY
                ;;
            bash.enablestatussymbol)
                __posh_git_parse_bool "$config_value" true
                EnableStatusSymbol=$REPLY
                ;;
        esac
    done <<< "$config_output"

    if ! $EnableGitStatus; then
        return
    fi

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

    local BeforeIndexText=''
    local BeforeIndexForegroundColor=$(__posh_color $Green) # Dark green
    local BeforeIndexBackgroundColor=

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
    if $EnableStatusSymbol; then
      BranchIdenticalStatusSymbol=$' \xE2\x89\xA1' # Three horizontal lines
      BranchAheadStatusSymbol=$' \xE2\x86\x91' # Up Arrow
      BranchBehindStatusSymbol=$' \xE2\x86\x93' # Down Arrow
      BranchBehindAndAheadStatusSymbol=$'\xE2\x86\x95' # Up and Down Arrow
      BranchWarningStatusSymbol=' ?'
    fi

    # these globals are updated by __posh_git_ps1_upstream_divergence
    __POSH_BRANCH_AHEAD_BY=0
    __POSH_BRANCH_BEHIND_BY=0

    local g=$(__posh_gitdir)
    if [ -z "$g" ]; then
        return # not a git directory
    fi
    local rebase=''
    local b=''
    local branch_oid=''
    local step=''
    local total=''
    if [ -d "$g/rebase-merge" ]; then
        b=$(<"$g/rebase-merge/head-name" 2>/dev/null)
        step=$(<"$g/rebase-merge/msgnum" 2>/dev/null)
        total=$(<"$g/rebase-merge/end" 2>/dev/null)
        if [ -f "$g/rebase-merge/interactive" ]; then
            rebase='|REBASE-i'
        else
            rebase='|REBASE-m'
        fi
    else
        if [ -d "$g/rebase-apply" ]; then
            step=$(<"$g/rebase-apply/next" 2>/dev/null)
            total=$(<"$g/rebase-apply/last" 2>/dev/null)
            if [ -f "$g/rebase-apply/rebasing" ]; then
                rebase='|REBASE'
            elif [ -f "$g/rebase-apply/applying" ]; then
                rebase='|AM'
            else
                rebase='|AM/REBASE'
            fi
        elif [ -f "$g/MERGE_HEAD" ]; then
            rebase='|MERGING'
        elif [ -f "$g/CHERRY_PICK_HEAD" ]; then
            rebase='|CHERRY-PICKING'
        elif [ -f "$g/REVERT_HEAD" ]; then
            rebase='|REVERTING'
        elif [ -f "$g/BISECT_LOG" ]; then
            rebase='|BISECTING'
        fi
    fi

    if [ -n "$step" ] && [ -n "$total" ]; then
        rebase="$rebase $step/$total"
    fi

    local hasStash=false
    local stashCount=0
    local isBare=''
    local divergence_return_code=1
    local inside_git_dir=false
    local inside_work_tree=false
    local is_bare_repo=false
    local repo_state_output=
    local repo_state_value=
    local repo_state_index=0
    local stash_info=

    __posh_git_reset_counters

    repo_state_output=$(__posh_git rev-parse --is-inside-git-dir --is-bare-repository --is-inside-work-tree 2>/dev/null)
    while IFS= read -r repo_state_value; do
        (( repo_state_index++ ))
        case "$repo_state_index:$repo_state_value" in
            1:true)
                inside_git_dir=true
                ;;
            2:true)
                is_bare_repo=true
                ;;
            3:true)
                inside_work_tree=true
                ;;
        esac
    done <<< "$repo_state_output"

    if ! $EnableFileStatus; then
        if $inside_work_tree; then
            if $EnableStashStatus; then
                stash_info=$(__posh_git_stash_info)
                hasStash=${stash_info%%:*}
                stashCount=${stash_info#*:}
            fi
            __posh_git_ps1_upstream_divergence
            divergence_return_code=$?
        fi
    elif $inside_work_tree && __posh_git_supports_status_v2; then
        local status_cmd=(status --porcelain=v2 --branch -z)
        local status_record=
        local branch_head=
        local has_upstream=false

        if $EnableStashStatus && __posh_git_supports_show_stash; then
            status_cmd+=(--show-stash)
        fi

        while IFS= read -r -d '' status_record; do
            case "$status_record" in
                '# branch.head '*)
                    branch_head=${status_record#'# branch.head '}
                    ;;
                '# branch.oid '*)
                    branch_oid=${status_record#'# branch.oid '}
                    [ "$branch_oid" = '(initial)' ] && branch_oid=
                    ;;
                '# branch.upstream '*)
                    has_upstream=true
                    ;;
                '# branch.ab '*)
                    __POSH_BRANCH_AHEAD_BY=${${status_record#'# branch.ab +'}%% -*}
                    __POSH_BRANCH_BEHIND_BY=${status_record##* -}
                    divergence_return_code=0
                    has_upstream=true
                    ;;
                '# stash '*)
                    stashCount=${status_record#'# stash '}
                    hasStash=true
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
                b=$(__posh_git_describe_detached "$g" "$branch_oid")
            else
                b="refs/heads/$branch_head"
            fi
        fi

        if ! $has_upstream; then
            divergence_return_code=1
        fi

        if $EnableStashStatus && ! $hasStash && ! __posh_git_supports_show_stash; then
            stash_info=$(__posh_git_stash_info)
            hasStash=${stash_info%%:*}
            stashCount=${stash_info#*:}
        fi
    else
        if $inside_work_tree; then
            if $EnableStashStatus; then
                stash_info=$(__posh_git_stash_info)
                hasStash=${stash_info%%:*}
                stashCount=${stash_info#*:}
            fi
            __posh_git_ps1_upstream_divergence
            divergence_return_code=$?
        fi

        # show index status and working directory status
        if $EnableFileStatus; then
            local status_record=
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
        fi
    fi

    if [ -z "$b" ]; then
        b=$(__posh_git_resolve_ref "$g")
    fi

    if $inside_git_dir; then
        if $is_bare_repo; then
            isBare='BARE:'
        else
            b='GIT_DIR!'
        fi
    fi

    local gitstring=
    local branchstring="$isBare${b##refs/heads/}"

    # before-branch text
    gitstring="$BeforeBackgroundColor$BeforeForegroundColor$BeforeText"

    # branch
    if (( $__POSH_BRANCH_BEHIND_BY > 0 && $__POSH_BRANCH_AHEAD_BY > 0 )); then
        gitstring+="$BranchBehindAndAheadBackgroundColor$BranchBehindAndAheadForegroundColor$branchstring"
        if [ "$BranchBehindAndAheadDisplay" = "full" ]; then
            gitstring+="$BranchBehindStatusSymbol$__POSH_BRANCH_BEHIND_BY$BranchAheadStatusSymbol$__POSH_BRANCH_AHEAD_BY"
        elif [ "$BranchBehindAndAheadDisplay" = "compact" ]; then
            gitstring+=" $__POSH_BRANCH_BEHIND_BY$BranchBehindAndAheadStatusSymbol$__POSH_BRANCH_AHEAD_BY"
        else
            gitstring+=" $BranchBehindAndAheadStatusSymbol"
        fi
    elif (( $__POSH_BRANCH_BEHIND_BY > 0 )); then
        gitstring+="$BranchBehindBackgroundColor$BranchBehindForegroundColor$branchstring"
        if [ "$BranchBehindAndAheadDisplay" = "full" -o "$BranchBehindAndAheadDisplay" = "compact" ]; then
            gitstring+="$BranchBehindStatusSymbol$__POSH_BRANCH_BEHIND_BY"
        else
            gitstring+="$BranchBehindStatusSymbol"
        fi
    elif (( $__POSH_BRANCH_AHEAD_BY > 0 )); then
        gitstring+="$BranchAheadBackgroundColor$BranchAheadForegroundColor$branchstring"
        if [ "$BranchBehindAndAheadDisplay" = "full" -o "$BranchBehindAndAheadDisplay" = "compact" ]; then
            gitstring+="$BranchAheadStatusSymbol$__POSH_BRANCH_AHEAD_BY"
        else
            gitstring+="$BranchAheadStatusSymbol"
        fi
    elif (( $divergence_return_code )); then
        # ahead and behind are both 0, but there was some problem while executing the command.
        gitstring+="$BranchBackgroundColor$BranchForegroundColor$branchstring$BranchWarningStatusSymbol"
    else
        # ahead and behind are both 0, and the divergence was determined successfully
        gitstring+="$BranchBackgroundColor$BranchForegroundColor$branchstring$BranchIdenticalStatusSymbol"
    fi

    gitstring+="${rebase:+$RebaseForegroundColor$RebaseBackgroundColor$rebase}"

    # index status
    if $EnableFileStatus; then
        local indexCount="$(( __POSH_INDEX_ADDED + __POSH_INDEX_MODIFIED + __POSH_INDEX_DELETED + __POSH_INDEX_UNMERGED ))"
        local workingCount="$(( __POSH_FILES_ADDED + __POSH_FILES_MODIFIED + __POSH_FILES_DELETED + __POSH_FILES_UNMERGED ))"

        if (( $indexCount != 0 )) || $ShowStatusWhenZero; then
            gitstring+="$IndexBackgroundColor$IndexForegroundColor +$__POSH_INDEX_ADDED ~$__POSH_INDEX_MODIFIED -$__POSH_INDEX_DELETED"
        fi
        if (( $__POSH_INDEX_UNMERGED != 0 )); then
            gitstring+=" $IndexBackgroundColor$IndexForegroundColor!$__POSH_INDEX_UNMERGED"
        fi
        if (( $indexCount != 0 && ($workingCount != 0 || $ShowStatusWhenZero) )); then
            gitstring+="$DelimBackgroundColor$DelimForegroundColor$DelimText"
        fi
        if (( $workingCount != 0 )) || $ShowStatusWhenZero; then
            gitstring+="$WorkingBackgroundColor$WorkingForegroundColor +$__POSH_FILES_ADDED ~$__POSH_FILES_MODIFIED -$__POSH_FILES_DELETED"
        fi
        if (( $__POSH_FILES_UNMERGED != 0 )); then
            gitstring+=" $WorkingBackgroundColor$WorkingForegroundColor!$__POSH_FILES_UNMERGED"
        fi

        local localStatusSymbol=$LocalDefaultStatusSymbol
        local localStatusColor=$DefaultForegroundColor

        if (( workingCount != 0 )); then
            localStatusSymbol=$LocalWorkingStatusSymbol
            localStatusColor=$LocalWorkingStatusColor
        elif (( indexCount != 0 )); then
            localStatusSymbol=$LocalStagedStatusSymbol
            localStatusColor=$LocalStagedStatusColor
        fi

        gitstring+="$DefaultBackgroundColor$localStatusColor$localStatusSymbol$DefaultForegroundColor"

        if $EnableStashStatus && $hasStash; then
            gitstring+="$DefaultBackgroundColor$DefaultForegroundColor $StashBackgroundColor$StashForegroundColor$BeforeStash$stashCount$AfterStash"
        fi
    fi

    # after-branch text
    gitstring+="$AfterBackgroundColor$AfterForegroundColor$AfterText$DefaultBackgroundColor$DefaultForegroundColor"
    echo "$gitstring"
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
    # get some config options from git-config
    local output="$(__posh_git config -z --get-regexp '^(svn-remote\..*\.url|bash\.showUpstream)$' 2>/dev/null | tr '\0\n' '\n ')"
    while read -r key value; do
        case "$key" in
        bash.showUpstream)
            GIT_PS1_SHOWUPSTREAM="$value"
            if [ -z "${GIT_PS1_SHOWUPSTREAM}" ]; then
                return
            fi
            ;;
        svn-remote.*.url)
            svn_remote[ $((${#svn_remote[@]} + 1)) ]="$value"
            svn_url_pattern+="\\|$value"
            upstream=svn+git # default upstream is SVN if available, else git
            ;;
        esac
    done <<< "$output"

    # parse configuration values
    for option in ${GIT_PS1_SHOWUPSTREAM}; do
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
        output=$(__posh_git rev-list --count --left-right $upstream...HEAD 2>/dev/null)
        return_code=$?
        IFS=$' \t\n' read -r __POSH_BRANCH_BEHIND_BY __POSH_BRANCH_AHEAD_BY <<< $output
    else
        local output
        output=$(__posh_git rev-list --left-right $upstream...HEAD 2>/dev/null)
        return_code=$?
        # produce equivalent output to --count for older versions of git
        while IFS=$' \t\n' read -r commit; do
            case "$commit" in
            "<*") (( __POSH_BRANCH_BEHIND_BY++ )) ;;
            ">*") (( __POSH_BRANCH_AHEAD_BY++ ))  ;;
            esac
        done <<< $output
    fi
    : ${__POSH_BRANCH_AHEAD_BY:=0}
    : ${__POSH_BRANCH_BEHIND_BY:=0}
    return $return_code
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

_posh_git_repo_key() {
    local g=$(__posh_gitdir)
    [ -z "$g" ] && return
    print -r -- "${g:A}"
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
    IFS= read -r -u $fd result_key
    IFS= read -r -u $fd next_result
    zle -F $fd
    exec {fd}<&-
    # Only clear the job pid when the completed fd matches the current one,
    # preventing a stale callback from zeroing out a newer job's pid.
    if (( fd == _posh_git_fd )); then
        _posh_git_job_pid=0
        _posh_git_job_key=""
    fi
    if [ "$result_key" = "$_posh_git_display_key" ] && [[ $next_result != $_posh_git_result || $result_key != $_posh_git_result_key ]]; then
        _posh_git_result=$next_result
        _posh_git_result_key=$result_key
        [[ -o zle ]] && zle reset-prompt
    fi
}

_posh_git_async_refresh() {
    local next_key=$(_posh_git_repo_key)
    _posh_git_display_key=$next_key

    if [ -z "$next_key" ]; then
        if (( _posh_git_job_pid )); then
            kill $_posh_git_job_pid 2>/dev/null
            zle -F $_posh_git_fd 2>/dev/null
            exec {_posh_git_fd}<&-
            _posh_git_job_pid=0
            _posh_git_job_key=""
        fi
        _posh_git_result=""
        _posh_git_result_key=""
        return
    fi

    if [ "$next_key" != "$_posh_git_result_key" ]; then
        _posh_git_result=""
    fi

    if (( _posh_git_job_pid )) && [ "$_posh_git_job_key" = "$next_key" ]; then
        return
    fi

    # Explicitly clean up the previous job before starting a new one.
    # The if-guard ensures _posh_git_fd is always valid when we touch it here.
    if (( _posh_git_job_pid )); then
        kill $_posh_git_job_pid 2>/dev/null
        zle -F $_posh_git_fd 2>/dev/null
        exec {_posh_git_fd}<&-
        _posh_git_job_pid=0
        _posh_git_job_key=""
    fi
    exec {_posh_git_fd}< <(print -r -- "$next_key"; __posh_git_echo_sync 2>/dev/null; echo)
    _posh_git_job_pid=$!
    _posh_git_job_key=$next_key
    zle -F $_posh_git_fd _posh_git_on_ready
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _posh_git_async_refresh

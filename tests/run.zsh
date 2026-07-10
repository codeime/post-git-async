#!/usr/bin/env zsh
# Minimal regression checks for posh-git-async hot-path changes.
emulate -L zsh
setopt extended_glob

ROOT=${0:A:h:h}
PLUGIN=$ROOT/posh-git-async.plugin.zsh
TMP=$(mktemp -d)
# Only ever kill PIDs this test spawned itself; never pattern-match processes.
typeset -a SPAWNED_PIDS=()
trap 'command rm -rf "$TMP"; (( ${#SPAWNED_PIDS} )) && kill -9 $SPAWNED_PIDS 2>/dev/null; true' EXIT

pass=0
fail=0

assert() {
    local name=$1
    shift
    if "$@"; then
        print -r -- "PASS $name"
        (( pass++ ))
    else
        print -r -- "FAIL $name"
        (( fail++ ))
    fi
}

assert_eq() {
    local name=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        print -r -- "PASS $name"
        (( pass++ ))
    else
        print -r -- "FAIL $name expected=[$expected] actual=[$actual]"
        (( fail++ ))
    fi
}

source "$PLUGIN"
add-zsh-hook -d precmd _posh_git_async_refresh 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1) Feature detection is cached in the current shell
# ---------------------------------------------------------------------------
_POSH_GIT_STATUS_FEATURES_DETECTED=
_POSH_GIT_FEATURE_GIT_PATH=
__posh_git_detect_status_features
assert "feature detection sets cache flag" [ "$_POSH_GIT_STATUS_FEATURES_DETECTED" = true ]
assert "feature detection records git path" [ -n "$_POSH_GIT_FEATURE_GIT_PATH" ]
_POSH_GIT_SUPPORTS_STATUS_V2=sentinel
__posh_git_detect_status_features
assert_eq "feature detection reuses parent cache" sentinel "$_POSH_GIT_SUPPORTS_STATUS_V2"

# ---------------------------------------------------------------------------
# 2) enableFileStatus=false skips stash query
# ---------------------------------------------------------------------------
repo=$TMP/repo-nostash
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t
print 'a' > "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -qm init
print 'b' > "$repo/a.txt"
git -C "$repo" stash push -qu -m tmp
git -C "$repo" config bash.enableFileStatus false

stash_calls=0
typeset -g stash_calls
(
    cd "$repo"
    __posh_git_load_config
    __posh_gitdir_value
    g=$REPLY
    stash_calls=0
    __posh_git_load_stash_state() { (( stash_calls++ )); }
    __posh_git_collect_prompt_state "$g"
    print -r -- "STASH_CALLS=$stash_calls"
    rendered=$(__posh_git_render_prompt)
    print -r -- "RENDERED=$rendered"
) > "$TMP/nostash.out"

source "$TMP/nostash.out" 2>/dev/null || true
nostash_calls=$(sed -n 's/^STASH_CALLS=//p' "$TMP/nostash.out")
nostash_render=$(sed -n 's/^RENDERED=//p' "$TMP/nostash.out")
assert_eq "file status off skips stash query" 0 "$nostash_calls"
if [[ $nostash_render != *'('* ]]; then
    print -r -- "PASS file status off prompt has no stash marker"
    (( pass++ ))
else
    print -r -- "FAIL file status off prompt has no stash marker render=[$nostash_render]"
    (( fail++ ))
fi

# ---------------------------------------------------------------------------
# 3) Passing gitdir works from a subdirectory
# ---------------------------------------------------------------------------
repo2=$TMP/repo-sub
mkdir -p "$repo2/sub/deep"
git -C "$repo2" init -q
git -C "$repo2" config user.email t@t
git -C "$repo2" config user.name t
print x > "$repo2/x.txt"
git -C "$repo2" add x.txt
git -C "$repo2" commit -qm init
abs_gitdir=$(git -C "$repo2" rev-parse --absolute-git-dir)

(
    cd "$repo2/sub/deep"
    __posh_git_load_config
    out=$(__posh_git_echo_sync_loaded_config "$abs_gitdir")
    if [ -n "$out" ]; then
        print OK
    else
        print EMPTY
    fi
) > "$TMP/sub.out"
assert_eq "echo with explicit gitdir works in subdirectory" OK "$(<"$TMP/sub.out")"

# ---------------------------------------------------------------------------
# 4) porcelain v2 parser counts untracked and handles rename records
# ---------------------------------------------------------------------------
repo3=$TMP/repo-parse
mkdir -p "$repo3"
git -C "$repo3" init -q
git -C "$repo3" config user.email t@t
git -C "$repo3" config user.name t
print old > "$repo3/old.txt"
git -C "$repo3" add old.txt
git -C "$repo3" commit -qm init
git -C "$repo3" mv old.txt new.txt
print u1 > "$repo3/u1.txt"
print u2 > "$repo3/u2.txt"

(
    cd "$repo3"
    __posh_git_load_config
    __posh_gitdir_value
    g=$REPLY
    __POSH_STATE_HAS_STASH=false
    __POSH_STATE_STASH_COUNT=0
    __POSH_STATE_DIVERGENCE_RETURN_CODE=1
    __POSH_BRANCH_AHEAD_BY=0
    __POSH_BRANCH_BEHIND_BY=0
    __posh_git_reset_counters
    __posh_git_collect_status_v2 "$g"
    print -r -- "INDEX_MOD=$__POSH_INDEX_MODIFIED"
    print -r -- "FILES_ADD=$__POSH_FILES_ADDED"
) > "$TMP/parse.out"

assert_eq "rename counts as index modified" 1 "$(sed -n 's/^INDEX_MOD=//p' "$TMP/parse.out")"
assert_eq "two untracked files counted" 2 "$(sed -n 's/^FILES_ADD=//p' "$TMP/parse.out")"

# ---------------------------------------------------------------------------
# 5) kill_tree terminates worker descendants
# ---------------------------------------------------------------------------
{
    sleep 30 &
    sleep 30 &
    wait
} &!
worker=$!
SPAWNED_PIDS+=($worker)
sleep 0.15
worker_kids=(${(f)"$(command pgrep -P $worker 2>/dev/null)"})
SPAWNED_PIDS+=($worker_kids)
_posh_git_kill_tree $worker TERM
sleep 0.25
if ps -p $worker >/dev/null 2>&1; then
    print -r -- "FAIL kill_tree leaves worker alive"
    (( fail++ ))
else
    print -r -- "PASS kill_tree terminates worker"
    (( pass++ ))
fi

child_left=0
for c in $worker_kids; do
    kill -0 $c 2>/dev/null && child_left=1
done
if (( child_left )); then
    print -r -- "FAIL kill_tree left children: $worker_kids"
    (( fail++ ))
else
    print -r -- "PASS kill_tree no worker children remain"
    (( pass++ ))
fi

# ---------------------------------------------------------------------------
# 5b) Non-work-tree fallback: bare repo and inside .git still render correctly
# ---------------------------------------------------------------------------
bare=$TMP/repo-bare.git
git init -q --bare "$bare"
(
    cd "$bare"
    __posh_git_load_config
    out=$(__posh_git_echo_sync)
    case $out in
        *BARE:*) print BARE_OK ;;
        *) print "BARE_BAD out=[$out]" ;;
    esac
) > "$TMP/bare.out"
assert "bare repo shows BARE prefix" grep -q BARE_OK "$TMP/bare.out"

(
    cd "$repo2/.git"
    __posh_git_load_config
    out=$(__posh_git_echo_sync)
    case $out in
        *'GIT_DIR!'*) print GITDIR_OK ;;
        *) print "GITDIR_BAD out=[$out]" ;;
    esac
) > "$TMP/gitdir.out"
assert "inside .git shows GIT_DIR!" grep -q GITDIR_OK "$TMP/gitdir.out"

# ---------------------------------------------------------------------------
# 5c) repo_key subdirectory cache: stable hit, invalidated when repo vanishes
# ---------------------------------------------------------------------------
repo_c=$TMP/repo-cache
mkdir -p "$repo_c/sub"
git -C "$repo_c" init -q
(
    cd "$repo_c/sub"
    _posh_git_repo_key; k1=$REPLY
    _posh_git_repo_key; k2=$REPLY
    [ -n "$k1" ] && [ "$k1" = "$k2" ] && print CACHE_OK || print "CACHE_BAD k1=[$k1] k2=[$k2]"
    rm -rf "$repo_c/.git"
    if _posh_git_repo_key; then
        print "INVALIDATE_BAD key=[$REPLY]"
    else
        print INVALIDATE_OK
    fi
) > "$TMP/cache.out"
assert "repo_key cache returns stable gitdir" grep -q CACHE_OK "$TMP/cache.out"
assert "repo_key cache invalidated when repo removed" grep -q INVALIDATE_OK "$TMP/cache.out"

# ---------------------------------------------------------------------------
# 6) Worker end-to-end: fifo protocol returns key + rendered prompt
# ---------------------------------------------------------------------------
repo4=$TMP/repo-e2e
mkdir -p "$repo4"
git -C "$repo4" init -q
git -C "$repo4" config user.email t@t
git -C "$repo4" config user.name t
print y > "$repo4/y.txt"
git -C "$repo4" add y.txt
git -C "$repo4" commit -qm init
print z > "$repo4/z.txt"

(
    cd "$repo4"
    _posh_git_repo_key
    key=$REPLY
    _posh_git_start_job "$key" "$key" 2>/dev/null
    IFS= read -r -u $_posh_git_fd got_key
    IFS= read -r -u $_posh_git_fd got_result
    exec {_posh_git_fd}<&-
    sync_result=$(__posh_git_echo_sync)
    [ "$got_key" = "$key" ] && print KEY_OK || print KEY_BAD
    [ "$got_result" = "$sync_result" ] && print RESULT_OK || print "RESULT_BAD got=[$got_result] want=[$sync_result]"
) > "$TMP/e2e.out"
assert "worker e2e returns matching key" grep -q KEY_OK "$TMP/e2e.out"
assert "worker e2e result matches sync path" grep -q RESULT_OK "$TMP/e2e.out"

# ---------------------------------------------------------------------------
# 7) Cancel leaves no orphan git processes
# ---------------------------------------------------------------------------
repo5=$TMP/repo-cancel
mkdir -p "$repo5"
git -C "$repo5" init -q
git -C "$repo5" config user.email t@t
git -C "$repo5" config user.name t
print c > "$repo5/c.txt"
git -C "$repo5" add c.txt
git -C "$repo5" commit -qm init
for i in {1..3000}; do : > "$repo5/f$i"; done

(
    cd "$repo5"
    _posh_git_repo_key
    key=$REPLY
    _posh_git_start_job "$key" "$key" 2>/dev/null
    wpid=$_posh_git_job_pid
    sleep 0.08
    # Snapshot this worker's own children before cancel, so the orphan check
    # is scoped to our processes instead of pattern-matching system-wide.
    wkids=(${(f)"$(command pgrep -P $wpid 2>/dev/null)"})
    _posh_git_cancel_job
    sleep 0.2
    if ps -p $wpid >/dev/null 2>&1; then
        print WORKER_ALIVE
    else
        print WORKER_DEAD
    fi
    orphan=0
    for c in $wkids; do
        kill -0 $c 2>/dev/null && orphan=1
    done
    if (( orphan )); then
        print "ORPHAN_GIT kids=$wkids"
        kill -9 $wkids 2>/dev/null
    else
        print NO_ORPHAN
    fi
) > "$TMP/cancel.out"
assert "cancel kills worker" grep -q WORKER_DEAD "$TMP/cancel.out"
assert "cancel leaves no orphan git" grep -q NO_ORPHAN "$TMP/cancel.out"

# ---------------------------------------------------------------------------
# 8) POSH_GIT_ASYNC_PROMPT mirrors echo cache rules
# ---------------------------------------------------------------------------
_posh_git_display_key=abc
_posh_git_result_key=abc
_posh_git_result='[main]'
_posh_git_sync_prompt_var
assert_eq "prompt var set when keys match" '[main]' "$POSH_GIT_ASYNC_PROMPT"
_posh_git_display_key=other
_posh_git_sync_prompt_var
assert_eq "prompt var cleared when keys differ" '' "$POSH_GIT_ASYNC_PROMPT"

print -r -- "----"
print -r -- "passed=$pass failed=$fail"
(( fail == 0 ))

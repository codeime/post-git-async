[English](README.md) | [简体中文](README.zh-CN.md)

# posh-git-async

## Overview

posh-git-async is an oh-my-zsh plugin for developers who use zsh in large Git repositories.

It turns the Git status prompt from [posh-git-sh](https://github.com/lyze/posh-git-sh) into an **asynchronous, non-blocking** workflow: every time you press Enter, the prompt returns immediately, while Git status information is refreshed quietly in the background. This eliminates the prompt lag caused by slow `git status` calls in large repositories.

If you have ever worked in a large monorepo or a long-lived project where pressing Enter freezes the terminal for 1 to 3 seconds before the next prompt appears, this plugin is built for that case.

In short, it converts the git prompt logic from [posh-git-sh](https://github.com/lyze/posh-git-sh) into an asynchronous version to solve prompt lag in large repositories.

The current version also includes several hot-path optimizations:

- Prefer a single `git status --porcelain=v2 --branch -z` call to collect branch, ahead/behind, stash, and file status
- Use `GIT_OPTIONAL_LOCKS=0` for all prompt-related Git calls
- Reuse the in-flight async task for the same repository inside the current shell instead of restarting background work on rapid consecutive Enter presses
- Apply a short debounce window to repeated refreshes in the same repository, and schedule at most one extra background refresh when needed
- Clean up and restart a timed-out background worker on the next refresh so a stuck worker does not occupy the slot forever
- Avoid redundant `symbolic-ref`, `rev-parse`, and `config` calls on common repository paths whenever possible

## How It Works

The original `__posh_git_echo` renders the prompt by synchronously running multiple Git commands such as `git status` and `git rev-list`, which is noticeably expensive in large repositories.

This plugin changes that behavior to:

1. Render the prompt immediately and display the last cached Git state
2. Reuse the same background query when the current repository already has an unfinished async task instead of starting another one
3. Cancel the old background query when you switch to another repository
4. Refresh the prompt only when the new result is actually different
5. Debounce rapid consecutive refreshes in the same repository to avoid repeatedly starting workers
6. If another refresh arrives while a worker is still running for the same repository, schedule at most one follow-up run instead of repeatedly killing and restarting
7. Reap and restart a worker on the next refresh if it gets stuck for too long

To reduce hot-path cost, the current implementation also:

- Prefers `git status --porcelain=v2 --branch -z`
- Skips file scanning and uses a lighter branch-status path when `bash.enableFileStatus=false`
- Uses a faster stash-count path first and falls back to a compatibility path only if needed
- Automatically falls back to a compatibility path on older Git versions
- Clears the display when you leave a Git repository so status from the previous repository does not linger

### Code Structure

The synchronous main path is currently split into three layers:

- Config loading: reads `bash.*` configuration values and normalizes defaults
- State collection: detects repository context and gathers branch / ahead-behind / stash / file status
- Prompt rendering: only assembles the collected state into the final colored string

The goal is to make future maintenance safer: changes to collection logic do not need to touch rendering details, and display changes are less likely to break the Git query path.

## Installation

**1. Download the plugin into your oh-my-zsh custom plugin directory**

```bash
# Option 1: if the project is published on GitHub
git clone thisRepoUrl ~/.oh-my-zsh/custom/plugins/posh-git-async

# Option 2: local install (development or testing)
ln -s /path/to/posh-git-async ~/.oh-my-zsh/custom/plugins/posh-git-async

# Option 3: copy files directly (without a symlink)
mkdir -p ~/.oh-my-zsh/custom/plugins/posh-git-async
cp /path/to/posh-git-async/posh-git-async.plugin.zsh ~/.oh-my-zsh/custom/plugins/posh-git-async/
cp /path/to/posh-git-async/README.md ~/.oh-my-zsh/custom/plugins/posh-git-async/
cp /path/to/posh-git-async/LICENSE ~/.oh-my-zsh/custom/plugins/posh-git-async/
```

**2. Update `~/.zshrc`**

If you are migrating from [posh-git-sh](https://github.com/lyze/posh-git-sh) or from a previous local synchronous script, remove the old `source ~/git-prompt.sh` and add the plugin to your plugins list:

```zsh
plugins=(
    posh-git-async
    zsh-autosuggestions
    zsh-syntax-highlighting
)
```

If you also manually enabled VS Code shell integration in `~/.zshrc` with a line like this:

```zsh
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"
```

that line starts the `code` command every time a VS Code terminal launches, which adds visible shell startup overhead. A lighter approach is to run this once:

```bash
code --locate-shell-integration-path zsh
```

Then copy the resolved script path and source it directly from `~/.zshrc`, for example:

```zsh
[[ "$TERM_PROGRAM" == "vscode" ]] && . "/Applications/Visual Studio Code.app/Contents/Resources/app/out/vs/workbench/contrib/terminal/common/scripts/shellIntegration-rc.zsh"
```

This note is not a hard dependency of the plugin itself, but it is worth addressing first when you are diagnosing slow zsh startup inside VS Code so you can measure the real prompt and Git-query cost more accurately.

**3. Update the git prompt placeholder in your theme**

Find your theme file, usually under `~/.oh-my-zsh/themes/` or `~/.oh-my-zsh/custom/themes/`, and change the `git_info` assignment to call this plugin:

```zsh
# Before
local git_info='$(git_prompt_info)'

# After
local git_info='$(__posh_git_echo)'
```

**4. oh-my-zsh's built-in git prompt is disabled by default**

To avoid duplicate Git queries, the plugin overrides `git_prompt_info`, `git_prompt_status`, and `git_prompt_ahead` with empty implementations after loading.

That means:

- If your theme already uses `$(__posh_git_echo)`, you do not need to manually disable oh-my-zsh's built-in git prompt
- If your theme still uses `$(git_prompt_info)`, the git section will become empty, so update the theme first as described above

If you really want to keep oh-my-zsh's native git prompt, set this before `source $ZSH/oh-my-zsh.sh`:

```zsh
POSH_GIT_ASYNC_DISABLE_OMZ_GIT_PROMPT=false
```

You can also continue setting the following variable before `source $ZSH/oh-my-zsh.sh` to reduce oh-my-zsh's native dirty-check cost. Note that this does not fully disable the built-in git prompt:

```zsh
DISABLE_UNTRACKED_FILES_DIRTY="true"
```

## Optional Environment Variables

Set these variables before `source $ZSH/oh-my-zsh.sh`:

```zsh
# Keep oh-my-zsh's native git prompt instead of letting the plugin disable it by default
POSH_GIT_ASYNC_DISABLE_OMZ_GIT_PROMPT=false

# Debounce window for consecutive refreshes in the same repository, default: 0.25 seconds
POSH_GIT_ASYNC_DEBOUNCE_SECONDS=0.25

# Timeout for the background worker, default: 5 seconds
POSH_GIT_ASYNC_TIMEOUT_SECONDS=5
```

Notes:

- A larger `POSH_GIT_ASYNC_DEBOUNCE_SECONDS` value reduces background Git queries during rapid Enter presses, but prompt status may update a little later
- `POSH_GIT_ASYNC_TIMEOUT_SECONDS` is mainly a stability guard and usually does not need to be changed

**5. Reload your shell configuration**

```bash
source ~/.zshrc
```

## Requirements

- zsh 4.3.11 or newer, with `zle -F` support
- oh-my-zsh
- git

Notes:

- Newer Git versions will prefer the porcelain v2 path and perform better
- Older Git versions automatically fall back to a compatibility path, but state collection may be heavier

## Uninstall

**1. Remove `posh-git-async` from the plugins list in `~/.zshrc`**

```zsh
plugins=(
    # posh-git-async  # comment out or delete this line
    zsh-autosuggestions
    zsh-syntax-highlighting
)
```

**2. Restore the original git prompt in your theme**

```zsh
# Change it back
local git_info='$(git_prompt_info)'
```

**3. Reload your shell configuration**

```bash
source ~/.zshrc
```

**4. Optional: delete the plugin files**

```bash
rm -rf ~/.oh-my-zsh/custom/plugins/posh-git-async
```

## Troubleshooting

### Git information never appears

**Possible causes:**

- Your theme file was not updated to call `$(__posh_git_echo)`
- Your theme is still using `$(git_prompt_info)`, while the plugin already disabled oh-my-zsh's built-in git prompt by default
- You are not inside a Git repository

**How to fix it:**

1. Check that your theme correctly uses `$(__posh_git_echo)`
2. If you really want to keep `$(git_prompt_info)`, set `POSH_GIT_ASYNC_DISABLE_OMZ_GIT_PROMPT=false` before `source $ZSH/oh-my-zsh.sh`
3. Test inside a Git repository: `cd /path/to/git/repo`
4. Run a manual check in the terminal: `__posh_git_echo_sync`, and see whether it prints anything

### The prompt shows errors or garbled output

**Possible causes:**

- A Git command failed
- Your terminal does not support the color sequences being used

**How to fix it:**

1. Verify Git itself works: `git status`
2. Temporarily disable the plugin by removing it from the plugins list, then run `source ~/.zshrc`

### Why is the prompt faster when file status is disabled

**Explanation:** when you set `git config bash.enableFileStatus false`, the plugin skips `git status` file scanning. It no longer counts staged and unstaged file changes, and keeps only lighter status information such as branch, ahead/behind, and stash.

### Why does the prompt sometimes show the wrong Git status after changing directories

**Explanation:** the current implementation prevents background results from an old repository from overwriting the prompt of a new one. After switching to another repository, the Git section may be empty briefly until the async refresh finishes.

### Why don't multiple terminals share the same state

**Explanation:** the plugin stores prompt state and in-flight async tasks only inside the current shell process. It does not share state across multiple terminals.

**Impact:**

- Advantage: the design stays simple, avoids temp files, and does not introduce cross-terminal cache consistency issues
- Limitation: if you open many terminals in the same large repository, each terminal still runs its own background Git queries

## Notes

- Git information is empty when the terminal first opens, and appears after the first async refresh completes
- After switching to another repository, the Git section may be empty briefly until the async refresh updates it
- Prompt state and async tasks exist only in the current shell process and are not shared across terminals
- If you install by copying files instead of using a symlink, later changes in this repository will not be synced automatically into `~/.oh-my-zsh/custom/plugins/posh-git-async/`

## License

This project is based on [posh-git-sh](https://github.com/lyze/posh-git-sh) (Copyright © 2022 David Xu), with modifications released under the [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html).

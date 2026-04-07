# posh-git-async

## 项目简介

posh-git-async 是一个 oh-my-zsh 插件，专为在大型 Git 仓库中使用 zsh 的开发者设计。

它将 [posh-git-sh](https://github.com/lyze/posh-git-sh) 提供的 Git 状态 prompt（分支名、文件变更数、ahead/behind 等信息）改造为**异步非阻塞**模式：每次按下回车后，终端 prompt 立即响应，Git 状态信息在后台静默更新，彻底消除大型仓库中因 `git status` 耗时导致的 prompt 卡顿感。

如果你曾在大型 monorepo 或历史悠久的项目中遇到"按回车后终端卡住 1~3 秒才出现新 prompt"的问题，这个插件就是为此而生的。

将 [posh-git-sh](https://github.com/lyze/posh-git-sh) 的 git prompt 改造为异步非阻塞版本，解决在大型仓库中按回车后 prompt 卡顿的问题。

当前版本还额外做了几项热路径优化：

- 优先使用一次 `git status --porcelain=v2 --branch -z` 获取分支、ahead/behind、stash 和文件状态
- 所有 prompt 相关 Git 调用统一使用 `GIT_OPTIONAL_LOCKS=0`
- 当前 shell 内会复用同一仓库的 in-flight 异步任务，避免连续回车时重复重启后台查询
- 同一仓库的连续刷新会做短暂 debounce，并在需要时只补一次后台刷新
- 后台任务超时后会在下一次刷新时自动回收并重启，避免单个卡住的 worker 长时间占位
- 常规仓库路径会尽量避免重复的 `symbolic-ref` / `rev-parse` / `config` 调用

## 原理

原版 `__posh_git_echo` 每次渲染 prompt 时同步执行多个 git 命令（`git status`、`git rev-list` 等），在大型仓库中耗时明显。

本插件将其改为：

1. prompt 立即渲染，显示上一次缓存的 git 状态
2. 同一仓库有未完成的后台查询时，后续 `precmd` 会直接复用，不重复启动
3. 切换到其他仓库时，旧仓库的后台查询会被取消
4. 查询完成后只在结果真的变化时刷新 prompt
5. 同一仓库短时间内的连续刷新会被 debounce，避免频繁重复启动 worker
6. 如果 worker 执行期间又收到了同仓库刷新请求，只会补跑一次，不会反复 kill/restart
7. 如果某个 worker 长时间卡住，下次刷新会按超时策略回收并重启

为了降低热路径开销，当前实现会：

- 优先走 `git status --porcelain=v2 --branch -z`
- 当 `bash.enableFileStatus=false` 时，跳过 `git status` 文件扫描，改走更轻的分支状态路径
- stash 状态会优先走一次更快的计数路径，失败时再自动回退到兼容逻辑
- 在旧版 Git 上自动回退到兼容路径
- 离开 Git 仓库时清空显示，避免残留上一个仓库的状态

### 代码结构

当前同步主路径已经按职责拆成 3 层：

- 配置加载：读取 `bash.*` 配置项并归一化默认值
- 状态采集：判断仓库上下文、采集 branch / ahead-behind / stash / 文件状态
- prompt 渲染：只负责把采集结果拼成最终的颜色字符串

这样做的目标是让后续维护更安全：改采集逻辑时，不需要同时碰渲染细节；改显示格式时，也不容易误伤 Git 查询路径。

## 安装

**1. 下载插件到 oh-my-zsh 自定义插件目录**

```bash
# 方式一：如果项目已发布到 GitHub
git clone thisRepoUrl ~/.oh-my-zsh/custom/plugins/posh-git-async

# 方式二：本地安装（开发或测试）
ln -s /path/to/posh-git-async ~/.oh-my-zsh/custom/plugins/posh-git-async

# 方式三：直接复制文件（不使用软链）
mkdir -p ~/.oh-my-zsh/custom/plugins/posh-git-async
cp /path/to/posh-git-async/posh-git-async.plugin.zsh ~/.oh-my-zsh/custom/plugins/posh-git-async/
cp /path/to/posh-git-async/README.md ~/.oh-my-zsh/custom/plugins/posh-git-async/
cp /path/to/posh-git-async/LICENSE ~/.oh-my-zsh/custom/plugins/posh-git-async/
```

**2. 修改 `~/.zshrc`**

如果从 [posh-git-sh](https://github.com/lyze/posh-git-sh) 或你之前的本地同步脚本迁移，移除原有的 `source ~/git-prompt.sh`，在 plugins 列表中添加插件：

```zsh
plugins=(
    posh-git-async
    zsh-autosuggestions
    zsh-syntax-highlighting
)
```

如果你还在 `~/.zshrc` 里为 VS Code 终端手动启用了 shell integration，并且写的是下面这种形式：

```zsh
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"
```

它会在每次启动 VS Code 终端时额外启动一次 `code` 命令，带来可见的 shell startup 开销。更轻的写法是先运行一次：

```bash
code --locate-shell-integration-path zsh
```

拿到固定脚本路径后，直接在 `~/.zshrc` 中 `source` 这个路径，例如：

```zsh
[[ "$TERM_PROGRAM" == "vscode" ]] && . "/Applications/Visual Studio Code.app/Contents/Resources/app/out/vs/workbench/contrib/terminal/common/scripts/shellIntegration-rc.zsh"
```

这条提示和本插件本身无强依赖，但如果你在 VS Code 里排查 zsh 启动慢，值得先处理掉这类额外开销，再评估 prompt/Git 查询的真实成本。

**3. 修改主题中的 git prompt 占位符**

找到你的主题文件（通常在 `~/.oh-my-zsh/themes/` 或 `~/.oh-my-zsh/custom/themes/` 目录下），将 git_info 的赋值改为调用本插件：

```zsh
# 改前
local git_info='$(git_prompt_info)'

# 改后
local git_info='$(__posh_git_echo)'
```

**4. oh-my-zsh 内置 git prompt 会默认被插件禁用**

为了避免重复 Git 查询，插件加载后会默认把 `git_prompt_info`、`git_prompt_status` 和 `git_prompt_ahead` 覆盖为空实现。

这意味着：

- 如果你的主题已经改成使用 `$(__posh_git_echo)`，就不需要再手动禁用 oh-my-zsh 内置 git prompt
- 如果你的主题还在使用 `$(git_prompt_info)`，git 区域会变空，所以请先按上一步改主题

如果你确实想保留 oh-my-zsh 原生 git prompt，可以在 `source $ZSH/oh-my-zsh.sh` 之前设置：

```zsh
POSH_GIT_ASYNC_DISABLE_OMZ_GIT_PROMPT=false
```

另外，你也可以继续在 `source $ZSH/oh-my-zsh.sh` 之前设置下面这个变量，减少 oh-my-zsh 原生 dirty 检查（注意：这不会完全禁用内置 git prompt）：

```zsh
DISABLE_UNTRACKED_FILES_DIRTY="true"
```

## 可选环境变量

下面这些变量都建议在 `source $ZSH/oh-my-zsh.sh` 之前设置：

```zsh
# 保留 oh-my-zsh 原生 git prompt，不让插件默认禁用它
POSH_GIT_ASYNC_DISABLE_OMZ_GIT_PROMPT=false

# 同一仓库连续刷新时的 debounce 窗口，默认 0.25 秒
POSH_GIT_ASYNC_DEBOUNCE_SECONDS=0.25

# 后台 worker 的超时秒数，默认 5 秒
POSH_GIT_ASYNC_TIMEOUT_SECONDS=5
```

说明：

- `POSH_GIT_ASYNC_DEBOUNCE_SECONDS` 越大，连续快速回车时越省后台 Git 查询，但状态更新可能会略晚一点
- `POSH_GIT_ASYNC_TIMEOUT_SECONDS` 主要是稳定性保护，正常情况下不需要改

**5. 重载配置**

```bash
source ~/.zshrc
```

## 系统要求

- zsh 4.3.11 或更高版本（需要 `zle -F` 支持）
- oh-my-zsh
- git

备注：

- 较新的 Git 版本会优先使用 `porcelain v2` 路径，性能更好
- 较旧的 Git 版本会自动回退到兼容逻辑，但状态采集可能稍重

## 卸载

**1. 从 `~/.zshrc` 的 plugins 列表中移除 `posh-git-async`**

```zsh
plugins=(
    # posh-git-async  # 注释或删除这行
    zsh-autosuggestions
    zsh-syntax-highlighting
)
```

**2. 恢复主题文件中的原始 git prompt**

```zsh
# 改回
local git_info='$(git_prompt_info)'
```

**3. 重载配置**

```bash
source ~/.zshrc
```

**4. （可选）删除插件文件**

```bash
rm -rf ~/.oh-my-zsh/custom/plugins/posh-git-async
```

## 故障排查

### git 信息一直不显示

**可能原因**：

- 主题文件未正确修改为调用 `$(__posh_git_echo)`
- 主题仍在使用 `$(git_prompt_info)`，而插件已经默认禁用了 oh-my-zsh 内置 git prompt
- 不在 git 仓库目录中

**解决方法**：

1. 检查主题文件是否正确使用 `$(__posh_git_echo)`
2. 如果你确实要保留 `$(git_prompt_info)`，请在 `source $ZSH/oh-my-zsh.sh` 之前设置 `POSH_GIT_ASYNC_DISABLE_OMZ_GIT_PROMPT=false`
3. 在 git 仓库目录中测试：`cd /path/to/git/repo`
4. 手动测试：在终端执行 `__posh_git_echo_sync`，查看是否有输出

### prompt 显示错误信息或乱码

**可能原因**：

- git 命令执行失败
- 终端不支持颜色代码

**解决方法**：

1. 检查 git 是否正常工作：`git status`
2. 临时禁用插件测试：从 plugins 列表中移除后 `source ~/.zshrc`

### 关闭文件状态后为什么 prompt 会更快

**说明**：当你设置 `git config bash.enableFileStatus false` 时，插件当前会跳过 `git status` 文件扫描，不再统计 staged / unstaged 文件数量，只保留分支、ahead/behind、stash 等较轻的状态信息。

### 切换目录后显示错误的 git 状态

**说明**：当前实现会避免把旧仓库的后台结果覆盖到新仓库 prompt 上。切换到另一个仓库后，如果 git 区域短暂为空，等异步查询完成后就会显示新仓库状态。

### 多个终端同时打开时为什么不会共享状态

**说明**：插件只在当前 shell 进程内维护当前 prompt 结果和 in-flight 异步任务，不会在多个终端之间共享状态。

**影响**：

- 优点：实现简单，不写临时文件，也不会引入跨终端缓存一致性问题
- 限制：如果你同时打开很多终端并进入同一个大型仓库，每个终端仍会各自执行后台 Git 查询

## 注意

- 首次打开终端时 git 信息为空，第一次异步完成后才显示
- 切换到另一个仓库后，git 区域可能会短暂为空，异步刷新后更新
- 当前 prompt 结果和异步任务只存在于当前 shell 内存中，不会跨终端共享
- 如果你使用“复制文件”安装方式，仓库里的后续修改不会自动同步到 `~/.oh-my-zsh/custom/plugins/posh-git-async/`

## 许可证

本项目基于 [posh-git-sh](https://github.com/lyze/posh-git-sh)（Copyright © 2022 David Xu）修改，依据 [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html) 发布。

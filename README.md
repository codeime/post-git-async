# posh-git-async

## 项目简介

posh-git-async 是一个 oh-my-zsh 插件，专为在大型 Git 仓库中使用 zsh 的开发者设计。

它将 [posh-git-sh](https://github.com/lyze/posh-git-sh) 提供的 Git 状态 prompt（分支名、文件变更数、ahead/behind 等信息）改造为**异步非阻塞**模式：每次按下回车后，终端 prompt 立即响应，Git 状态信息在后台静默更新，彻底消除大型仓库中因 `git status` 耗时导致的 prompt 卡顿感。

如果你曾在大型 monorepo 或历史悠久的项目中遇到"按回车后终端卡住 1~3 秒才出现新 prompt"的问题，这个插件就是为此而生的。

将 [posh-git-sh](https://github.com/lyze/posh-git-sh) 的 git prompt 改造为异步非阻塞版本，解决在大型仓库中按回车后 prompt 卡顿的问题。

当前版本还额外做了几项热路径优化：

- 优先使用一次 `git status --porcelain=v2 --branch -z` 获取分支、ahead/behind、stash 和文件状态
- 所有 prompt 相关 Git 调用统一使用 `GIT_OPTIONAL_LOCKS=0`
- 在当前 shell 内按仓库跟踪异步任务，避免同一仓库连续回车时重复重启后台查询

## 原理

原版 `__posh_git_echo` 每次渲染 prompt 时同步执行多个 git 命令（`git status`、`git rev-list` 等），在大型仓库中耗时明显。

本插件将其改为：

1. prompt 立即渲染，显示上一次缓存的 git 状态
2. 同一仓库有未完成的后台查询时，后续 `precmd` 会直接复用，不重复启动
3. 切换到其他仓库时，旧仓库的后台查询会被取消
4. 查询完成后只在结果真的变化时刷新 prompt

为了降低热路径开销，当前实现会：

- 优先走 `git status --porcelain=v2 --branch -z`
- 在旧版 Git 上自动回退到兼容路径
- 离开 Git 仓库时清空显示，避免残留上一个仓库的状态

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

如果从 [posh-git-sh](https://github.com/lyze/posh-git-sh) 迁移，移除原有的 `source ~/git-prompt.sh`，在 plugins 列表中添加插件：

```zsh
plugins=(
    posh-git-async
    zsh-autosuggestions
    zsh-syntax-highlighting
)
```

**3. 修改主题中的 git prompt 占位符**

找到你的主题文件（通常在 `~/.oh-my-zsh/themes/` 或 `~/.oh-my-zsh/custom/themes/` 目录下），将 git_info 的赋值改为调用本插件：

```zsh
# 改前
local git_info='$(git_prompt_info)'

# 改后
local git_info='$(__posh_git_echo)'
```

**4. （可选）禁用 oh-my-zsh 内置 git prompt**

oh-my-zsh 自带的 git prompt 函数（`git_prompt_info` 等）与本插件功能重复，建议禁用。

**推荐方法**：在 `~/.zshrc` 的 `source $ZSH/oh-my-zsh.sh` 之后手动覆盖函数：

```zsh
source $ZSH/oh-my-zsh.sh

# 禁用 oh-my-zsh 内置 git prompt，避免重复查询
git_prompt_info()   { echo "" }
git_prompt_status() { echo "" }
git_prompt_ahead()  { echo "" }
```

**备选方法**：在 `~/.zshrc` 的 `source $ZSH/oh-my-zsh.sh` 之前添加（注意：这只会减少 untracked 文件检查，不会完全禁用内置 git prompt）：

```zsh
DISABLE_UNTRACKED_FILES_DIRTY="true"
```

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
- 不在 git 仓库目录中

**解决方法**：

1. 检查主题文件是否正确使用 `$(__posh_git_echo)`
2. 在 git 仓库目录中测试：`cd /path/to/git/repo`
3. 手动测试：在终端执行 `__posh_git_echo_sync`，查看是否有输出

### prompt 显示错误信息或乱码

**可能原因**：

- git 命令执行失败
- 终端不支持颜色代码

**解决方法**：

1. 检查 git 是否正常工作：`git status`
2. 临时禁用插件测试：从 plugins 列表中移除后 `source ~/.zshrc`

### 切换目录后显示错误的 git 状态

**说明**：短暂显示旧状态是异步 prompt 的正常现象，但当前实现已经避免了把旧仓库的后台结果覆盖到新仓库 prompt 上。通常下一次异步完成后会更新为正确状态。

### 多个终端同时打开时为什么不会共享状态

**说明**：插件只在当前 shell 进程内缓存和复用异步结果，不会在多个终端之间共享状态。

**影响**：

- 优点：实现简单，不写临时文件，也不会引入跨终端缓存一致性问题
- 限制：如果你同时打开很多终端并进入同一个大型仓库，每个终端仍会各自执行后台 Git 查询

## 注意

- 首次打开终端时 git 信息为空，第一次异步完成后才显示
- 切换目录后 prompt 会短暂显示上一个目录的 git 状态，异步刷新后更新
- 缓存和异步任务只存在于当前 shell 内存中，不会跨终端共享
- 如果你使用“复制文件”安装方式，仓库里的后续修改不会自动同步到 `~/.oh-my-zsh/custom/plugins/posh-git-async/`

## 许可证

本项目基于 [posh-git-sh](https://github.com/lyze/posh-git-sh)（Copyright © 2022 David Xu）修改，依据 [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html) 发布。

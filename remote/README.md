# remote 工具集

`sync-remote` 负责在本地与远端之间同步文件，`run-remote` 负责在同一个远端镜像目录执行命令。两者共享 Bash 格式的配置和“异树同枝”路径映射：当前目录相对本地 `$HOME` 的路径，会拼接到远端 `$DEFAULT_REMOTE_BASE` 下。

例如，本地 `~/Projects/demo` 在 `DEFAULT_REMOTE_BASE="~"` 时映射到远端 `~/Projects/demo`；配置为 `DEFAULT_REMOTE_BASE="~/work"` 时则映射到远端 `~/work/Projects/demo`。

## 安装

在仓库根目录运行：

```bash
./setup.sh
```

从旧版 `sync/` 目录结构升级时，需要重新运行 `./setup.sh`，刷新原有的 `~/bin/sync-remote` 符号链接。

旧配置中的 `DEFAULT_SSH_IDENTITY_FILE` 已不再支持；如需指定密钥，请在 `~/.ssh/config` 的对应 Host 下配置 `IdentityFile`。

也可以手动创建符号链接：

```bash
mkdir -p ~/bin
ln -sf "$(pwd)/remote/sync_remote.sh" ~/bin/sync-remote
ln -sf "$(pwd)/remote/run_remote.sh" ~/bin/run-remote
```

确保 `~/bin` 已加入 `PATH`。`sync-remote` 需要 `rsync` 和 `ssh`；`run-remote` 需要 `ssh`，其 `precheck` 命令还会使用本地 `git`。

## 共享配置

配置仍使用原有 Bash source 格式；新增角色专用 host 字段，其余协议不变。加载顺序从低到高为：

1. 用户配置：优先 `~/.config/remote/config`，不存在时兼容 `~/.config/sync_to_remote/config`
2. 项目配置：优先 `./.remote_config`，不存在时兼容 `./.sync_config`
3. 命令行参数覆盖相应默认值

快速配置：

```bash
mkdir -p ~/.config/remote
cp remote/config.sample ~/.config/remote/config
cp remote/remote_config.sample .remote_config
```

项目配置与用户配置使用相同字段。`run-remote` 只读取连接和路径字段，会忽略同步模式及过滤规则。

| 字段 | 默认值 | 用途 |
| --- | --- | --- |
| `DEFAULT_REMOTE_HOST` | 空，建议配置 | 两个工具共享的 fallback SSH host、alias 或 `user@host` |
| `DEFAULT_RUN_HOST` | `DEFAULT_REMOTE_HOST` | `run-remote` 使用的登录/计算节点 |
| `DEFAULT_SYNC_HOST` | `DEFAULT_REMOTE_HOST` | `sync-remote` 使用的数据传输节点 |
| `DEFAULT_REMOTE_BASE` | `~` | 远端目录树的映射根 |
| `DEFAULT_REMOTE_PORT` | `22` | SSH 端口 |
| `DEFAULT_MODE` | `pull` | `sync-remote` 默认模式 |
| `INCLUDE_ONLY` | 空 | `sync-remote` 仅同步匹配项 |
| `EXCLUDE_TYPES` | 空 | `sync-remote` 启用的预定义排除规则组 |
| `EXCLUDE_CUSTOM` | 空 | `sync-remote` 自定义排除规则 |
| `EXCLUDES_FORTRAN`、`EXCLUDES_PYTHON`、`EXCLUDES_CPP`、`EXCLUDES_COMMON` | 由用户定义 | `sync-remote` 可复用的排除规则组 |

推荐使用 SSH alias，将连接细节统一放在 `~/.ssh/config` 中：

```bash
DEFAULT_REMOTE_HOST="mycluster"
DEFAULT_REMOTE_BASE="~"
DEFAULT_MODE="pull"
```

登录节点与数据传输节点分离但共享文件系统时，可以分别配置：

```bash
DEFAULT_RUN_HOST="siyuan"
DEFAULT_SYNC_HOST="sydata"
DEFAULT_REMOTE_HOST="siyuan"  # 任一角色未单独配置时的 fallback
DEFAULT_REMOTE_BASE="~"       # 两个节点共享同一个路径映射
```

`run-remote` 优先使用 `DEFAULT_RUN_HOST`，`sync-remote` 优先使用 `DEFAULT_SYNC_HOST`，未设置角色专用 host 时都回退到 `DEFAULT_REMOTE_HOST`。命令行 `-H` 始终具有最高优先级。

## sync-remote

`sync-remote` 是本地与远端镜像目录之间的同步封装。它支持基于 rsync 的 push/pull/copy-*、冲突感知的 handoff/reclaim，以及只传 git commits 的 git-push/git-pull/git-sync。

```bash
sync-remote                         # 使用 DEFAULT_MODE
sync-remote -m push                 # 本地覆盖远端
sync-remote -m pull                 # 远端覆盖本地
sync-remote -m copy-push -n         # 预览保留远端文件的推送
sync-remote -m handoff              # 接力工作现场
sync-remote -m reclaim              # 从远端归队
sync-remote -m git-push             # 本地超前 commits ff 推到远端工作树
sync-remote -m git-pull             # 远端超前 commits ff 拉到本地
sync-remote -m git-sync             # 谁超前就单向 ff；diverged 拒绝
sync-remote -H mycluster -m pull    # 临时覆盖 host
sync-remote -h
```

rsync 类模式的过滤规则继续沿用 `config.sample` 和 `remote_config.sample` 中的数组配置。`INCLUDE_ONLY` 优先级最高；未设置时合并 `EXCLUDE_TYPES` 与 `EXCLUDE_CUSTOM`。git-* 模式不使用这些过滤规则。

### 模式怎么选

| 场景 | 模式 |
| --- | --- |
| 源码已 commit，推到集群编译/跑 | `git-push` 或 `git-sync` |
| 集群上有新 commits，拉回本地 | `git-pull` 或 `git-sync` |
| job 输入等被 gitignore 的文件 | `copy-push` |
| 脏工作区整包换机器接着改 | `handoff` / `reclaim` |

### git-push / git-pull / git-sync

- **通道**：经已有 SSH 直连远端仓库（`host:绝对或可展开路径`），**不经 GitHub**，无需远端代理或 PAT。
- **只传 commits**：不传 untracked / 未提交改动；两端仅有 untracked（如 `dqmc.out`）不阻止同步。
- **默认 ff-only**：历史分叉、分支名不一致、不在仓库根目录 → 拒绝。工作区 dirty 对齐原生 git：本地 dirty 不拦 push/pull（pull 时与入站重叠则由 `merge` 失败）；远端 dirty 只拦 push（`updateInstead` 会改远端工作树），不拦 pull。HEAD 相同即报「已同步」，不因 dirty 误失败。
- **`-f` / `--force`（仅 git-push / git-sync）**：远端超前或分叉时用 `git push --force-with-lease`，**以本地为权威**覆盖远端分支与工作树，**丢弃远端独有 commits**（不是 rebase）。lease 锚定探测到的远端 tip，降低误盖他人新推送的风险。`git-pull` 忽略 `-f`。
- **工作树**：push 前将远端设为 `receive.denyCurrentBranch=updateInstead`，使非 bare 当前分支在更新后同步文件。
- **remote 名**：本地使用名为 `sync-remote` 的 git remote（不存在则创建，存在则更新 URL），不改动 `origin`。
- **路径**：仍走「异树同枝」；须在**仓库根目录**执行；`DEFAULT_REMOTE_BASE` 可为 `~` 或绝对路径；远端路径经 shell 引用，支持空格等特殊字符。

```bash
cd ~/Projects/myrepo
sync-remote -H siyuan -m git-push -n   # 预览
sync-remote -H siyuan -m git-push
sync-remote -H siyuan -m git-push -f   # 分叉时本地权威覆盖远端
sync-remote -H siyuan -m git-sync
```

### 自测

git 模式回归不依赖真 SSH / 集群，使用临时 HOME + 假 `ssh`：

```bash
./remote/test_git_modes.sh
```

## run-remote

`run-remote` 将命令及其参数安全引用后，通过 SSH 在映射目录内执行。选项必须写在命令之前；需要传递以 `-` 开头的命令名时可使用 `--`。

```bash
run-remote squeue -u "$USER"
run-remote julia run_sjtusy_omp.jl
run-remote sbatch job.sub
run-remote tail -20 dqmc.out
run-remote make
run-remote precheck
run-remote -n echo hello
run-remote --login sbatch job.sub
run-remote -d '~/other/project' make
run-remote -H mycluster -p 2222 make
```

`--login` 使用 `bash -lc` 包装命令，适合调度器等程序只在登录 shell 中加入 `PATH` 的集群。`--dry-run` 会把完整 SSH 命令输出到 stderr，不连接远端。

`precheck` 使用非交互 SSH 和 10 秒连接超时测试连通性，并汇报当前本地 Git 工作区是 clean、dirty 还是非 Git 仓库：

```bash
run-remote precheck
```

完整选项可通过 `run-remote -h` 查看。

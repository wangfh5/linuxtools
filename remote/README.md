# remote 工具集

`remote/` 提供两个围绕同一远端项目目录工作的工具：

- `sync-remote`：通过 rsync 同步文件，或通过 Git 同步 commits。
- `run-remote`：通过 SSH 在映射后的远端目录中执行命令。

两者共享配置与“异树同枝”路径映射。你只需进入本地项目目录，工具就能找到远端对应目录，不必在每次命令中重复填写路径。

## 设计理念：异树同枝

![异树同枝：本地与远端目录映射](assets/sync-remote.png)

每台机器的家目录下都是一棵目录树：本地树以 `$HOME` 为根，远端树以 `$DEFAULT_REMOTE_BASE` 为映射根。你在本地 `~/Projects/mycode` 工作，就像站在树的一根枝上；工具保留当前目录相对本地 `$HOME` 的路径，把它拼接到远端映射根下，从而找到另一棵树上的同一根枝。

### 对称映射

默认配置 `DEFAULT_REMOTE_BASE="~"`，两端在各自家目录下保持相同的相对结构：

```text
本地：$HOME/Projects/mycode
            └─ Projects/mycode

远端：$HOME/Projects/mycode
            └─ Projects/mycode
```

在本地 `~/Projects/mycode` 中执行 `sync-remote` 或 `run-remote make`，远端目标都是 `~/Projects/mycode`。

### 非对称映射

如果远端项目统一放在某个子目录中，可以改变远端树根：

```bash
DEFAULT_REMOTE_BASE="~/mywork"
```

映射关系随之变为：

```text
本地：~/Projects/mycode
远端：~/mywork/Projects/mycode
```

这样仍然保留 `Projects/mycode` 这段“枝的走向”，只是把它挂到了远端的 `~/mywork` 子树下。

路径映射有两个边界：

- 当前本地目录必须位于 `$HOME` 下。
- 远端映射根及目标目录所需的父目录必须已经存在；`run-remote` 还要求最终映射目录已经存在。

## 工具和模式怎么选

| 场景 | 推荐方式 |
| --- | --- |
| 在远端对应项目中编译、提交作业或查看结果 | `run-remote` |
| 已 commit 的代码在两端快进同步 | `git-push`、`git-pull` 或 `git-sync` |
| 严格镜像整个目录，并删除目标端多余文件 | `push` 或 `pull` |
| 复制文件，但保留目标端独有文件 | `copy-push` 或 `copy-pull` |
| 把包含未提交改动、暂存区和 Git 状态的工作现场交给远端 | `handoff` |
| 从 handoff 的远端现场安全返回本地 | `reclaim` |

## 安装

在仓库根目录运行：

```bash
./setup.sh
```

从旧版 `sync/` 目录结构升级时，需要重新运行 `./setup.sh`，刷新原有的 `~/bin/sync-remote` 符号链接。

也可以手动创建符号链接：

```bash
mkdir -p ~/bin
ln -sf "$(pwd)/remote/sync_remote.sh" ~/bin/sync-remote
ln -sf "$(pwd)/remote/run_remote.sh" ~/bin/run-remote
```

确保 `~/bin` 已加入 `PATH`。`sync-remote` 的文件模式需要 `rsync` 和 `ssh`，handoff/reclaim 与 Git 模式还需要两端安装 `git`；指纹校验使用 `sha256sum`。`run-remote` 需要 `ssh`，其 `precheck` 命令还会使用本地 `git`。

## 共享配置

配置文件是会被 Bash `source` 的脚本，只应使用自己信任的内容。加载优先级从低到高为：

1. 用户配置：优先读取 `~/.config/remote/config`；不存在时兼容 `~/.config/sync_to_remote/config`。
2. 项目配置：优先读取当前目录的 `.remote_config`；不存在时兼容 `.sync_config`。
3. 命令行参数：覆盖 host、port、mode 等对应值；命令行 `--include-only` 会追加到配置中的 `INCLUDE_ONLY`。

如果新旧配置文件同时存在，只读取新文件名。快速创建配置：

```bash
mkdir -p ~/.config/remote
cp remote/config.sample ~/.config/remote/config
cp remote/remote_config.sample .remote_config
```

项目配置与用户配置使用相同字段；项目中的赋值会覆盖用户配置。`run-remote` 只使用连接和路径字段，会忽略同步模式及过滤规则。

| 字段 | 内置默认值 | 用途 |
| --- | --- | --- |
| `DEFAULT_REMOTE_HOST` | 空，必须配置 | 两个工具共享的 fallback SSH host、alias 或 `user@host` |
| `DEFAULT_RUN_HOST` | `DEFAULT_REMOTE_HOST` | `run-remote` 使用的登录或计算节点 |
| `DEFAULT_SYNC_HOST` | `DEFAULT_REMOTE_HOST` | `sync-remote` 使用的数据传输节点 |
| `DEFAULT_REMOTE_BASE` | `~` | 远端目录树的映射根 |
| `DEFAULT_REMOTE_PORT` | `22` | SSH 端口 |
| `DEFAULT_MODE` | `pull` | `sync-remote` 无 `-m` 参数时使用的模式 |
| `INCLUDE_ONLY` | 空 | 仅同步匹配项，优先级高于全部排除规则 |
| `EXCLUDE_TYPES` | 空 | 启用预定义排除规则组 |
| `EXCLUDE_CUSTOM` | 空 | 追加自定义排除规则 |
| `EXCLUDES_FORTRAN`、`EXCLUDES_PYTHON`、`EXCLUDES_CPP`、`EXCLUDES_COMMON` | 由用户配置定义 | 可被 `EXCLUDE_TYPES` 引用的规则组 |

### 推荐使用 SSH alias

将用户名、端口和密钥放在 `~/.ssh/config`：

```ssh-config
Host mycluster
    HostName cluster.example.com
    User username
    Port 22
    IdentityFile ~/.ssh/id_ed25519
```

remote 配置只保留逻辑名称和映射根：

```bash
DEFAULT_REMOTE_HOST="mycluster"
DEFAULT_REMOTE_BASE="~"
DEFAULT_MODE="pull"
```

旧字段 `DEFAULT_SSH_IDENTITY_FILE` 已不再支持；请使用 SSH 配置中的 `IdentityFile`。

### 分离命令节点与传输节点

如果登录节点与数据传输节点共享文件系统，可以分别配置：

```bash
DEFAULT_RUN_HOST="siyuan"
DEFAULT_SYNC_HOST="sydata"
DEFAULT_REMOTE_HOST="siyuan"
DEFAULT_REMOTE_BASE="~"
```

`run-remote` 优先使用 `DEFAULT_RUN_HOST`，`sync-remote` 优先使用 `DEFAULT_SYNC_HOST`，未配置角色专用 host 时都回退到 `DEFAULT_REMOTE_HOST`。命令行 `-H` 始终具有最高优先级。

## sync-remote

常用命令：

```bash
sync-remote                         # 使用 DEFAULT_MODE
sync-remote -m push                 # 本地严格镜像到远端
sync-remote -m pull                 # 远端严格镜像到本地
sync-remote -m copy-push -n         # 预览一次保留远端文件的推送
sync-remote -m handoff              # 把完整工作现场接力到远端
sync-remote -m reclaim              # 从接力现场归队
sync-remote -m git-push             # 把本地超前 commits 快进到远端
sync-remote -m git-pull             # 把远端超前 commits 快进到本地
sync-remote -m git-sync             # 自动判断快进方向
sync-remote -H mycluster -m pull    # 临时覆盖同步 host
sync-remote -h
```

### 模式语义

| 模式 | 方向 | 删除目标端独有文件 | 主要保护 |
| --- | --- | --- | --- |
| `push` | 本地 → 远端 | 是 | 无冲突检查，先用 `-n` 预览 |
| `pull` | 远端 → 本地 | 是 | 无冲突检查，先用 `-n` 预览 |
| `copy-push` | 本地 → 远端 | 否 | 保留远端独有文件 |
| `copy-pull` | 远端 → 本地 | 否 | 保留本地独有文件 |
| `handoff` | 本地 → 远端 | 否 | 检查远端 Git 状态，有冲突时 fork 新槽位 |
| `reclaim` | 远端 → 本地 | 否 | 校验本地自 handoff 后没有 tracked 状态变化 |
| `git-push` | 本地 commits → 远端 | 不适用 | 默认仅允许快进 |
| `git-pull` | 远端 commits → 本地 | 不适用 | 仅允许快进 |
| `git-sync` | 自动判断 | 不适用 | 仅自动执行单向快进 |

`push` 和 `pull` 会把目标端变成源端的镜像，目标端额外文件会被 `--delete` 删除。名称带 `copy-` 的模式、`handoff` 和 `reclaim` 都不执行删除。

### 文件过滤

过滤规则只作用于 rsync 类模式，git 模式始终只传 commits。规则优先级为：

1. `INCLUDE_ONLY`：只同步指定内容，忽略所有 `EXCLUDE_*`。
2. `EXCLUDE_TYPES`：依次加载 `fortran`、`python`、`cpp`、`common` 等预定义规则组。
3. `EXCLUDE_CUSTOM`：追加项目自定义排除项。
4. 如果没有配置任何规则，使用脚本内置的少量编译产物与系统文件排除项。

示例：

```bash
INCLUDE_ONLY=("results" "*.csv")

EXCLUDE_TYPES=("python" "common")
EXCLUDE_CUSTOM=(
    "--exclude=data/"
    "--exclude=outputs/"
)
```

目录模式末尾的 `/` 会被自动去除，因此 `results` 和 `results/` 的效果相同。

命令行 `--include-only PATTERN` 可以重复使用，并追加到配置中的 `INCLUDE_ONLY`：

```bash
sync-remote -m copy-push --include-only refs.bib
sync-remote -m copy-push --include-only assets --include-only '*.tex'
```

`handoff` 和 `reclaim` 会移除针对 `.git/` 的排除项，并默认复用 `.gitignore` 与 `.git/info/exclude` 来过滤大型生成物。设置 `INCLUDE_ONLY` 会取代这一默认过滤语义，也可能不再形成完整工作现场，应谨慎使用。

## Handoff：工作现场接力

Handoff 不是普通的文件推送，而是把本地工作树、暂存区和 Git 元数据一起交给远端，让远端能够立即继续 `git status`、`git diff`、提交或运行。它在覆盖 canonical 远端目录之前检查冲突；如果无法确认安全，就自动创建一个并列的 fork 槽位。

### 判定流程

1. 记录本地 HEAD 与 tracked Git 状态指纹。
2. 通过 SSH 检查 canonical 远端目录的存在性、tracked 修改、HEAD 和 pairing marker。
3. 安全时同步到原目录；检测到远端工作时，改用 `<项目名>-handoff-<时间戳>`。
4. fork 时使用 `--link-dest` 复用 canonical 目录中未变化的文件，减少传输和磁盘占用。
5. 同步成功后在两端写入 marker，记录本次同步点和实际远端路径。

| 远端状态 | 判定 | 动作 |
| --- | --- | --- |
| 目录不存在 | `absent` | 原位创建 |
| 非 Git 目录 | `safe` | 原位同步 |
| HEAD 一致 | `safe` | 原位同步 |
| 远端 HEAD 是本地 HEAD 的祖先 | `safe` | 原位同步 |
| tracked 文件有修改，但指纹与上次 marker 一致 | `safe` | 视为上次 handoff 留下的现场，原位同步 |
| tracked 文件有新修改 | `dirty` | fork 新槽位 |
| 远端存在本地不认识的 commit | `diverged` | fork 新槽位 |

Handoff 不使用 `--delete`，因此不会删除远端独有文件。它会同步 `.git/`，因为 staged changes、branch refs、stash 等都是完整工作现场的一部分。

常用命令：

```bash
sync-remote -m handoff
sync-remote -m handoff -n
sync-remote -m handoff --suffix mobile
sync-remote -H mycluster -m handoff
```

当发生冲突时，`--suffix mobile` 会使用类似 `mycode-handoff-mobile` 的槽位名；未指定后缀时使用时间戳。命令输出会显示最终目标，以及先登录远端、再进入该目录的两步提示。

`-f` 或 `--force` 会跳过冲突判定并强制使用 canonical 目录：

```bash
sync-remote -m handoff -f
```

这可能覆盖远端 tracked 改动和远端独有 commits。只有在已经手动确认远端内容可以被本地现场取代时才应使用。

## Reclaim：从接力现场归队

Reclaim 是 handoff 的反向操作：结束远端工作，把远端现场拉回本地。它会优先读取 handoff 留在本地的 marker，因此即使上次 handoff 使用了 fork 槽位，也能找到正确的远端来源。

执行过程：

1. 从本地 marker 读取实际远端 host 和路径；只有 marker host 与当前同步 host 相同时才采用该路径，否则回退到“异树同枝”的 canonical 路径。
2. 检查远端路径与 handoff marker。
3. 比较当前本地 tracked 状态指纹和 handoff 时记录的指纹；不一致时拒绝覆盖。
4. 从远端同步到本地，但不删除本地独有文件。
5. 确认两端指纹一致后刷新 pairing marker，建立新的同步点。

常用命令：

```bash
sync-remote -m reclaim
sync-remote -m reclaim -n
sync-remote -H mycluster -m reclaim
```

校验失败时，先用 `git status`、`git diff` 和 `git log` 确认本地发生了什么，再选择 commit、stash 或手动保存。本地状态确实可以被远端取代时，可以强制执行：

```bash
sync-remote -m reclaim -f
```

### Pairing marker

对于普通 Git 仓库，marker 存放在 `.git/` 内，因此不会出现在 `git status` 中，也不会被 rsync 传到错误的一端：

| 位置 | 内容 | 用途 |
| --- | --- | --- |
| 远端 `.git/.sync_handoff_mark` | 上次对齐时的 Git 指纹 | 判断远端现场是否在 handoff 后发生变化 |
| 本地 `.git/.sync_reclaim_mark` | 远端 host、实际路径和时间 | reclaim 找回 canonical 或 fork 槽位 |

Handoff 和 reclaim 成功后都会刷新 marker，而不是在归队后删除。Marker 表示“最近一次两端已知一致的同步点”；保留它才能让下一次 handoff 识别出远端 dirty 状态只是上次同步留下的现场，而不是新的冲突。

### Handoff/Reclaim 边界

- 指纹只覆盖 HEAD、tracked 工作树和暂存区，不包含 untracked 文件；同名 untracked 文件仍可能被 rsync 覆盖。
- 两种模式都不使用 `--delete`。文件删除或重命名不会自动清除接收端残留；reclaim 检测到由此造成的两端指纹不一致时会警告并跳过 marker 刷新。
- 非 Git 目录无法建立可靠指纹；handoff 会按无 Git 冲突信息处理，reclaim 默认拒绝并要求显式 `-f`。
- submodule 和 worktree 的 `.git` 可能是文件而不是目录，远端冲突检测与 marker 位置会退化；重要现场应先手动确认。
- 远端或本地正处于 merge、rebase 等中间状态时，应先完成或中止该 Git 操作。

## git-push / git-pull / git-sync

Git 模式经 SSH 直连远端仓库，只同步 commits，不经过 GitHub，也不传输 untracked 文件或未提交改动。

- `git-push`：本地超前时快进远端分支和工作树。
- `git-pull`：远端超前时快进本地分支和工作树。
- `git-sync`：探测两端关系，自动执行唯一安全的快进方向；两端分叉时拒绝。

共同约束：

- 必须在本地仓库根目录执行，远端映射目录也必须是现有 Git 仓库。
- 本地与远端分支名必须一致。
- 本地使用专用 remote 名 `sync-remote`，不会修改 `origin`。
- push 前会把远端非 bare 仓库设置为 `receive.denyCurrentBranch=updateInstead`，让当前分支更新后同步工作树。
- 本地 dirty 不会预先阻止 push 或 pull；pull 与本地改动重叠时，Git 自身会拒绝更新。
- 远端 tracked dirty 会阻止 push，因为更新远端工作树可能覆盖它；它不会阻止从远端 pull。

远端超前或历史分叉时，`git-push -f` 使用 `--force-with-lease`，以本地为权威覆盖远端分支和工作树。`git-sync -f` 只在历史分叉时强推；远端单纯超前时仍然执行正常的快进拉取：

```bash
sync-remote -H mycluster -m git-push -n
sync-remote -H mycluster -m git-push
sync-remote -H mycluster -m git-push -f
sync-remote -H mycluster -m git-sync
```

`--force-with-lease` 会检查远端 tip 是否仍是刚探测到的值，降低覆盖并发新提交的风险，但远端独有 commits 仍会丢失。`git-pull` 忽略 `-f`，始终只允许快进。

### 自测

Git 模式回归测试使用临时 HOME 和假 SSH，不需要连接真实服务器：

```bash
./remote/test_git_modes.sh
```

## run-remote

`run-remote` 将命令及参数进行 shell 引用，然后通过 SSH 在“异树同枝”映射目录内执行。选项必须写在命令之前；如果命令名以 `-` 开头，可以用 `--` 结束选项解析。

```bash
run-remote make
run-remote squeue -u "$USER"
run-remote sbatch job.sub
run-remote tail -20 dqmc.out
run-remote julia run_sjtusy_omp.jl
run-remote -n echo hello
run-remote --login sbatch job.sub
run-remote -d '~/other/project' make
run-remote -H mycluster -p 2222 make
```

主要选项：

- `-H, --host HOST`：临时覆盖 `DEFAULT_RUN_HOST` 或 `DEFAULT_REMOTE_HOST`。
- `-d, --remote-dir DIR`：跳过路径映射，直接指定远端工作目录。
- `-p, --port PORT`：临时覆盖 SSH 端口。
- `-n, --dry-run`：打印完整 SSH 命令，不建立连接。
- `--login`：使用 `bash -lc` 执行，适合调度器等程序只在登录 shell 中加入 `PATH` 的集群。

`precheck` 使用非交互 SSH 和 10 秒连接超时检查连通性，并报告当前本地目录是 clean、dirty 还是非 Git 仓库：

```bash
run-remote precheck
```

完整选项可通过 `run-remote -h` 查看。

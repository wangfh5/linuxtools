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
| `DEFAULT_MODE` | `push` | `sync-remote` 默认模式 |
| `INCLUDE_ONLY` | 空 | `sync-remote` 仅同步匹配项 |
| `EXCLUDE_TYPES` | 空 | `sync-remote` 启用的预定义排除规则组 |
| `EXCLUDE_CUSTOM` | 空 | `sync-remote` 自定义排除规则 |
| `EXCLUDES_FORTRAN`、`EXCLUDES_PYTHON`、`EXCLUDES_CPP`、`EXCLUDES_COMMON` | 由用户定义 | `sync-remote` 可复用的排除规则组 |

推荐使用 SSH alias，将连接细节统一放在 `~/.ssh/config` 中：

```bash
DEFAULT_REMOTE_HOST="mycluster"
DEFAULT_REMOTE_BASE="~"
DEFAULT_MODE="push"
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

`sync-remote` 是 `rsync` 的双向同步封装。它支持覆盖式 push/pull、保留目标文件的 copy-push/copy-pull，以及冲突感知的 handoff/reclaim。

```bash
sync-remote                         # 使用 DEFAULT_MODE
sync-remote -m push                 # 本地覆盖远端
sync-remote -m pull                 # 远端覆盖本地
sync-remote -m copy-push -n         # 预览保留远端文件的推送
sync-remote -m handoff              # 接力工作现场
sync-remote -m reclaim              # 从远端归队
sync-remote -H mycluster -m pull    # 临时覆盖 host
sync-remote -h
```

同步过滤规则继续沿用 `config.sample` 和 `remote_config.sample` 中的数组配置。`INCLUDE_ONLY` 优先级最高；未设置时合并 `EXCLUDE_TYPES` 与 `EXCLUDE_CUSTOM`。

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

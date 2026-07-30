# linuxtools

个人开发工具集，包含各种通用的开发和管理脚本工具。

## 工具列表

### [sync-remote](./remote/)

远程服务器文件同步工具，基于 rsync 的双向同步封装脚本。

**核心特性**：相对路径镜像；rsync 双向同步；git-push/pull/sync 经 SSH 只传 commits（不经 GitHub）。

```bash
sync-remote              # 推送到远程
sync-remote -m pull      # 从远程拉取
sync-remote -m git-push  # 本地超前 commits ff 到远端
./remote/test_git_modes.sh  # git 模式沙箱回归
```

### [run-remote](./remote/)

远程命令执行工具，通过 SSH 在当前项目的远端镜像目录运行任意命令。

```bash
run-remote make                 # 在远端镜像目录构建
run-remote sbatch job.sub       # 提交 Slurm 作业
run-remote -n echo hello        # 预览 SSH 命令
```

详见 [remote/README.md](./remote/README.md)

### [asmgr](./asmgr/)

`~/agent-settings` 中央配置仓库的命令行管家：统一管理 skills、subagents、项目局域清单与 Claude Code plugin/marketplace。

**核心特性**：中央存储 + 符号链接，跨 cursor/claude-code/codex/gemini/opencode/pi/omp，统一 scope 模型。

**依赖**: 需要安装 `yq` (https://github.com/mikefarah/yq)

```bash
asmgr add <github-url>           # 从 GitHub 添加 skill
asmgr add <github-url> -a cursor # 添加并链接到 cursor
```

详见 [asmgr/README.md](./asmgr/README.md)

## 安装

### 前置依赖

asmgr 需要 `yq` 工具：

```bash
# macOS
brew install yq

# Linux - 参见官方文档
# https://github.com/mikefarah/yq#install
```

### 安装工具

```bash
# 一键安装所有工具（会自动添加 ~/bin 到 PATH）
./setup.sh
```

从旧版 `sync/` 目录结构升级时，请重新运行 `./setup.sh` 以刷新已有的 `sync-remote` 符号链接。

或手动安装到 `~/bin/` 目录：

```bash
# 确保 ~/bin 在 PATH 中
mkdir -p ~/bin
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 安装 remote 工具
ln -sf "$(pwd)/remote/sync_remote.sh" ~/bin/sync-remote
ln -sf "$(pwd)/remote/run_remote.sh" ~/bin/run-remote
```

## 添加新工具

1. 在对应分类目录下创建脚本
2. 添加执行权限：`chmod +x script_name.sh`
3. 在该目录创建 `README.md` 说明文档
4. 更新根目录 README 的工具列表
5. 创建符号链接到 `~/bin/`

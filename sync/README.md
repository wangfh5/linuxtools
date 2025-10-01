# sync-remote - 远程服务器文件同步工具

支持双向同步的 rsync 封装脚本，简化本地和远程服务器之间的文件传输。

## 特性

- ✅ 双向同步（push/pull）
- ✅ 多级配置支持
- ✅ Dry-run 预览模式
- ✅ 智能路径映射
- ✅ rsync 参数自定义

## 设计理念

**相对路径镜像同步** - 这是本工具的核心设计：

- 工具会自动计算当前目录相对于 `$HOME` 的路径
- 在远程服务器的对应位置进行同步
- 本地和远程必须有相似的目录结构

### 工作原理示例

假设配置：
- 本地 HOME: `/Users/username`
- 远程 BASE: `/remote/home/username`

在本地 `~/Projects/mycode` 目录执行 `sync-remote`：
```
本地路径: /Users/username/Projects/mycode
相对路径: /Projects/mycode
远程路径: /remote/home/username/Projects/mycode
```

**优势**：
- 无需每次指定目录路径
- 保持本地和远程目录结构一致
- 适合在多个项目间频繁切换同步

**限制**：
- 当前目录必须在 `$HOME` 下
- 需要远程有对应的目录结构

## 快速开始

```bash
# 1. 安装（创建符号链接）
ln -sf $(pwd)/sync/sync_to_remote.sh ~/bin/sync-remote

# 2. 配置用户默认设置
mkdir -p ~/.config/sync_to_remote
cp sync/config.sample ~/.config/sync_to_remote/config
vim ~/.config/sync_to_remote/config  # 编辑服务器地址等信息

# 3. （可选）为特定项目创建配置
# 在项目目录下：
cp /path/to/sync/sync_config.sample .sync_config
vim .sync_config  # 定制项目特定行为
```

## 使用方法

```bash
# 本地推送到远程（默认）
sync-remote

# 从远程拉取到本地
sync-remote -m pull

# 预览模式（dry-run）
sync-remote -n

# 查看帮助
sync-remote -h
```

## SSH 配置（推荐）

**最佳实践**：在 `~/.ssh/config` 中配置服务器，然后在 sync-remote 中使用别名。

### 示例：配置超算服务器

**1. 编辑 `~/.ssh/config`：**
```ssh-config
Host scnet
    HostName lasg02.hpccube.com
    Port 65032
    User acn16ba0cj
    IdentityFile ~/.ssh/acn16ba0cj_lasg02.hpccube.com_RsaKeyExpireTime_2025-11-25_11-22-10.txt
```

**2. 在 sync-remote 配置中使用别名：**
```bash
# ~/.config/sync_to_remote/config
DEFAULT_REMOTE_HOST="scnet"  # 引用 SSH alias
DEFAULT_REMOTE_BASE="/dssg/home/acct-phyxxy/phyxxy-wfh"
```

**优势：**
- ✅ 一处配置，多工具复用（ssh、scp、rsync 都能用）
- ✅ 端口、密钥、用户名都在 SSH config 中管理
- ✅ 配置简洁，易于维护

## 配置文件

工具支持两级配置，按优先级从高到低：
1. **项目配置**：`./.sync_config`（当前目录，项目特定配置）
2. **用户配置**：`~/.config/sync_to_remote/config`（遵循 XDG 标准）

### 两种配置的区别

| 配置类型 | 用途 | 适用场景 | 示例文件 |
|---------|------|---------|---------|
| **用户配置** | 定义默认行为和预设规则 | 跨项目通用设置 | `config.sample` |
| **项目配置** | 覆盖默认配置 | 特定项目的定制需求 | `sync_config.sample` |

**典型工作流**：
1. 首次使用：复制 `config.sample` 到 `~/.config/sync_to_remote/config`，配置常用服务器
2. 项目特殊需求：在项目根目录创建 `.sync_config`，定制同步行为

### 配置示例

**用户配置** (`config.sample`)：
- 定义常用的远程服务器和基础路径
- 预定义各语言项目的排除规则（Fortran、Python、C/C++）
- 设置默认同步模式（通常是 `push`）

**项目配置** (`sync_config.sample`)：
- 覆盖同步模式（如数据项目用 `pull`）
- 定义项目特定的排除规则
- 可选：覆盖服务器地址（多服务器场景）

### 主要配置项

**基础配置：**
- `DEFAULT_REMOTE_HOST`: 远程服务器地址
  - 方式1（推荐）：使用 `~/.ssh/config` 中的 Host alias（如 `scnet`）
  - 方式2：使用完整地址（如 `user@host.com`）
- `DEFAULT_REMOTE_BASE`: 远程基础目录
- `DEFAULT_REMOTE_PORT`: SSH 端口（默认 `22`，仅在方式2下需要配置）
- `DEFAULT_SSH_IDENTITY_FILE`: SSH 密钥文件路径（可选，使用 alias 时自动读取）
- `DEFAULT_MODE`: 默认同步模式（`push`/`pull`/`copy-push`/`copy-pull`）

**排除规则配置：**
- `EXCLUDES_*`: 预定义规则（在用户配置中定义，供 `EXCLUDE_TYPES` 使用）, 目前支持如下四项: 
  - `EXCLUDES_FORTRAN`: Fortran 项目规则（`*.o`, `*.mod`, `*.a`, `*.so`）
  - `EXCLUDES_PYTHON`: Python 项目规则（`__pycache__/`, `*.pyc`, `venv/`）
  - `EXCLUDES_CPP`: C/C++ 项目规则（`*.o`, `build/`, `cmake-build-*/`）
  - `EXCLUDES_COMMON`: 通用规则（`.git/`, `.DS_Store`, `Thumbs.db`）
- `EXCLUDE_TYPES`: 数组，指定要使用的预定义规则（可组合多个）
  - 可选值：`fortran`, `python`, `cpp`, `common`
  - 示例：`EXCLUDE_TYPES=("fortran" "common")`
- `EXCLUDE_CUSTOM`: 自定义排除规则数组（在预定义规则基础上追加）

**排除规则合并顺序：**
1. 如果设置了 `EXCLUDE_TYPES`，按顺序加载对应的预定义规则
2. 追加自定义的 `EXCLUDE_CUSTOM` 数组
3. 如果都没有，使用脚本默认规则

**优势：用户完全掌控**
- 想要通用规则？添加 `"common"` 到 `EXCLUDE_TYPES`
- 不想要通用规则？不添加即可
- 需要同步 `.git/`？完全由你决定


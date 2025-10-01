# sync-remote - 远程服务器文件同步工具

支持双向同步的 rsync 封装脚本，简化本地和远程服务器之间的文件传输。

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
# 安装（创建符号链接）
ln -sf /home/wangfh5/Projects/tools/sync/sync_to_remote.sh ~/bin/sync-remote

# 配置
mkdir -p ~/.config/sync_to_remote
cp sync/config.sample ~/.config/sync_to_remote/config
vim ~/.config/sync_to_remote/config  # 编辑服务器地址等信息
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

## 配置文件

工具支持两级配置，按优先级从高到低：
1. 项目配置：`./.sync_config`（当前目录，项目特定配置）
2. 用户配置：`~/.config/sync_to_remote/config`（遵循 XDG 标准）

### 配置示例

参见 `config.sample` 文件，主要配置项：

- `REMOTE_HOST`: 远程服务器地址
- `REMOTE_USER`: SSH 用户名
- `REMOTE_BASE_DIR`: 远程基础目录
- `EXCLUDE_PATTERNS`: 排除的文件模式
- 等等...

## 特性

- ✅ 双向同步（push/pull）
- ✅ 多级配置支持
- ✅ Dry-run 预览模式
- ✅ 智能路径映射
- ✅ rsync 参数自定义


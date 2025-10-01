# sync-remote - 远程服务器文件同步工具

支持双向同步的 rsync 封装脚本，简化本地和远程服务器之间的文件传输。

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

工具支持多级配置，按优先级从高到低：
1. 项目配置：`./.sync_config`（当前目录）
2. 用户配置：`~/.sync_config`（用户主目录）
3. 全局配置：`~/.config/sync_to_remote/config`

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


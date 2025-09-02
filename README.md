# 个人开发工具集

这个目录包含了各种通用的开发和管理工具。

## 目录结构

```
tools/
├── sync/                   # 文件同步工具
│   └── sync_to_remote.sh   # 远程服务器同步脚本
├── backup/                 # 备份工具 (待添加)
├── deploy/                 # 部署工具 (待添加)
└── README.md              # 本文件
```

## 全局安装

所有工具通过符号链接安装到 `~/bin/` 目录，实现全局可用：

```bash
# 创建 ~/bin 目录（如果不存在）
mkdir -p ~/bin

# 同步工具
ln -sf /home/wangfh5/Projects/tools/sync/sync_to_remote.sh ~/bin/sync-remote

# 将 ~/bin 添加到 PATH（如果尚未添加）
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

## 版本控制

整个 `tools/` 目录应该被纳入版本控制，这样可以：
- 跟踪工具的演进历史
- 在不同机器间同步工具配置
- 备份重要的工具脚本

## 使用方法

### sync-remote
远程服务器文件同步工具，支持双向同步。

```bash
# 本地推送到远程（默认）
sync-remote

# 从远程拉取到本地
sync-remote -m pull

# 预览模式
sync-remote -n

# 查看帮助
sync-remote -h
```

## 配置文件

工具支持多级配置：
1. 项目配置：`./.sync_config`
2. 用户配置：`~/.sync_config`
3. 全局配置：`~/.config/sync_to_remote/config`

## 添加新工具

1. 在对应分类目录下创建脚本
2. 添加执行权限：`chmod +x script_name.sh`
3. 创建符号链接：`ln -sf /home/wangfh5/Projects/tools/category/script_name.sh ~/bin/tool-name`
4. 更新此 README 文档

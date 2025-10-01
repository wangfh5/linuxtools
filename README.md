# linuxtools

个人开发工具集，包含各种通用的开发和管理脚本工具。

## 工具列表

### [sync-remote](./sync/)
远程服务器文件同步工具，基于 rsync 的双向同步封装脚本。

```bash
sync-remote              # 推送到远程
sync-remote -m pull      # 从远程拉取
```

详见 [sync/README.md](./sync/README.md)

## 安装

所有工具通过符号链接安装到 `~/bin/` 目录：

```bash
# 确保 ~/bin 在 PATH 中
mkdir -p ~/bin
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 安装工具（以 sync-remote 为例）
ln -sf $(pwd)/sync/sync_to_remote.sh ~/bin/sync-remote
```

## 添加新工具

1. 在对应分类目录下创建脚本
2. 添加执行权限：`chmod +x script_name.sh`
3. 在该目录创建 `README.md` 说明文档
4. 更新根目录 README 的工具列表
5. 创建符号链接到 `~/bin/`

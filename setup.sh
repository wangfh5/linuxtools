#!/bin/bash
# 一键配置脚本 - 安装 sync-remote 和 skill-mgr 到全局 PATH

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/bin"

echo "=== linuxtools 一键配置 ==="
echo ""

# 1. 创建 ~/bin 目录
if [[ ! -d "$BIN_DIR" ]]; then
    echo "[1/3] 创建 $BIN_DIR 目录..."
    mkdir -p "$BIN_DIR"
else
    echo "[1/3] $BIN_DIR 目录已存在"
fi

# 2. 创建符号链接
echo "[2/3] 创建符号链接..."

ln -sf "$SCRIPT_DIR/sync/sync_to_remote.sh" "$BIN_DIR/sync-remote"
echo "  ✓ sync-remote -> $SCRIPT_DIR/sync/sync_to_remote.sh"

ln -sf "$SCRIPT_DIR/skill-mgr/skill_mgr.sh" "$BIN_DIR/skill-mgr"
echo "  ✓ skill-mgr -> $SCRIPT_DIR/skill-mgr/skill_mgr.sh"

# 3. 检查并配置 PATH
echo "[3/3] 检查 PATH 配置..."

# 检测当前 shell 配置文件
if [[ -n "$ZSH_VERSION" ]] || [[ "$SHELL" == *"zsh"* ]]; then
    SHELL_RC="$HOME/.zshrc"
else
    SHELL_RC="$HOME/.bashrc"
fi

# 检查 PATH 是否已包含 ~/bin（使用 case 模式匹配更可靠）
case ":$PATH:" in
    *":$BIN_DIR:"*)
        echo "  ✓ $BIN_DIR 已在 PATH 中"
        ;;
    *)
        # 检查配置文件是否已有相关配置
        if [[ -f "$SHELL_RC" ]] && grep -qE '(export )?PATH=.*(\$HOME|~)/bin' "$SHELL_RC"; then
            echo "  ✓ PATH 配置已存在于 $SHELL_RC（需要重新加载）"
        else
            echo "  添加 PATH 配置到 $SHELL_RC..."
            [[ -f "$SHELL_RC" ]] || touch "$SHELL_RC"
            echo '' >> "$SHELL_RC"
            echo '# linuxtools - 添加 ~/bin 到 PATH' >> "$SHELL_RC"
            echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
            echo "  ✓ 已添加 PATH 配置"
        fi
        ;;
esac

echo ""
echo "=== 配置完成 ==="
echo ""
echo "如果 PATH 刚被修改，请运行 source $SHELL_RC 或重新打开终端"
echo "验证安装: sync-remote -h && skill-mgr --help"

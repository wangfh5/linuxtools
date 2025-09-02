#!/bin/bash

# 通用目录同步工具
# 支持本地与远程服务器之间的双向同步

# 默认配置
DEFAULT_REMOTE_HOST="phyxxy-wfh@sydata.hpc.sjtu.edu.cn"
DEFAULT_REMOTE_BASE="/dssg/home/acct-phyxxy/phyxxy-wfh"
DEFAULT_MODE="push"

# 配置文件路径（优先级：当前目录 > 家目录 > 默认配置）
CONFIG_FILES=(
    "./.sync_config"
    "$HOME/.sync_config"
    "$HOME/.config/sync_to_remote/config"
)

# 加载配置文件
load_config() {
    # 按优先级从低到高加载所有存在的配置文件
    # 这样高优先级的配置可以覆盖低优先级的配置
    
    # 1. 首先加载全局配置（如果存在）
    if [[ -f "$HOME/.config/sync_to_remote/config" ]]; then
        echo "加载全局配置: $HOME/.config/sync_to_remote/config"
        source "$HOME/.config/sync_to_remote/config"
    fi
    
    # 2. 然后加载用户配置（如果存在）
    if [[ -f "$HOME/.sync_config" ]]; then
        echo "加载用户配置: $HOME/.sync_config"
        source "$HOME/.sync_config"
    fi
    
    # 3. 最后加载项目配置（如果存在），具有最高优先级
    if [[ -f "./.sync_config" ]]; then
        echo "加载项目配置: ./.sync_config"
        source "./.sync_config"
    fi
}

# 合并排除规则
merge_excludes() {
    local merged_excludes=()
    
    # 如果指定了排除规则类型，使用预定义的规则
    if [[ -n "$EXCLUDE_TYPE" ]]; then
        case "$EXCLUDE_TYPE" in
            "fortran")
                merged_excludes+=("${EXCLUDES_FORTRAN[@]}")
                ;;
            "python")
                merged_excludes+=("${EXCLUDES_PYTHON[@]}")
                ;;
            "cpp")
                merged_excludes+=("${EXCLUDES_CPP[@]}")
                ;;
        esac
    fi
    
    # 添加通用排除规则
    if [[ -n "${EXCLUDES_COMMON[@]}" ]]; then
        merged_excludes+=("${EXCLUDES_COMMON[@]}")
    fi
    
    # 添加自定义排除规则
    if [[ -n "${EXCLUDES[@]}" ]]; then
        merged_excludes+=("${EXCLUDES[@]}")
    fi
    
    # 如果没有任何规则，使用默认规则
    if [[ ${#merged_excludes[@]} -eq 0 ]]; then
        merged_excludes=(
            "--exclude=*.o"
            "--exclude=*.mod" 
            "--exclude=__pycache__/"
            "--exclude=.DS_Store"
            "--exclude=Thumbs.db"
        )
    fi
    
    # 输出最终排除规则
    echo "最终排除规则:"
    for exclude in "${merged_excludes[@]}"; do
        echo "  $exclude"
    done
    EXCLUDES=("${merged_excludes[@]}")
}

# 全局变量
MODE="$DEFAULT_MODE"
REMOTE_HOST="$DEFAULT_REMOTE_HOST"
DRY_RUN=false

# 显示帮助信息
show_help() {
    cat << EOF
通用目录同步工具

用法: $0 [选项]

选项:
    -m, --mode MODE        同步模式 (默认: push)
                          push:      本地覆盖远程 (删除远程多余文件)
                          pull:      远程覆盖本地 (删除本地多余文件)
                          copy-push: 本地复制到远程 (不删除远程文件)
                          copy-pull: 远程复制到本地 (不删除本地文件)
    
    -r, --remote HOST      远程服务器地址 (默认: $DEFAULT_REMOTE_HOST)
    -n, --dry-run          预览模式，不实际执行
    -h, --help             显示此帮助信息

示例:
    $0                     # 默认: 本地覆盖远程
    $0 -m pull             # 远程覆盖本地
    $0 -m copy-push        # 本地复制到远程，不删除
    $0 -n                  # 预览模式
EOF
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--mode)
                MODE="$2"
                shift 2
                ;;
            -r|--remote)
                REMOTE_HOST="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 检测路径并构建远程目标
detect_paths() {
    # 获取当前目录
    LOCAL_PATH="$(pwd)"
    
    # 获取用户家目录
    HOME_PATH="$HOME"
    
    # 检查当前目录是否在家目录下
    if [[ "$LOCAL_PATH" != "$HOME_PATH"* ]]; then
        echo "错误: 当前目录不在用户家目录下"
        echo "当前目录: $LOCAL_PATH"
        echo "家目录: $HOME_PATH"
        exit 1
    fi
    
    # 获取相对于家目录的路径
    RELATIVE_PATH="${LOCAL_PATH#$HOME_PATH}"
    if [[ -z "$RELATIVE_PATH" ]]; then
        RELATIVE_PATH="/"
    fi
    
    # 构建远程目标路径
    REMOTE_TARGET="$REMOTE_HOST:$DEFAULT_REMOTE_BASE$RELATIVE_PATH"
}

# 验证同步模式
validate_mode() {
    case "$MODE" in
        push|pull|copy-push|copy-pull)
            ;;
        *)
            echo "错误: 无效的同步模式 '$MODE'"
            echo "支持的模式: push, pull, copy-push, copy-pull"
            exit 1
            ;;
    esac
}

# 执行同步
perform_sync() {
    # 基本 rsync 参数
    RSYNC_OPTS=(--archive --partial --progress)
    
    # EXCLUDES 数组已经在 merge_excludes() 函数中设置好了
    
    # 根据模式设置源和目标
    case "$MODE" in
        push)
            SOURCE="$LOCAL_PATH/"
            DEST="$REMOTE_TARGET"
            RSYNC_OPTS+=(--delete)
            echo "模式: 本地覆盖远程 (删除远程多余文件)"
            ;;
        pull)
            SOURCE="$REMOTE_TARGET/"
            DEST="$LOCAL_PATH"
            RSYNC_OPTS+=(--delete)
            echo "模式: 远程覆盖本地 (删除本地多余文件)"
            ;;
        copy-push)
            SOURCE="$LOCAL_PATH/"
            DEST="$REMOTE_TARGET"
            echo "模式: 本地复制到远程 (保留远程文件)"
            ;;
        copy-pull)
            SOURCE="$REMOTE_TARGET/"
            DEST="$LOCAL_PATH"
            echo "模式: 远程复制到本地 (保留本地文件)"
            ;;
    esac
    
    # 预览模式
    if [ "$DRY_RUN" = true ]; then
        RSYNC_OPTS+=(--dry-run)
        echo "--- 预览模式 ---"
    fi
    
    echo "本地路径: $LOCAL_PATH"
    echo "远程路径: $REMOTE_TARGET"
    echo "源: $SOURCE"
    echo "目标: $DEST"
    echo
    
    # 执行 rsync
    rsync "${RSYNC_OPTS[@]}" "${EXCLUDES[@]}" "$SOURCE" "$DEST"
    
    if [ $? -eq 0 ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "预览完成！"
        else
            echo "同步完成！"
        fi
    else
        echo "同步失败！"
        exit 1
    fi
}

# 主函数
main() {
    load_config
    merge_excludes
    parse_args "$@"
    validate_mode
    detect_paths
    perform_sync
}

main "$@"
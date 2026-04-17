#!/bin/bash

# 通用目录同步工具 —— 异树同枝
# 每台机器的家目录下，都是一棵以 $HOME 为起点向下延伸的目录树。
# 本工具将当前目录相对本地 $HOME 的"枝的走向"，映射到远端 $DEFAULT_REMOTE_BASE
# 下的同名位置（另一棵树上的同一根枝），通过 rsync 双向同步该枝往后延伸的所有文件。
# 默认 $DEFAULT_REMOTE_BASE="~" 使两端完全对称；也可配置为 ~/mywork 等，
# 让本地 ~/Projects/xxx 映射到远端 ~/mywork/Projects/xxx（非对称映射）。

# 硬编码默认值（作为最后的 fallback）
# 这些值会被配置文件覆盖
FALLBACK_REMOTE_HOST=""   # 无默认值，必须由用户级或项目级配置提供
FALLBACK_REMOTE_BASE="~"  # 默认远端“树干终点”为远端 $HOME（异树同枝）
FALLBACK_REMOTE_PORT="22"
FALLBACK_SSH_IDENTITY_FILE=""  # 默认不指定，让 SSH 自动选择
FALLBACK_MODE="push"

# 配置文件路径（优先级：项目配置 > 用户配置）
CONFIG_FILES=(
    "./.sync_config" # 项目配置
    "$HOME/.config/sync_to_remote/config" # 用户配置
)

# 加载配置文件
load_config() {
    # 按优先级从低到高加载所有存在的配置文件
    # 这样高优先级的配置可以覆盖低优先级的配置
    
    # 1. 首先加载用户配置（如果存在），遵循 XDG 标准
    if [[ -f "$HOME/.config/sync_to_remote/config" ]]; then
        echo "加载用户配置: $HOME/.config/sync_to_remote/config"
        source "$HOME/.config/sync_to_remote/config"
    fi
    
    # 2. 然后加载项目配置（如果存在），具有最高优先级
    if [[ -f "./.sync_config" ]]; then
        echo "加载项目配置: ./.sync_config"
        source "./.sync_config"
    fi
    
    # 3. 应用 fallback 值（如果配置文件中没有定义）
    DEFAULT_MODE="${DEFAULT_MODE:-$FALLBACK_MODE}"
    DEFAULT_REMOTE_HOST="${DEFAULT_REMOTE_HOST:-$FALLBACK_REMOTE_HOST}"
    DEFAULT_REMOTE_BASE="${DEFAULT_REMOTE_BASE:-$FALLBACK_REMOTE_BASE}"
    DEFAULT_REMOTE_PORT="${DEFAULT_REMOTE_PORT:-$FALLBACK_REMOTE_PORT}"
    DEFAULT_SSH_IDENTITY_FILE="${DEFAULT_SSH_IDENTITY_FILE:-$FALLBACK_SSH_IDENTITY_FILE}"
}

# 初始化工作变量
init_vars() {
    # 基于配置值初始化工作变量
    MODE="$DEFAULT_MODE"
    REMOTE_HOST="$DEFAULT_REMOTE_HOST"
    REMOTE_PORT="$DEFAULT_REMOTE_PORT"
    SSH_IDENTITY_FILE="$DEFAULT_SSH_IDENTITY_FILE"
    DRY_RUN=false
    HANDOFF_SLOT_SUFFIX=""
    HANDOFF_EXTRA_OPTS=()
    HANDOFF_FORCE=false
}

# 计算本地 git 状态指纹（供 handoff marker 使用）
# 算法：sha256(HEAD SHA + diff HEAD + diff --cached)
# 非 git 仓库返回空
git_fingerprint() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo ""
        return
    fi
    {
        git rev-parse HEAD 2>/dev/null || echo "NO-HEAD"
        git diff HEAD 2>/dev/null
        echo "---CACHED---"
        git diff --cached 2>/dev/null
    } | sha256sum | awk '{print $1}'
}

# 合并排除规则
merge_excludes() {
    local merged_rules=()
    
    # 检查是否设置了限定规则（INCLUDE_ONLY）
    # 限定规则优先级最高，会忽略所有排除规则
    if [[ -n "${INCLUDE_ONLY[@]}" ]]; then
        echo "使用限定规则 (INCLUDE_ONLY)，忽略所有排除规则"
        echo "只同步以下匹配的内容:"
        
        for pattern in "${INCLUDE_ONLY[@]}"; do
            echo "  include: $pattern"
            # 包含匹配的目录/文件本身
            merged_rules+=("--include=$pattern")
            # 包含匹配目录内的所有内容（如果是目录）
            merged_rules+=("--include=$pattern/**")
        done
        
        # 排除所有其他内容
        merged_rules+=("--exclude=*")
        
        # 将限定规则赋值给 EXCLUDES
        EXCLUDES=("${merged_rules[@]}")
        return
    fi
    
    # 如果没有限定规则，使用原来的排除规则逻辑
    local merged_excludes=()
    
    # 如果指定了排除规则类型，使用预定义的规则
    # 支持数组形式，允许组合多个类型
    if [[ -n "${EXCLUDE_TYPES[@]}" ]]; then
        for type in "${EXCLUDE_TYPES[@]}"; do
            case "$type" in
                "fortran")
                    merged_excludes+=("${EXCLUDES_FORTRAN[@]}")
                    ;;
                "python")
                    merged_excludes+=("${EXCLUDES_PYTHON[@]}")
                    ;;
                "cpp")
                    merged_excludes+=("${EXCLUDES_CPP[@]}")
                    ;;
                "common")
                    merged_excludes+=("${EXCLUDES_COMMON[@]}")
                    ;;
            esac
        done
    fi
    
    # 添加自定义排除规则
    if [[ -n "${EXCLUDE_CUSTOM[@]}" ]]; then
        merged_excludes+=("${EXCLUDE_CUSTOM[@]}")
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
    # 将合并后的规则赋值给 EXCLUDES，供 rsync 使用
    EXCLUDES=("${merged_excludes[@]}")
}

# 显示帮助信息
show_help() {
    cat << EOF
通用目录同步工具

用法: $0 [选项]

选项:
    -m, --mode MODE        同步模式 (默认: 配置文件中的 DEFAULT_MODE)
                          push:      本地覆盖远程 (删除远程多余文件)
                          pull:      远程覆盖本地 (删除本地多余文件)
                          copy-push: 本地复制到远程 (不删除远程文件)
                          copy-pull: 远程复制到本地 (不删除本地文件)
                          handoff:   接力现场到远程 (冲突感知；远端安全则原位，
                                     否则自动 fork 新槽位；默认按 .gitignore 排除)

    -r, --remote HOST      远程服务器地址 (默认: 配置文件中的 DEFAULT_REMOTE_HOST)
    -p, --port PORT        SSH 端口 (默认: 配置文件中的 DEFAULT_REMOTE_PORT，通常是 22)
    -n, --dry-run          预览模式，不实际执行
        --suffix SUFFIX    handoff 模式 fork 槽位时的后缀名（默认: 时间戳）
    -f, --force            handoff 模式跳过所有安全检查，强制原位覆盖（慎用）
    -h, --help             显示此帮助信息

示例:
    $0                     # 默认: 本地覆盖远程
    $0 -m pull             # 远程覆盖本地
    $0 -m copy-push        # 本地复制到远程，不删除
    $0 -m handoff          # 接力现场到远程（自动判断原位或 fork）
    $0 -m handoff --suffix mobile  # fork 时用 "mobile" 作为槽位后缀
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
            -p|--port)
                REMOTE_PORT="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --suffix)
                HANDOFF_SLOT_SUFFIX="$2"
                shift 2
                ;;
            -f|--force)
                HANDOFF_FORCE=true
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

# 异树同枝：在远程目录树上找到与本地相同的枝（相对路径）
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

# 校验必需配置项（在 parse_args 之后执行，命令行 -r 也可满足校验）
validate_config() {
    if [[ -z "$REMOTE_HOST" ]]; then
        echo "错误: 未配置远程服务器地址 (DEFAULT_REMOTE_HOST)"
        echo ""
        echo "请在以下任一配置文件中设置:"
        echo "  - 用户级配置: $HOME/.config/sync_to_remote/config"
        echo "  - 项目级配置: ./.sync_config"
        echo ""
        echo "或通过命令行参数指定: $0 -r user@host"
        echo ""
        echo "示例配置:"
        echo '  DEFAULT_REMOTE_HOST="user@example.com"  # 或 SSH alias'
        echo '  DEFAULT_REMOTE_BASE="~"                 # 默认即远端 $HOME'
        exit 1
    fi
}

# 验证同步模式
validate_mode() {
    case "$MODE" in
        push|pull|copy-push|copy-pull|handoff)
            ;;
        *)
            echo "错误: 无效的同步模式 '$MODE'"
            echo "支持的模式: push, pull, copy-push, copy-pull, handoff"
            exit 1
            ;;
    esac
}

# 构建 SSH 命令字符串（供 rsync -e 和 prepare_handoff 共用）
# 输出: 设置全局变量 SSH_CMD 和 SSH_OPTS_CHANGED
build_ssh_cmd() {
    SSH_CMD="ssh"
    SSH_OPTS_CHANGED=false
    if [[ "$REMOTE_PORT" != "22" ]]; then
        SSH_CMD="$SSH_CMD -p $REMOTE_PORT"
        SSH_OPTS_CHANGED=true
    fi
    if [[ -n "$SSH_IDENTITY_FILE" ]]; then
        SSH_CMD="$SSH_CMD -i $SSH_IDENTITY_FILE"
        SSH_OPTS_CHANGED=true
    fi
}

# Handoff 准备：检查远端状态，决定原位 or fork 槽位，注入 handoff 专用 rsync 选项
prepare_handoff() {
    echo "=== Handoff 接力模式 ==="

    # 1. 采集本地 git 状态
    local LOCAL_HEAD=""
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        LOCAL_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
    fi

    # 2. 解析远端 canonical 路径（tilde 在远端 shell 展开）
    local CANONICAL_REMOTE_PATH="$DEFAULT_REMOTE_BASE$RELATIVE_PATH"

    # 3. SSH 到远端采集状态（只采集，不判定）
    build_ssh_cmd
    echo "检查远端状态: $REMOTE_HOST:$CANONICAL_REMOTE_PATH"
    local REMOTE_STATUS
    REMOTE_STATUS=$($SSH_CMD "$REMOTE_HOST" bash -s -- "$CANONICAL_REMOTE_PATH" <<'REMOTE_PROBE'
set -u
TARGET="$1"
# 安全地展开 leading tilde（避免 eval 带来的命令注入风险）
case "$TARGET" in
    "~")   TARGET="$HOME" ;;
    "~/"*) TARGET="$HOME/${TARGET#~/}" ;;
esac
if [[ ! -d "$TARGET" ]]; then
    echo "DIRTY:no-dir"
    echo "REMOTE_HEAD:"
    echo "ABS_PATH:$TARGET"
    echo "MARKER:none"
    exit 0
fi
cd "$TARGET" 2>/dev/null || { echo "DIRTY:error"; echo "REMOTE_HEAD:"; echo "ABS_PATH:"; echo "MARKER:none"; exit 0; }
ABS=$(pwd)
if [[ ! -d ".git" ]]; then
    echo "DIRTY:no-git"
    echo "REMOTE_HEAD:"
    echo "ABS_PATH:$ABS"
    echo "MARKER:none"
    exit 0
fi
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --quiet --cached 2>/dev/null; then
    echo "DIRTY:true"
else
    echo "DIRTY:false"
fi
echo "REMOTE_HEAD:$(git rev-parse HEAD 2>/dev/null || echo '')"
echo "ABS_PATH:$ABS"
# 读 marker 并对比远端当前指纹
MARKER_FP=""
if [[ -f ".sync_handoff_mark" ]]; then
    MARKER_FP=$(grep '^fingerprint=' .sync_handoff_mark 2>/dev/null | head -n1 | cut -d= -f2)
fi
if [[ -n "$MARKER_FP" ]]; then
    CURRENT_FP=$({
        git rev-parse HEAD 2>/dev/null || echo "NO-HEAD"
        git diff HEAD 2>/dev/null
        echo "---CACHED---"
        git diff --cached 2>/dev/null
    } | sha256sum | awk '{print $1}')
    if [[ "$MARKER_FP" == "$CURRENT_FP" ]]; then
        echo "MARKER:match"
    else
        echo "MARKER:drift"
    fi
else
    echo "MARKER:none"
fi
REMOTE_PROBE
    )

    if [[ -z "$REMOTE_STATUS" ]]; then
        echo "错误: 无法连接远端或采集状态失败"
        exit 1
    fi

    local REMOTE_DIRTY="" REMOTE_HEAD="" REMOTE_ABS="" REMOTE_MARKER="none"
    while IFS= read -r line; do
        case "$line" in
            DIRTY:*)       REMOTE_DIRTY="${line#DIRTY:}" ;;
            REMOTE_HEAD:*) REMOTE_HEAD="${line#REMOTE_HEAD:}" ;;
            ABS_PATH:*)    REMOTE_ABS="${line#ABS_PATH:}" ;;
            MARKER:*)      REMOTE_MARKER="${line#MARKER:}" ;;
        esac
    done <<< "$REMOTE_STATUS"

    # 防御：若远端 shell 有 banner/motd/.bashrc 噪声导致 DIRTY 行被污染
    # 或探测脚本未成功执行，REMOTE_DIRTY 会为空。此时不能继续——空值会悄悄
    # 走到 safe 分支，失去冲突检测。
    if [[ -z "$REMOTE_DIRTY" ]]; then
        echo "错误: 未能从远端采集到有效的状态信息（可能是 shell banner/motd 污染输出）"
        echo "原始响应:"
        echo "$REMOTE_STATUS"
        exit 1
    fi

    # 4. 本地判定 STATUS
    local STATUS=""
    local MARKER_OVERRIDE=false
    if [[ "$REMOTE_DIRTY" == "no-dir" ]]; then
        STATUS="absent"
    elif [[ "$REMOTE_DIRTY" == "error" ]]; then
        echo "错误: 远端目录访问异常"
        exit 1
    elif [[ "$REMOTE_DIRTY" == "true" ]]; then
        STATUS="dirty"
    elif [[ "$REMOTE_DIRTY" == "no-git" || -z "$LOCAL_HEAD" || -z "$REMOTE_HEAD" ]]; then
        STATUS="safe"
    elif [[ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]]; then
        STATUS="safe"
    elif git merge-base --is-ancestor "$REMOTE_HEAD" "$LOCAL_HEAD" 2>/dev/null; then
        STATUS="safe"
    else
        STATUS="diverged"
    fi

    # 4b. Marker 覆盖：若远端 dirty 但指纹与 marker 匹配（即远端自上次 handoff 后未变）
    #     则升级为 safe。diverged 情况下 HEAD 已变，指纹必然不匹配，无需特判。
    if [[ "$STATUS" == "dirty" && "$REMOTE_MARKER" == "match" ]]; then
        STATUS="safe"
        MARKER_OVERRIDE=true
    fi

    # 4c. --force 兜底：跳过所有安全检查（除 absent 外强制 safe）
    local FORCE_OVERRIDE=false
    if [[ "$HANDOFF_FORCE" == "true" && "$STATUS" != "absent" ]]; then
        STATUS="safe"
        FORCE_OVERRIDE=true
    fi

    # 5. 根据 STATUS 决定目标
    local REASON=""
    case "$STATUS" in
        absent)
            REASON="远端目录不存在，原位创建"
            REMOTE_TARGET="$REMOTE_HOST:$CANONICAL_REMOTE_PATH"
            ;;
        safe)
            if [[ "$FORCE_OVERRIDE" == "true" ]]; then
                REASON="--force 强制原位（跳过所有安全检查）"
            elif [[ "$MARKER_OVERRIDE" == "true" ]]; then
                REASON="远端有 tracked 改动，但 marker 指纹匹配（自上次 handoff 后未被改动），原位覆盖"
            else
                REASON="远端无冲突（干净 / HEAD 一致 / 远端是本地祖先 / 非 git 目录）"
            fi
            REMOTE_TARGET="$REMOTE_HOST:$CANONICAL_REMOTE_PATH"
            ;;
        dirty|diverged)
            local suffix="$HANDOFF_SLOT_SUFFIX"
            [[ -z "$suffix" ]] && suffix="$(date +%Y%m%d-%H%M)"
            local basename_val="${RELATIVE_PATH##*/}"
            [[ -z "$basename_val" || "$basename_val" == "/" ]] && basename_val="home"
            local parent_rel="${RELATIVE_PATH%/*}"
            # 归一化：去掉 parent_rel 头尾的斜杠和 BASE 尾部斜杠，再统一用 / 拼接
            parent_rel="${parent_rel#/}"
            parent_rel="${parent_rel%/}"
            local base_norm="${DEFAULT_REMOTE_BASE%/}"
            local slot_name="${basename_val}-handoff-${suffix}"
            local slot_path
            if [[ -z "$parent_rel" ]]; then
                slot_path="$base_norm/$slot_name"
            else
                slot_path="$base_norm/$parent_rel/$slot_name"
            fi
            REMOTE_TARGET="$REMOTE_HOST:$slot_path"
            if [[ "$STATUS" == "dirty" ]]; then
                REASON="远端 tracked 文件有修改，fork 到新槽位"
            else
                REASON="远端有本地不认识的 commit，fork 到新槽位"
            fi
            # 若原目录存在，用 --link-dest 优化传输（未变文件硬链接）
            if [[ -n "$REMOTE_ABS" ]]; then
                HANDOFF_EXTRA_OPTS+=("--link-dest=$REMOTE_ABS")
            fi
            ;;
    esac

    # 6. 从 EXCLUDES 中剔除 .git/ 相关排除规则
    #    handoff 的核心设计是"同步完整工作现场，含 .git/"，而用户配置的
    #    EXCLUDES_COMMON 通常包含 --exclude=.git/，会静默违反该承诺
    local filtered=()
    local rule stripped
    for rule in "${EXCLUDES[@]}"; do
        # 取出 --exclude= 之后的 pattern 部分，去掉外层的单双引号（若有）
        stripped="${rule#--exclude=}"
        stripped="${stripped#\'}"; stripped="${stripped%\'}"
        stripped="${stripped#\"}"; stripped="${stripped%\"}"
        # 匹配 .git, .git/, .git/* (含 **) 等所有以 .git/ 或 .git 开头的变体
        case "$stripped" in
            .git|.git/|.git/*) continue ;;
        esac
        filtered+=("$rule")
    done
    EXCLUDES=("${filtered[@]}")

    # 7. 注入 handoff 默认规则（除非用户用了 INCLUDE_ONLY）
    if [[ -z "${INCLUDE_ONLY[*]:-}" ]]; then
        HANDOFF_EXTRA_OPTS+=(
            "--filter=:- .gitignore"
            "--filter=:- .git/info/exclude"
        )
    fi

    # 8. 输出决策摘要
    echo "判定结果: $STATUS"
    echo "原因: $REASON"
    echo "目标: $REMOTE_TARGET"
    # 仅在 fork 到新槽位时提示 ssh 命令（新路径含自动生成的后缀，用户需要知道）
    if [[ "$STATUS" == "dirty" || "$STATUS" == "diverged" ]]; then
        echo "下一步: ssh $REMOTE_HOST && cd ${REMOTE_TARGET#*:}"
    fi
    echo "========================"
    echo
}

# 写入 handoff marker（在远端目标目录写 .sync_handoff_mark）
# 目的：记录本次 handoff 后远端的 git 状态指纹，供下次 handoff 判定"远端是否自上次后未被改动"
write_handoff_marker() {
    local FP
    FP=$(git_fingerprint)
    if [[ -z "$FP" ]]; then
        return 0  # 非 git 仓库，跳过
    fi

    local TS LOCAL_HOST_NAME LOCAL_ABS
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    LOCAL_HOST_NAME=$(hostname)
    LOCAL_ABS="$LOCAL_PATH"

    local REMOTE_DIR="${REMOTE_TARGET#*:}"
    build_ssh_cmd
    $SSH_CMD "$REMOTE_HOST" bash -s -- "$REMOTE_DIR" "$FP" "$TS" "$LOCAL_HOST_NAME" "$LOCAL_ABS" <<'WRITE_MARKER' || echo "警告: marker 写入失败（不影响本次 handoff）"
set -u
TARGET="$1"
case "$TARGET" in
    "~")   TARGET="$HOME" ;;
    "~/"*) TARGET="$HOME/${TARGET#~/}" ;;
esac
cat > "$TARGET/.sync_handoff_mark" <<EOF
fingerprint=$2
timestamp=$3
local_host=$4
local_path=$5
EOF
WRITE_MARKER
}

# 执行同步
perform_sync() {
    # 基本 rsync 参数
    RSYNC_OPTS=(--archive --partial --progress)
    
    # EXCLUDES 数组已经在 merge_excludes() 中合并好了（预定义 + 自定义）
    
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
        handoff)
            # REMOTE_TARGET 已由 prepare_handoff() 决定（原位或 fork 槽位）
            SOURCE="$LOCAL_PATH/"
            DEST="$REMOTE_TARGET"
            echo "模式: Handoff 接力推送 (不删除远程文件)"
            ;;
    esac
    
    # 预览模式
    if [ "$DRY_RUN" = true ]; then
        RSYNC_OPTS+=(--dry-run)
        echo "--- 预览模式 ---"
    fi
    
    # 配置 SSH 选项（端口和密钥）
    build_ssh_cmd
    if [ "$SSH_OPTS_CHANGED" = true ]; then
        RSYNC_OPTS+=(-e "$SSH_CMD")
        [[ "$REMOTE_PORT" != "22" ]] && echo "SSH 端口: $REMOTE_PORT"
        [[ -n "$SSH_IDENTITY_FILE" ]] && echo "SSH 密钥: $SSH_IDENTITY_FILE"
    fi

    echo "本地路径: $LOCAL_PATH"
    echo "远程路径: $REMOTE_TARGET"
    echo "源: $SOURCE"
    echo "目标: $DEST"
    echo

    # 执行 rsync（HANDOFF_EXTRA_OPTS 由 prepare_handoff 填充，如 --filter、--link-dest）
    rsync "${RSYNC_OPTS[@]}" "${HANDOFF_EXTRA_OPTS[@]}" "${EXCLUDES[@]}" "$SOURCE" "$DEST"
    
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
    load_config      # 加载配置文件（用户配置 → 项目配置）
    init_vars        # 基于配置初始化工作变量
    merge_excludes   # 合并排除规则
    parse_args "$@"  # 解析命令行参数（可覆盖配置）
    validate_config  # 校验必需配置项（DEFAULT_REMOTE_HOST）
    validate_mode    # 验证同步模式
    detect_paths     # 检测路径
    if [[ "$MODE" == "handoff" ]]; then
        prepare_handoff  # 检查远端、决定原位或 fork、注入 handoff 规则
    fi
    perform_sync     # 执行同步
    if [[ "$MODE" == "handoff" && "$DRY_RUN" != "true" ]]; then
        write_handoff_marker  # 写入 marker，供下次 handoff 判定远端状态是否改动
    fi
}

main "$@"
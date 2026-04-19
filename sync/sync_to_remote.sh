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
    HANDOFF_START_FP=""
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
                          reclaim:   归队：从远端把 handoff 出去的现场拉回本地
                                     (按 marker 找回 fork 槽位；校验本地自 handoff
                                     起未被改动，否则拒绝覆盖)

    -H, --host HOST        远程 SSH host，例如 myserver 或 user@host
                          (默认: 配置文件中的 DEFAULT_REMOTE_HOST)
    -p, --port PORT        SSH 端口 (默认: 配置文件中的 DEFAULT_REMOTE_PORT，通常是 22)
    -n, --dry-run          预览模式，不实际执行
        --suffix SUFFIX    handoff 模式 fork 槽位时的后缀名（默认: 时间戳）
    -f, --force            handoff/reclaim 模式跳过所有安全检查，强制覆盖（慎用）
    -h, --help             显示此帮助信息

示例:
    $0                     # 默认: 本地覆盖远程
    $0 -m pull             # 远程覆盖本地
    $0 -m copy-push        # 本地复制到远程，不删除
    $0 -m handoff          # 接力现场到远程（自动判断原位或 fork）
    $0 -m reclaim          # 从远端归队（自动找 fork 槽位，刷新 pairing marker）
    $0 -H myserver -m handoff  # 临时指定远程 SSH host
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
            -H|--host)
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

# 校验必需配置项（在 parse_args 之后执行，命令行 -H/--host 也可满足校验）
validate_config() {
    if [[ -z "$REMOTE_HOST" ]]; then
        echo "错误: 未配置远程服务器地址 (DEFAULT_REMOTE_HOST)"
        echo ""
        echo "请在以下任一配置文件中设置:"
        echo "  - 用户级配置: $HOME/.config/sync_to_remote/config"
        echo "  - 项目级配置: ./.sync_config"
        echo ""
        echo "或通过命令行参数指定: $0 -H user@host"
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
        push|pull|copy-push|copy-pull|handoff|reclaim)
            ;;
        *)
            echo "错误: 无效的同步模式 '$MODE'"
            echo "支持的模式: push, pull, copy-push, copy-pull, handoff, reclaim"
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

    # 1. 采集本地 git 状态；FP 在 rsync 前定格，避免"rsync 期间本地被编辑，marker 捕获的 FP
    #    与真正发出去的 payload 不符"——marker 是 reclaim 安全校验的锚点，必须对应实际 rsync 内容
    local LOCAL_HEAD=""
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        LOCAL_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
    fi
    HANDOFF_START_FP="$(git_fingerprint)"

    # 2. 解析远端 canonical 路径（tilde 在远端 shell 展开）
    local CANONICAL_REMOTE_PATH="$DEFAULT_REMOTE_BASE$RELATIVE_PATH"

    # 3. SSH 到远端采集状态（只采集，不判定）
    build_ssh_cmd
    echo "检查远端状态: $REMOTE_HOST:$CANONICAL_REMOTE_PATH"

    # 注意：不要写成 REMOTE_STATUS=$(ssh ... <<'EOF' ... EOF)。
    # macOS 自带 bash 3.2 在 $() 命令替换里嵌套 here-doc 有 parser bug，
    # 会把 heredoc 正文"漏"到外层解析，遇到 ;; 等 token 直接报语法错。
    # 所以先用 read -r -d '' 把脚本收进变量（此时 heredoc 不在 $() 内），
    # 再 pipe 给 ssh。bash 3.2 / 4 / 5 都能跑。
    local PROBE_SCRIPT
    IFS='' read -r -d '' PROBE_SCRIPT <<'REMOTE_PROBE' || true
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

    local REMOTE_STATUS
    REMOTE_STATUS=$(printf '%s' "$PROBE_SCRIPT" | \
        $SSH_CMD "$REMOTE_HOST" bash -s -- "$CANONICAL_REMOTE_PATH")

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

    # 7. 始终排除 pairing marker（放在 .gitignore filter 前面，rsync first-match 语义下必定先中）
    HANDOFF_EXTRA_OPTS+=(
        "--exclude=.sync_reclaim_mark"
        "--exclude=.sync_handoff_mark"
    )

    # 8. 注入 handoff 默认规则（除非用户用了 INCLUDE_ONLY）
    if [[ -z "${INCLUDE_ONLY[*]:-}" ]]; then
        HANDOFF_EXTRA_OPTS+=(
            "--filter=:- .gitignore"
            "--filter=:- .git/info/exclude"
        )
    fi

    # 9. 输出决策摘要
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

# 写入配对 marker（handoff 和 reclaim 共用，代表"这一刻两端同步到了同一 FP"）：
#   - 远端 $REMOTE_DIR/.sync_handoff_mark：记录 FP，供下次 handoff/reclaim 判定对齐
#   - 本地 $LOCAL_PATH/.sync_reclaim_mark：记录远端路径绑定，供下次 reclaim 路由
#     （handoff 可能 fork 到新槽位，canonical 路径不够用）
# 参数 $1: mode 标签，写入 local marker 的 mode= 字段；默认 "handoff"
write_handoff_marker() {
    local MODE_LABEL="${1:-handoff}"
    # handoff 路径：用 prepare_handoff 在 rsync 前定格的 FP，避免 rsync 期间本地被改
    # reclaim 路径：HANDOFF_START_FP 为空，回退到即时计算——此刻本地刚被 rsync 覆盖，
    #              FP 等于远端刚发过来的 FP，正是"新的同步点"
    local FP="${HANDOFF_START_FP:-}"
    if [[ -z "$FP" ]]; then
        FP=$(git_fingerprint)
    fi
    if [[ -z "$FP" ]]; then
        return 0  # 非 git 仓库，跳过
    fi

    # reclaim 特检：rsync 不带 --delete。若远端删除/重命名了 tracked 文件，
    # 本地旧文件仍在 → 本地 FP 与远端 FP 不符，marker 写下去会误导下次 handoff。
    # 对策：重新 SSH 探一次远端 FP 做 sanity check；不一致则 loud 警告并跳过 marker 刷新，
    # 下次 handoff 走标准（dirty/diverged）判定，fail-safe。
    if [[ "$MODE_LABEL" == "reclaim" ]]; then
        local REMOTE_DIR_VERIFY="${REMOTE_TARGET#*:}"
        build_ssh_cmd
        local VERIFY_SCRIPT REMOTE_FP=""
        IFS='' read -r -d '' VERIFY_SCRIPT <<'VERIFY_FP' || true
set -u
TARGET="$1"
case "$TARGET" in
    "~")   TARGET="$HOME" ;;
    "~/"*) TARGET="$HOME/${TARGET#~/}" ;;
esac
cd "$TARGET" 2>/dev/null || { echo "REMOTE_FP:"; exit 0; }
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "REMOTE_FP:"
    exit 0
fi
RFP=$({
    git rev-parse HEAD 2>/dev/null || echo "NO-HEAD"
    git diff HEAD 2>/dev/null
    echo "---CACHED---"
    git diff --cached 2>/dev/null
} | sha256sum | awk '{print $1}')
echo "REMOTE_FP:$RFP"
VERIFY_FP
        local VRES
        VRES=$(printf '%s' "$VERIFY_SCRIPT" | \
            $SSH_CMD "$REMOTE_HOST" bash -s -- "$REMOTE_DIR_VERIFY" 2>/dev/null)
        while IFS= read -r line; do
            case "$line" in
                REMOTE_FP:*) REMOTE_FP="${line#REMOTE_FP:}" ;;
            esac
        done <<< "$VRES"
        if [[ -n "$REMOTE_FP" && "$REMOTE_FP" != "$FP" ]]; then
            echo "警告: reclaim 后本地 FP 与远端不一致，跳过 marker 刷新"
            echo "       本地 FP: $FP"
            echo "       远端 FP: $REMOTE_FP"
            echo "       可能原因: 远端删除/重命名了 tracked 文件，但 rsync 无 --delete 未同步到本地"
            echo "       建议: git status 确认本地残留；或手动 rm 这些文件；然后重跑 reclaim"
            echo "       下次 handoff 会走标准 dirty/diverged 判定（可能 fork 新槽位，fail-safe）"
            return 0
        fi
    fi

    local TS LOCAL_HOST_NAME LOCAL_ABS
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    LOCAL_HOST_NAME=$(hostname)
    LOCAL_ABS="$LOCAL_PATH"

    local REMOTE_DIR="${REMOTE_TARGET#*:}"
    build_ssh_cmd
    $SSH_CMD "$REMOTE_HOST" bash -s -- "$REMOTE_DIR" "$FP" "$TS" "$LOCAL_HOST_NAME" "$LOCAL_ABS" <<'WRITE_MARKER' || echo "警告: 远端 marker 写入失败（不影响本次同步）"
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

    # 本地 reclaim marker：下次 reclaim 据此回程到正确的远端路径
    cat > "$LOCAL_PATH/.sync_reclaim_mark" <<LOCAL_MARKER || echo "警告: 本地 reclaim marker 写入失败（不影响本次同步）"
remote_host=$REMOTE_HOST
remote_path=$REMOTE_DIR
timestamp=$TS
mode=$MODE_LABEL
LOCAL_MARKER
}

# Reclaim 归队：把 handoff 出去的现场拉回本地
# 契约（用户声明）：reclaim 仅在本地无进行中工作时调用，故无本地冲突检查、无 fork。
# 唯一实际问题：handoff 若 fork 到槽位，canonical 路径不够用 —— 靠
# $LOCAL_PATH/.sync_reclaim_mark 记录的绑定路径回程。
prepare_reclaim() {
    echo "=== Reclaim 归队模式 ==="

    local CANONICAL_REMOTE_PATH="$DEFAULT_REMOTE_BASE$RELATIVE_PATH"
    local RECLAIM_SOURCE_PATH="$CANONICAL_REMOTE_PATH"
    local REASON="使用 canonical 路径（未找到 reclaim marker）"

    # 1. 读本地 marker（仅在 host 匹配时采纳其路径）
    local LOCAL_MARK="$LOCAL_PATH/.sync_reclaim_mark"
    if [[ -f "$LOCAL_MARK" ]]; then
        local MARK_HOST MARK_PATH
        MARK_HOST=$(grep '^remote_host=' "$LOCAL_MARK" 2>/dev/null | head -n1 | cut -d= -f2-)
        MARK_PATH=$(grep '^remote_path=' "$LOCAL_MARK" 2>/dev/null | head -n1 | cut -d= -f2-)
        if [[ -n "$MARK_HOST" && -n "$MARK_PATH" ]]; then
            if [[ "$MARK_HOST" == "$REMOTE_HOST" ]]; then
                RECLAIM_SOURCE_PATH="$MARK_PATH"
                REASON="从 .sync_reclaim_mark 读取到绑定路径"
            else
                REASON="marker 的 host=$MARK_HOST 与当前 -H $REMOTE_HOST 不匹配，改用 canonical 路径"
            fi
        fi
    fi

    # 2. SSH 探测：路径存在性 + 读取远端 marker 的 fingerprint（= handoff 时的本地 FP）
    #    使用 read -d '' 变量 + 管道，绕开 bash 3.2 在 $() 内嵌 heredoc 的 parser bug
    build_ssh_cmd
    echo "检查远端路径: $REMOTE_HOST:$RECLAIM_SOURCE_PATH"
    local PROBE_SCRIPT
    IFS='' read -r -d '' PROBE_SCRIPT <<'RECLAIM_PROBE' || true
set -u
TARGET="$1"
case "$TARGET" in
    "~")   TARGET="$HOME" ;;
    "~/"*) TARGET="$HOME/${TARGET#~/}" ;;
esac
if [[ ! -d "$TARGET" ]]; then
    echo "EXISTS:false"
    echo "ABS_PATH:$TARGET"
    echo "MARKER_FP:"
    exit 0
fi
ABS=$(cd "$TARGET" 2>/dev/null && pwd)
echo "EXISTS:true"
echo "ABS_PATH:$ABS"
MFP=""
if [[ -f "$TARGET/.sync_handoff_mark" ]]; then
    MFP=$(grep '^fingerprint=' "$TARGET/.sync_handoff_mark" 2>/dev/null | head -n1 | cut -d= -f2-)
fi
echo "MARKER_FP:$MFP"
RECLAIM_PROBE

    local PROBE_RESULT
    PROBE_RESULT=$(printf '%s' "$PROBE_SCRIPT" | \
        $SSH_CMD "$REMOTE_HOST" bash -s -- "$RECLAIM_SOURCE_PATH")

    if [[ -z "$PROBE_RESULT" ]]; then
        echo "错误: 无法连接远端或采集状态失败"
        exit 1
    fi

    local REMOTE_EXISTS="" REMOTE_ABS="" REMOTE_MARKER_FP=""
    while IFS= read -r line; do
        case "$line" in
            EXISTS:*)    REMOTE_EXISTS="${line#EXISTS:}" ;;
            ABS_PATH:*)  REMOTE_ABS="${line#ABS_PATH:}" ;;
            MARKER_FP:*) REMOTE_MARKER_FP="${line#MARKER_FP:}" ;;
        esac
    done <<< "$PROBE_RESULT"

    if [[ "$REMOTE_EXISTS" != "true" ]]; then
        echo "错误: 远端路径不存在: $REMOTE_HOST:$REMOTE_ABS"
        echo "       （可能从未 handoff 过，或 marker 指向的 fork 槽位已删除）"
        exit 1
    fi

    # 3. 本地安全校验：当前本地 FP 必须等于远端 marker 里记录的"handoff 时本地 FP"
    #    匹配 → 本地自 handoff 以来未被改动，覆盖安全
    #    不匹配 → 本地可能有新的更改，拒绝覆盖，除非 -f 兜底
    local LOCAL_FP
    LOCAL_FP=$(git_fingerprint)

    if [[ "$HANDOFF_FORCE" != "true" ]]; then
        if [[ -z "$LOCAL_FP" ]]; then
            echo "错误: 本地不是 git 仓库，无法校验是否有新改动"
            echo "       若确认覆盖安全，加 -f/--force 强制执行"
            exit 1
        fi
        if [[ -z "$REMOTE_MARKER_FP" ]]; then
            echo "错误: 远端未找到 .sync_handoff_mark（或 fingerprint 字段缺失），无从校验本地状态"
            echo "       可能从未 handoff 过此目录，或 marker 已被删除"
            echo "       若确认覆盖安全，加 -f/--force 强制执行"
            exit 1
        fi
        if [[ "$LOCAL_FP" != "$REMOTE_MARKER_FP" ]]; then
            echo "错误: 本地 git 状态已偏离 handoff 时的状态（本地可能有新改动），拒绝覆盖"
            echo "       本地当前 FP: $LOCAL_FP"
            echo "       marker 记录: $REMOTE_MARKER_FP"
            echo "       建议: 查看 git status / git diff；然后 stash / commit / checkout -- . / 手动比对；或加 -f/--force 强制执行"
            exit 1
        fi
        echo "本地校验: FP 与 marker 匹配，本地自 handoff 以来未被改动 ✓"
    else
        echo "提示: -f/--force 已启用，跳过本地状态校验"
    fi

    # 4. 敲定 REMOTE_TARGET 供 perform_sync 使用
    REMOTE_TARGET="$REMOTE_HOST:$RECLAIM_SOURCE_PATH"

    if [[ -n "$HANDOFF_SLOT_SUFFIX" ]]; then
        echo "提示: --suffix 在 reclaim 模式下无作用（已忽略）"
    fi

    # 5. 两端的 marker 都不互相串台（handoff_mark 只该存在远端，reclaim_mark 只该存在本地）
    HANDOFF_EXTRA_OPTS+=(
        "--exclude=.sync_handoff_mark"
        "--exclude=.sync_reclaim_mark"
    )

    # 6. 复用 handoff 的"完整工作现场"语义：剔除 .git/ 排除 + 注入 gitignore 过滤
    local filtered=()
    local rule stripped
    for rule in "${EXCLUDES[@]}"; do
        stripped="${rule#--exclude=}"
        stripped="${stripped#\'}"; stripped="${stripped%\'}"
        stripped="${stripped#\"}"; stripped="${stripped%\"}"
        case "$stripped" in
            .git|.git/|.git/*) continue ;;
        esac
        filtered+=("$rule")
    done
    EXCLUDES=("${filtered[@]}")

    if [[ -z "${INCLUDE_ONLY[*]:-}" ]]; then
        HANDOFF_EXTRA_OPTS+=(
            "--filter=:- .gitignore"
            "--filter=:- .git/info/exclude"
        )
    fi

    echo "源: $REMOTE_HOST:$RECLAIM_SOURCE_PATH (绝对: $REMOTE_ABS)"
    echo "目标: $LOCAL_PATH"
    echo "原因: $REASON"
    echo "========================"
    echo
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
        reclaim)
            # REMOTE_TARGET 已由 prepare_reclaim() 决定（canonical 或 marker 指向的槽位）
            SOURCE="$REMOTE_TARGET/"
            DEST="$LOCAL_PATH"
            echo "模式: Reclaim 归队 (不删除本地文件)"
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
    elif [[ "$MODE" == "reclaim" ]]; then
        prepare_reclaim  # 解析远端源路径（canonical 或 marker），探测存在性
    fi
    perform_sync     # 执行同步
    if [[ "$MODE" == "handoff" && "$DRY_RUN" != "true" ]]; then
        write_handoff_marker handoff  # 刷新两端 marker 到本次 handoff 的同步点
    elif [[ "$MODE" == "reclaim" && "$DRY_RUN" != "true" ]]; then
        write_handoff_marker reclaim  # 刷新两端 marker 到本次 reclaim 的同步点
    fi
}

main "$@"

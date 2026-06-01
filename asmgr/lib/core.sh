# lib/core.sh — 常量、路径派生与通用 helper
#   依赖检查 / 中央路径常量 / 路径规范化 / agent 目录映射 / print_* / prompt / 时间戳 / yaml 数组 / agent 去重
#   （由入口 asmgr.sh 最先 source，其余 lib 与命令层共用）

# 检查必需的依赖工具
check_dependencies() {
    local missing=()

    # 检查 yq
    if ! command -v yq &>/dev/null; then
        missing+=("yq")
    fi

    # 检查 git
    if ! command -v git &>/dev/null; then
        missing+=("git")
    fi

    # 检查 jq（仅 plugin/marketplace 子命令需要，但统一在启动时提示）
    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "缺少必需的依赖工具: ${missing[*]}"
        echo
        echo "请安装缺失的工具："
        echo

        for tool in "${missing[@]}"; do
            case "$tool" in
                yq)
                    echo "  yq - YAML 处理工具"
                    echo "    macOS:   brew install yq"
                    echo "    Linux:   参见 https://github.com/mikefarah/yq#install"
                    echo "    官方仓库: https://github.com/mikefarah/yq"
                    echo
                    ;;
                git)
                    echo "  git - 版本控制工具"
                    echo "    macOS:   brew install git"
                    echo "    Linux:   sudo apt-get install git 或 sudo yum install git"
                    echo
                    ;;
                jq)
                    echo "  jq - JSON 处理工具（plugin/marketplace 子命令需要）"
                    echo "    macOS:   brew install jq"
                    echo "    Linux:   sudo apt-get install jq 或 sudo yum install jq"
                    echo
                    ;;
            esac
        done

        return 1
    fi

    return 0
}

# 中央 skills 存储目录
SKILLS_DIR="$HOME/agent-settings/skills"

# Skills 配置文件
SKILLS_YAML="$SKILLS_DIR/skills.yaml"

# agent-settings 根目录（中央 skills 目录的父目录），用于现场推导中央路径
AGENT_SETTINGS_ROOT="$(dirname "$SKILLS_DIR")"
# 中央 subagents 存储目录
AGENTS_DIR="$AGENT_SETTINGS_ROOT/agents"
# 项目级清单目录（每项目一个 <name>.yaml）
PROJECTS_DIR="$AGENT_SETTINGS_ROOT/projects"

# 规范化 base 目录路径
# 展开 ~ 并转换相对路径为绝对路径
normalize_base_dir() {
    local path="$1"

    # 展开波浪号
    path="${path/#\~/$HOME}"

    # 处理相对路径
    if [[ "$path" == ./* || "$path" == ../* || "$path" == "." ]]; then
        # 转换为绝对路径
        if [[ -d "$path" ]]; then
            path=$(cd "$path" && pwd)
        else
            # 目录不存在，尝试规范化
            local dir=$(dirname "$path")
            local base=$(basename "$path")
            if [[ -d "$dir" ]]; then
                path=$(cd "$dir" && pwd)/"$base"
            else
                path="$(/bin/pwd)/${path#./}"
            fi
        fi
    fi

    # 移除末尾斜杠
    path="${path%/}"

    echo "$path"
}

# 获取 agent 目录的函数
# 参数:
#   $1 - agent 名称 (cursor, claude-code, codex, gemini)
#   $2 - base 目录 (可选，默认为 $HOME)
get_agent_dir() {
    local agent="$1"
    local base_dir="${2:-$HOME}"

    case "$agent" in
        cursor)
            echo "$base_dir/.cursor/skills"
            ;;
        claude-code)
            echo "$base_dir/.claude/skills"
            ;;
        codex)
            echo "$base_dir/.codex/skills"
            ;;
        gemini)
            echo "$base_dir/.gemini/skills"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# 获取 subagent 目标目录（subagent 是 Claude Code 概念，固定 .claude/agents）
# 参数: $1 - base 目录（可选，默认 $HOME）
get_subagent_target_dir() {
    local base_dir="${1:-$HOME}"
    echo "$base_dir/.claude/agents"
}

# 把 scope 旗标解析成 base 目录（add/remove 共用，消除三处镜像）：
#   -g → $HOME；-p <dir> → 规范化并校验存在；默认 → 当前目录。
# 结果写入全局 RESOLVED_BASE_DIR（沿用本仓库 _merged_agents 式的输出变量约定，
# 因为 print_error 走 stdout、无法用命令替换回传）。-g/-p 互斥或 -p 目录不存在则报错返回 1。
# 用法: resolve_base_dir <is_global:true|false> <project_dir>; base_dir="$RESOLVED_BASE_DIR"
resolve_base_dir() {
    local is_global="$1" project_dir="$2"
    RESOLVED_BASE_DIR=""
    if [[ "$is_global" == true && -n "$project_dir" ]]; then
        print_error "-g 和 -p 参数不能同时使用"
        return 1
    fi
    if [[ "$is_global" == true ]]; then
        RESOLVED_BASE_DIR="$HOME"
    elif [[ -n "$project_dir" ]]; then
        RESOLVED_BASE_DIR=$(normalize_base_dir "$project_dir")
        if [[ ! -d "$RESOLVED_BASE_DIR" ]]; then
            print_error "项目目录不存在: $RESOLVED_BASE_DIR"
            return 1
        fi
    else
        RESOLVED_BASE_DIR="$(/bin/pwd)"
    fi
    return 0
}

# 校验 -p/--project 的实参：必须存在且不是另一个选项（不以 - 开头）。缺失则报错返回 1。
# 用法: require_project_dir_arg "$2" || return 1
require_project_dir_arg() {
    if [[ -z "$1" || "$1" =~ ^- ]]; then
        print_error "-p 参数需要指定项目目录"
        return 1
    fi
    return 0
}

# 支持的 agents 列表
SUPPORTED_AGENTS="cursor claude-code codex gemini"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印函数
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 无项目清单（空状态=WARN）。canonical 文案只此一处。
# 用法: warn_no_manifest "$manifest_path"
warn_no_manifest() {
    print_warn "无项目清单: $1"
}

# 引导用户切换 scope 的提示（INFO 级）。canonical 文案只此一处。
hint_other_scopes() {
    print_info "提示: 试试 -g（全局）或 --all（全局 + 所有项目）"
}

# 统一完成消息（INFO 级，无叹号）。用法: info_done <动作> [对象]
#   info_done "添加" "skill-x"  -> [INFO] 添加完成: skill-x
#   info_done "同步"            -> [INFO] 同步完成
info_done() {
    if [[ -n "${2:-}" ]]; then
        print_info "$1完成: $2"
    else
        print_info "$1完成"
    fi
}

# 统一 status 详情标签行（区别于 [INFO]/[WARN]/[ERROR] 日志级别，这是检查结果分类）。
# 用法: print_status_tag <OK|MISSING|WRONG|ORPHAN> "<msg>" ["<indent>"]
print_status_tag() {
    local tag="$1" msg="$2" indent="${3:-}"
    local color
    case "$tag" in
        OK)            color="$GREEN" ;;
        MISSING)       color="$RED" ;;
        WRONG|ORPHAN)  color="$YELLOW" ;;
        *)             color="$NC" ;;
    esac
    echo -e "${indent}${color}[${tag}]${NC} ${msg}"
}

# 通用 y/N 提示（需按回车确认；支持 y/yes, n/no；空输入走默认值）
# 用法: if prompt_yes_no "是否继续? (y/N) " "N"; then ...; fi
prompt_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local reply=""

    while true; do
        reply=""
        read -r -p "$prompt" reply

        # trim spaces
        reply="${reply#"${reply%%[![:space:]]*}"}"
        reply="${reply%"${reply##*[![:space:]]}"}"

        if [[ -z "$reply" ]]; then
            reply="$default"
        fi

        case "$reply" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "请输入 y 或 n，然后按回车确认。" ;;
        esac
    done
}

# 本地时间戳（ISO 8601 + 时区偏移，如 2026-02-03T23:22:36+08:00）
now_timestamp_local() {
    local base tz
    base=$(/bin/date +"%Y-%m-%dT%H:%M:%S")
    tz=$(/bin/date +"%z") # e.g. +0800
    echo "${base}${tz:0:3}:${tz:3:2}"
}

# 构建 yq 需要的数组字符串
build_yaml_array() {
    local items=("$@")
    local yaml="["
    local i
    for i in "${!items[@]}"; do
        [[ $i -gt 0 ]] && yaml+=", "
        yaml+="\"${items[$i]}\""
    done
    yaml+="]"
    echo "$yaml"
}

# 合并去重 agents（结果写入全局数组 _merged_agents）
merge_unique_agents() {
    _merged_agents=()
    local agent existing found
    for agent in "$@"; do
        found=0
        for existing in "${_merged_agents[@]}"; do
            if [[ "$existing" == "$agent" ]]; then
                found=1
                break
            fi
        done
        [[ $found -eq 0 ]] && _merged_agents+=("$agent")
    done
}

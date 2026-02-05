#!/bin/bash

# Skill Manager - 管理 AI Agent Skills 的命令行工具
# 支持从 GitHub 或本地路径添加 skills 到中央仓库，并可选地创建符号链接到各 AI agent

# 确保 PATH 包含标准命令路径（避免用户环境 PATH 缺失导致的 command not found）
# 同时包含 Homebrew 默认路径（Apple Silicon: /opt/homebrew/bin）。
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

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

# 初始化 skills.yaml 文件
init_skills_yaml() {
    if [[ ! -f "$SKILLS_YAML" ]]; then
        /bin/mkdir -p "$SKILLS_DIR"
        cat > "$SKILLS_YAML" << 'EOF'
# Skill installation registry
# Auto-managed by skill-mgr, can be manually edited

version: 1

skills: {}
EOF
    fi
}

## 注意：不做旧格式（installations）兼容；仅把旧字段 `agents` 视为 `agents_link` 的别名读取。

# 根据安装方式映射 agents 字段名
agents_field_for_method() {
    local method="${1:-link}"
    if [[ "$method" == "copy" ]]; then
        echo "agents_copy"
    else
        echo "agents_link"
    fi
}

get_skill_agents_field() {
    local skill_name="$1"
    local field="$2"
    [[ ! -f "$SKILLS_YAML" ]] && return 1
    yq -r ".skills.\"$skill_name\".$field // [] | .[]" "$SKILLS_YAML" 2>/dev/null
}

# 从 base 中移除 remove 列表中的 agents（结果写入全局数组 _filtered_agents）
filter_out_agents() {
    _filtered_agents=()

    local base=()
    local remove=()
    local removing=0
    local item
    for item in "$@"; do
        if [[ "$item" == "--remove" ]]; then
            removing=1
            continue
        fi
        if [[ $removing -eq 0 ]]; then
            base+=("$item")
        else
            remove+=("$item")
        fi
    done

    local agent r found
    for agent in "${base[@]}"; do
        found=0
        for r in "${remove[@]}"; do
            if [[ "$agent" == "$r" ]]; then
                found=1
                break
            fi
        done
        [[ $found -eq 0 ]] && _filtered_agents+=("$agent")
    done
}

# 更新 skills.yaml 配置文件
# 用法: update_skills_yaml <skill_name> <source> <touch_added_at:0|1> <method:link|copy> <agent1> [agent2] ...
update_skills_yaml() {
    local skill_name="$1"
    local source="$2"
    local touch_added_at="${3:-1}"
    local method="${4:-link}"
    shift 4
    local agents=("$@")

    init_skills_yaml

    local timestamp
    timestamp=$(now_timestamp_local)

    local exists=0
    local current_source=""
    local current_added_at=""

    if yq -e ".skills.\"$skill_name\"" "$SKILLS_YAML" &>/dev/null; then
        exists=1
        current_source=$(yq -r ".skills.\"$skill_name\".source // \"\"" "$SKILLS_YAML" 2>/dev/null)
        current_added_at=$(yq -r ".skills.\"$skill_name\".added_at // \"\"" "$SKILLS_YAML" 2>/dev/null)
    fi

    # source：传入 unknown 表示“不改现有 source”；如果是新建记录则写入 unknown。
    local final_source=""
    if [[ $exists -eq 1 ]]; then
        final_source="$current_source"
        if [[ -n "$source" && "$source" != "unknown" && ( -z "$final_source" || "$final_source" == "unknown" ) ]]; then
            final_source="$source"
        fi
    else
        final_source="$source"
    fi

    # added_at
    local final_added_at="$current_added_at"
    if [[ $exists -eq 0 || "$touch_added_at" == "1" || -z "$final_added_at" ]]; then
        final_added_at="$timestamp"
    fi

    # 读取现有 link/copy 列表
    local existing_link=()
    local existing_copy=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && existing_link+=("$line")
    done <<< "$(get_skill_agents_link "$skill_name")"
    while IFS= read -r line; do
        [[ -n "$line" ]] && existing_copy+=("$line")
    done <<< "$(get_skill_agents_field "$skill_name" "agents_copy")"

    local new_link=()
    local new_copy=()
    if [[ "$method" == "copy" ]]; then
        merge_unique_agents "${existing_copy[@]}" "${agents[@]}"
        new_copy=("${_merged_agents[@]}")
        filter_out_agents "${existing_link[@]}" --remove "${agents[@]}"
        new_link=("${_filtered_agents[@]}")
    else
        merge_unique_agents "${existing_link[@]}" "${agents[@]}"
        new_link=("${_merged_agents[@]}")
        filter_out_agents "${existing_copy[@]}" --remove "${agents[@]}"
        new_copy=("${_filtered_agents[@]}")
    fi

    local link_yaml copy_yaml
    link_yaml=$(build_yaml_array "${new_link[@]}")
    copy_yaml=$(build_yaml_array "${new_copy[@]}")

    # 整块重写，保证字段顺序：agents_link、agents_copy、source、added_at
    yq -i ".skills.\"$skill_name\" = {\"agents_link\": $link_yaml, \"agents_copy\": $copy_yaml, \"source\": \"$final_source\", \"added_at\": \"$final_added_at\"}" "$SKILLS_YAML"
}

# 从 skills.yaml 读取 skill 的 link/copy agents 列表
get_skill_agents_link() {
    local skill_name="$1"
    [[ ! -f "$SKILLS_YAML" ]] && return 1
    yq -r ".skills.\"$skill_name\".agents_link // .skills.\"$skill_name\".agents // [] | .[]" "$SKILLS_YAML" 2>/dev/null
}

get_skill_agents_copy() {
    local skill_name="$1"
    get_skill_agents_field "$skill_name" "agents_copy"
}

has_agent_in_list() {
    local agent="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$agent" ]]; then
            return 0
        fi
    done
    return 1
}

remove_agent_from_skill_field() {
    local skill_name="$1"
    local field="$2"
    local agent="$3"
    [[ ! -f "$SKILLS_YAML" ]] && return 1

    yq -i ".skills.\"$skill_name\".$field -= [\"$agent\"]" "$SKILLS_YAML"
}

remove_skill_if_empty() {
    local skill_name="$1"
    [[ ! -f "$SKILLS_YAML" ]] && return 0
    local remaining_link remaining_copy
    remaining_link=$(yq -r "(.skills.\"$skill_name\".agents_link // .skills.\"$skill_name\".agents // []) | length" "$SKILLS_YAML" 2>/dev/null)
    remaining_copy=$(yq -r ".skills.\"$skill_name\".agents_copy | length" "$SKILLS_YAML" 2>/dev/null)
    if [[ "${remaining_link:-0}" == "0" && "${remaining_copy:-0}" == "0" ]]; then
        yq -i "del(.skills.\"$skill_name\")" "$SKILLS_YAML"
    fi
}

# 从 skills.yaml 获取所有 skills
get_all_skills() {
    [[ ! -f "$SKILLS_YAML" ]] && return 1
    yq -r '.skills | keys | .[]' "$SKILLS_YAML" 2>/dev/null
}

# 从 skills.yaml 移除 skill 的 link agent
remove_agent_from_skill() {
    local skill_name="$1"
    local agent="$2"
    [[ ! -f "$SKILLS_YAML" ]] && return 1

    # 移除指定 agent
    remove_agent_from_skill_field "$skill_name" "agents_link" "$agent"
    remove_agent_from_skill_field "$skill_name" "agents" "$agent"
    remove_skill_if_empty "$skill_name"
}

# 从 skills.yaml 完全移除 skill 记录
remove_skill_from_yaml() {
    local skill_name="$1"
    [[ ! -f "$SKILLS_YAML" ]] && return 0
    yq -i "del(.skills.\"$skill_name\")" "$SKILLS_YAML"
}

# 显示帮助信息
show_help() {
    cat << EOF
Skill Manager - 管理 AI Agent Skills 的命令行工具

用法:
    skill-mgr <command> [options]

命令:
    add <source> [-a <agents...>] [-g|-p <dir>] [-c]  添加 skill 到中央目录并可选链接到 agents
    list                                          列出所有已注册的 skills 及其全局安装状态
    status [--fix]                                检查配置与实际全局链接/复制的一致性
    sync --from-agents                            从全局 agents 安装状态（link/copy）重建配置文件
    sync --from-config                            从配置文件创建全局链接/复制目录（用于新电脑部署）
    remove <skill>                                完全移除 skill（中央目录 + 全局安装 + 配置）
    remove <skill> -a <agents...> [-g|-p <dir>]   仅从指定位置移除 skill

add 命令参数:
    source              Skill 来源，支持三种格式:
                        - GitHub URL: https://github.com/owner/repo/tree/branch/path/to/skill
                        - 本地路径: /path/to/skill 或 ./skill 或 ../skill
                          (必须以 /, ./, ../ 开头，显式指定路径)
                        - Skill 名称: skill-creator (搜索中央目录)

	    -a <agents...>      指定要链接的 agents，支持: cursor, claude-code, codex, gemini
	                        可以指定多个，用空格分隔
	                        不指定则仅下载到中央目录

	    -g, --global        全局安装（安装到家目录）
	                        创建 ~/.cursor/skills/, ~/.claude/skills/, ~/.codex/skills/, ~/.gemini/skills/

	    -p, --project <dir> 指定项目根目录（本地安装）
	                        默认为当前目录
	                        创建 <dir>/.cursor/skills/, <dir>/.claude/skills/, <dir>/.codex/skills/, <dir>/.gemini/skills/
	                        不能与 -g 同时使用

    -c, --copy          复制模式（复制整个目录而非创建符号链接）
                        适用于不支持符号链接的 agents
                        默认为符号链接模式

    注意: 默认为本地安装（当前目录），使用 -g 进行全局安装

remove 命令参数:
    -a <agents...>      指定要移除的 agents
    -g, --global        从全局安装移除
    -p, --project <dir> 从指定项目移除
                        不指定 -g/-p 时默认从当前目录移除

示例:
    # 本地安装（默认）- 安装到当前目录
    skill-mgr add ./my-skill -a cursor
    # 创建 ./.cursor/skills/my-skill (符号链接)

    # 全局安装 - 安装到家目录
    skill-mgr add ./my-skill -a cursor -g
    # 创建 ~/.cursor/skills/my-skill (符号链接)

    # 复制模式安装（适用于不支持符号链接的 agent）
    skill-mgr add ./my-skill -a codex -g -c
    # 复制到 ~/.codex/skills/my-skill (实际目录)

    # 混合使用：cursor 用符号链接，codex 用复制
    skill-mgr add ./my-skill -a cursor -g        # symlink
    skill-mgr add ./my-skill -a codex -g -c      # copy

    # 本地安装到指定项目
    skill-mgr add ./my-skill -a cursor -p ~/projects/foo
    # 创建 ~/projects/foo/.cursor/skills/my-skill

    # 多个 agents（全局安装）
    skill-mgr add skill-creator -a cursor claude-code -g

    # 从 GitHub 添加（本地安装）
    skill-mgr add https://github.com/anthropics/skills/tree/main/skills/skill-creator -a cursor

    # 列出所有 skills（显示全局安装状态）
    skill-mgr list

    # 检查一致性状态
    skill-mgr status

    # 自动修复不一致
    skill-mgr status --fix

    # 从全局 agents 安装状态（link/copy）生成配置（首次使用或迁移）
    skill-mgr sync --from-agents

    # 在新电脑上从配置部署
    skill-mgr sync --from-config

    # 完全移除 skill（中央目录 + 全局安装）
    skill-mgr remove skill-creator

    # 从全局安装移除
    skill-mgr remove skill-creator -a cursor -g

    # 从指定项目移除
    skill-mgr remove skill-creator -a cursor -p ~/projects/foo

    # 从当前目录移除
    skill-mgr remove skill-creator -a cursor

中央存储目录: $SKILLS_DIR
配置文件: $SKILLS_YAML
EOF
}

# 解析 GitHub URL
# 输入: https://github.com/owner/repo/tree/branch/path/to/skill
# 输出: 设置全局变量 OWNER, REPO, BRANCH, REPO_PATH, SKILL_NAME
parse_github_url() {
    local url="$1"
    
    # 检查是否是 GitHub URL
    if [[ ! "$url" =~ ^https?://github\.com/ ]]; then
        return 1
    fi
    
    # 解析 URL: https://github.com/owner/repo/tree/branch/path/to/skill
    # 正则表达式匹配
    if [[ "$url" =~ github\.com/([^/]+)/([^/]+)/tree/([^/]+)/(.+)$ ]]; then
        OWNER="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]}"
        BRANCH="${BASH_REMATCH[3]}"
        REPO_PATH="${BASH_REMATCH[4]}"
        
        # 从路径提取 skill 名称（最后一级目录）
        SKILL_NAME=$(/usr/bin/basename "$REPO_PATH")
        
        return 0
    else
        print_error "无法解析 GitHub URL 格式"
        print_error "期望格式: https://github.com/owner/repo/tree/branch/path/to/skill"
        return 1
    fi
}

# 从 GitHub 下载 skill 使用 sparse checkout
download_from_github() {
    local temp_dir=$(/usr/bin/mktemp -d)
    
    print_info "下载 skill: $SKILL_NAME"
    print_info "来源: https://github.com/$OWNER/$REPO (分支: $BRANCH, 路径: $REPO_PATH)"
    
    # 使用 git sparse-checkout 只下载指定目录
    (
        cd "$temp_dir" || exit 1
        
        # 初始化仓库
        if ! /usr/bin/git clone --filter=blob:none --sparse --depth=1 \
            --branch "$BRANCH" "https://github.com/$OWNER/$REPO.git" repo 2>/dev/null; then
            print_error "Git clone 失败，请检查 URL 和网络连接"
            exit 1
        fi
        
        cd repo || exit 1
        
        # 设置 sparse-checkout
        if ! /usr/bin/git sparse-checkout set "$REPO_PATH" 2>/dev/null; then
            print_error "Sparse checkout 失败，请检查路径是否正确"
            exit 1
        fi
        
        # 检查目录是否存在
        if [[ ! -d "$REPO_PATH" ]]; then
            print_error "下载的目录不存在: $REPO_PATH"
            exit 1
        fi
        
        # 检查 SKILL.md 是否存在
        if [[ ! -f "$REPO_PATH/SKILL.md" ]]; then
            print_error "目录中没有找到 SKILL.md 文件"
            exit 1
        fi
        
        # 复制到中央目录
        local target_dir="$SKILLS_DIR/$SKILL_NAME"
        
        # 检查目标是否已存在
        if [[ -e "$target_dir" ]]; then
            print_warn "Skill 已存在: $target_dir"
            if ! prompt_yes_no "是否覆盖? (y/N) " "N"; then
                print_info "取消操作"
                exit 0
            fi
            if ! /bin/rm -rf "$target_dir"; then
                print_error "删除失败: $target_dir"
                exit 1
            fi
        fi
        
        # 复制文件
        /bin/mkdir -p "$SKILLS_DIR"
        if ! /bin/cp -r "$REPO_PATH" "$target_dir"; then
            print_error "复制失败: $REPO_PATH -> $target_dir"
            exit 1
        fi
        
        print_info "Skill 已保存到: $target_dir"
    )
    
    local exit_code=$?
    
    # 清理临时目录
    if ! /bin/rm -rf "$temp_dir"; then
        print_warn "清理临时目录失败: $temp_dir"
    fi
    
    return $exit_code
}

# 在中央目录搜索 skill
search_skill_in_central() {
    local query="$1"
    local matches=()
    
    # 如果中央目录不存在，返回空
    if [[ ! -d "$SKILLS_DIR" ]]; then
        return 1
    fi
    
    # 搜索匹配的 skills（使用简单的 for 循环避免 process substitution 问题）
    local skill_dirs=("$SKILLS_DIR"/*)
    for skill_dir in "${skill_dirs[@]}"; do
        # 跳过不存在的目录（处理空目录情况）
        [[ ! -d "$skill_dir" ]] && continue
        
        local skill_name=$(/usr/bin/basename "$skill_dir")
        
        # 精确匹配或部分匹配
        if [[ "$skill_name" == "$query" ]] || [[ "$skill_name" == *"$query"* ]]; then
            matches+=("$skill_name")
        fi
    done
    
    # 如果找到匹配
    if [[ ${#matches[@]} -eq 0 ]]; then
        return 1
    elif [[ ${#matches[@]} -eq 1 ]]; then
        # 只有一个匹配，返回完整路径
        echo "$SKILLS_DIR/${matches[0]}"
        return 0
    else
        # 多个匹配，让用户选择（输出到 stderr 避免污染返回值）
        print_info "找到多个匹配的 skills:" >&2
        local i=1
        for match in "${matches[@]}"; do
            echo "  $i) $match" >&2
            ((i++))
        done
        echo >&2
        read -p "请选择 (1-${#matches[@]}, 或 0 取消): " choice >&2
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#matches[@]} ]]; then
            local selected="${matches[$((choice-1))]}"
            echo "$SKILLS_DIR/$selected"
            return 0
        else
            print_info "取消操作" >&2
            return 1
        fi
    fi
}

# 直接使用中央目录中已存在的 skill（用于名称搜索）
link_from_central() {
    local skill_path="$1"
    
    # 检查路径是否在中央目录下
    if [[ "$skill_path" != "$SKILLS_DIR"/* ]]; then
        print_error "路径不在中央目录下: $skill_path"
        return 1
    fi
    
    # 检查路径是否存在
    if [[ ! -d "$skill_path" ]]; then
        print_error "Skill 路径不存在: $skill_path"
        return 1
    fi
    
    # 提取 skill 名称
    SKILL_NAME=$(/usr/bin/basename "$skill_path")
    
    print_info "使用已存在的 skill: $SKILL_NAME"
    
    return 0
}

# 从本地路径复制 skill
copy_from_local() {
    local source_path="$1"
    
    # 检查源路径是否存在
    if [[ ! -d "$source_path" ]]; then
        print_error "源路径不存在: $source_path"
        return 1
    fi
    
    # 检查 SKILL.md 是否存在
    if [[ ! -f "$source_path/SKILL.md" ]]; then
        print_error "目录中没有找到 SKILL.md 文件"
        return 1
    fi
    
    # 提取 skill 名称
    SKILL_NAME=$(/usr/bin/basename "$source_path")
    
    print_info "复制 skill: $SKILL_NAME"
    print_info "来源: $source_path"
    
    local target_dir="$SKILLS_DIR/$SKILL_NAME"
    
    # 检查目标是否已存在
    if [[ -e "$target_dir" ]]; then
        print_warn "Skill 已存在: $target_dir"
        if ! prompt_yes_no "是否覆盖? (y/N) " "N"; then
            print_info "取消操作"
            return 0
        fi
        if ! /bin/rm -rf "$target_dir"; then
            print_error "删除失败: $target_dir"
            return 1
        fi
    fi
    
    # 复制文件
    /bin/mkdir -p "$SKILLS_DIR"
    if ! /bin/cp -r "$source_path" "$target_dir"; then
        print_error "复制失败: $source_path -> $target_dir"
        return 1
    fi
    
    print_info "Skill 已保存到: $target_dir"
    
    return 0
}

# 创建符号链接到指定 agents
create_symlinks() {
    local base_dir="$1"
    shift
    local agents=("$@")

    _installed_agents=()
    _failed_agents=()

    if [[ ${#agents[@]} -eq 0 ]]; then
        print_info "未指定 agents，跳过创建符号链接"
        return 0
    fi

    print_info "创建符号链接到 agents..."

    local skill_source="$SKILLS_DIR/$SKILL_NAME"
    local any_installed=0

    for agent in "${agents[@]}"; do
        # 检查 agent 是否支持
        local agent_dir
        if ! agent_dir=$(get_agent_dir "$agent" "$base_dir"); then
            print_error "不支持的 agent: $agent"
            print_error "支持的 agents: $SUPPORTED_AGENTS"
            _failed_agents+=("$agent")
            continue
        fi

        local link_target="$agent_dir/$SKILL_NAME"

        # 检查 agent 目录是否存在
        if [[ ! -d "$agent_dir" ]]; then
            print_warn "Agent 目录不存在: $agent_dir"
            if prompt_yes_no "是否创建目录? (y/N) " "N"; then
                /bin/mkdir -p "$agent_dir"
                print_info "已创建目录: $agent_dir"
            else
                print_warn "跳过 $agent"
                _failed_agents+=("$agent")
                continue
            fi
        fi

        # 检查写权限
        if [[ ! -w "$agent_dir" ]]; then
            print_error "没有写权限: $agent_dir"
            print_warn "跳过 $agent"
            _failed_agents+=("$agent")
            continue
        fi

        # 如果链接已存在，先删除
        if [[ -L "$link_target" ]]; then
            if ! /bin/rm "$link_target"; then
                print_error "删除旧链接失败: $link_target"
                _failed_agents+=("$agent")
                continue
            fi
        elif [[ -e "$link_target" ]]; then
            print_warn "目标位置已存在非符号链接文件: $link_target"
            if prompt_yes_no "是否删除并创建符号链接? (y/N) " "N"; then
                if ! /bin/rm -rf "$link_target"; then
                    print_error "删除目标失败: $link_target"
                    _failed_agents+=("$agent")
                    continue
                fi
            else
                print_warn "跳过 $agent"
                _failed_agents+=("$agent")
                continue
            fi
        fi

        # 创建符号链接
        if ! /bin/ln -sf "$skill_source" "$link_target"; then
            print_error "创建符号链接失败: $link_target"
            _failed_agents+=("$agent")
            continue
        fi
        print_info "  ✓ $agent: $link_target -> $skill_source"
        _installed_agents+=("$agent")
        any_installed=1
    done

    if [[ $any_installed -eq 1 ]]; then
        return 0
    fi
    return 1
}

# 复制 skill 到指定 agents（用于不支持符号链接的 agent）
copy_to_agents() {
    local base_dir="$1"
    shift
    local agents=("$@")

    _installed_agents=()
    _failed_agents=()

    if [[ ${#agents[@]} -eq 0 ]]; then
        print_info "未指定 agents，跳过复制"
        return 0
    fi

    print_info "复制 skill 到 agents..."

    local skill_source="$SKILLS_DIR/$SKILL_NAME"
    local any_installed=0

    for agent in "${agents[@]}"; do
        local agent_dir
        if ! agent_dir=$(get_agent_dir "$agent" "$base_dir"); then
            print_error "不支持的 agent: $agent"
            _failed_agents+=("$agent")
            continue
        fi

        local target_dir="$agent_dir/$SKILL_NAME"

        # 检查 agent 目录是否存在
        if [[ ! -d "$agent_dir" ]]; then
            print_warn "Agent 目录不存在: $agent_dir"
            if prompt_yes_no "是否创建目录? (y/N) " "N"; then
                /bin/mkdir -p "$agent_dir"
                print_info "已创建目录: $agent_dir"
            else
                print_warn "跳过 $agent"
                _failed_agents+=("$agent")
                continue
            fi
        fi

        # 如果目标已存在，先删除
        if [[ -e "$target_dir" ]]; then
            print_warn "目标位置已存在: $target_dir"
            if prompt_yes_no "是否覆盖? (y/N) " "N"; then
                if ! /bin/rm -rf "$target_dir"; then
                    print_error "删除失败: $target_dir"
                    _failed_agents+=("$agent")
                    continue
                fi
            else
                print_warn "跳过 $agent"
                _failed_agents+=("$agent")
                continue
            fi
        fi

        # 复制目录
        if ! /bin/cp -r "$skill_source" "$target_dir"; then
            print_error "复制失败: $skill_source -> $target_dir"
            _failed_agents+=("$agent")
            continue
        fi
        print_info "  ✓ $agent: $target_dir (复制)"
        _installed_agents+=("$agent")
        any_installed=1
    done

    if [[ $any_installed -eq 1 ]]; then
        return 0
    fi
    return 1
}

# 添加 skill 命令
cmd_add() {
    local source=""
    local agents=()
    local is_global=false
    local project_dir=""
    local use_copy=false
    local source_by_name=false

    # 解析参数
    if [[ $# -eq 0 ]]; then
        print_error "缺少 source 参数"
        show_help
        return 1
    fi

    source="$1"
    shift

    # 解析可选参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--agents)
                shift
                # 收集所有 agents，直到遇到下一个选项或参数结束
                while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                    agents+=("$1")
                    shift
                done
                ;;
            -g|--global)
                is_global=true
                shift
                ;;
            -p|--project)
                if [[ -z "$2" || "$2" =~ ^- ]]; then
                    print_error "-p 参数需要指定项目目录"
                    return 1
                fi
                project_dir="$2"
                shift 2
                ;;
            -c|--copy)
                use_copy=true
                shift
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                return 1
                ;;
        esac
    done

    # -p 和 -g 互斥
    if [[ "$is_global" == true && -n "$project_dir" ]]; then
        print_error "-g 和 -p 参数不能同时使用"
        return 1
    fi

    # 确定 base 目录
    local base_dir
    if [[ "$is_global" == true ]]; then
        base_dir="$HOME"
    elif [[ -n "$project_dir" ]]; then
        base_dir=$(normalize_base_dir "$project_dir")
        if [[ ! -d "$base_dir" ]]; then
            print_error "项目目录不存在: $base_dir"
            return 1
        fi
    else
        # 默认为当前目录（本地模式）
        base_dir="$(/bin/pwd)"
    fi

    # 判断 source 类型
    if parse_github_url "$source"; then
        # GitHub URL
        if ! download_from_github; then
            return 1
        fi
    elif [[ "$source" == /* || "$source" == ./* || "$source" == ../* ]]; then
        # 本地路径（必须以 /, ./, ../ 开头，显式指定）
        source=$(normalize_base_dir "$source")
        if ! copy_from_local "$source"; then
            return 1
        fi
    else
        # 可能是 skill 名称，尝试在中央目录搜索
        print_info "在中央 skills 目录搜索: $source"
        local found_path
        if found_path=$(search_skill_in_central "$source"); then
            print_info "找到 skill: $found_path"
            # 直接使用中央目录中的 skill，不需要复制
            if ! link_from_central "$found_path"; then
                return 1
            fi
            source_by_name=true
        else
            print_error "未找到 skill '$source'"
            print_error "请提供："
            print_error "  - GitHub URL: https://github.com/owner/repo/tree/branch/path/to/skill"
            print_error "  - 本地路径: /path/to/skill 或 ./skill"
            print_error "  - 已存在的 skill 名称（将从 $SKILLS_DIR 搜索）"
            return 1
        fi
    fi

    # 创建符号链接或复制（传递 base_dir）
    local installed_agents=()
    local failed_agents=()
    if [[ "$use_copy" == true ]]; then
        copy_to_agents "$base_dir" "${agents[@]}"
    else
        create_symlinks "$base_dir" "${agents[@]}"
    fi
    installed_agents=("${_installed_agents[@]}")
    failed_agents=("${_failed_agents[@]}")

    # 更新 skills.yaml 配置文件
    # 确定 source 字符串
    local source_str="$source"
    if [[ "$source" == /* || "$source" == ./* || "$source" == ../* ]]; then
        source_str="local:$source"
    fi
    if [[ "$source_by_name" == true ]]; then
        source_str="unknown"
    fi
    if [[ "$is_global" == true && ${#installed_agents[@]} -gt 0 ]]; then
        local method="link"
        [[ "$use_copy" == true ]] && method="copy"
        update_skills_yaml "$SKILL_NAME" "$source_str" 1 "$method" "${installed_agents[@]}"
    fi

    if [[ ${#failed_agents[@]} -gt 0 ]]; then
        print_warn "以下 agents 未成功安装: ${failed_agents[*]}"
    fi

    if [[ ${#agents[@]} -gt 0 && ${#installed_agents[@]} -eq 0 ]]; then
        print_error "未能成功安装到任何 agent"
        return 1
    fi

    print_info "完成!"
    return 0
}

# 列出所有 skills 及其安装状态
cmd_list() {
    if [[ ! -f "$SKILLS_YAML" ]]; then
        print_info "配置文件不存在: $SKILLS_YAML"
        print_info "运行 'skill-mgr sync --from-agents' 从全局 agents 安装状态（link/copy）生成配置"
        return 0
    fi

    local skills
    skills=$(get_all_skills)

    if [[ -z "$skills" ]]; then
        print_info "没有已注册的 skills"
        return 0
    fi

    echo "已注册的 Skills:"
    echo "================"
    echo

    while IFS= read -r skill_name; do
        [[ -z "$skill_name" ]] && continue

        local source
        source=$(yq -r ".skills.\"$skill_name\".source // \"\"" "$SKILLS_YAML" 2>/dev/null)

        echo "  $skill_name"
        if [[ -n "$source" ]]; then
            echo "    来源: $source"
        fi

        local link_agents
        link_agents=$(get_skill_agents_link "$skill_name")
        local copy_agents
        copy_agents=$(get_skill_agents_copy "$skill_name")

        if [[ -n "$link_agents" || -n "$copy_agents" ]]; then
            echo "    全局安装:"

            echo "      链接 (link):"
            if [[ -n "$link_agents" ]]; then
                while IFS= read -r agent; do
                    [[ -z "$agent" ]] && continue
                    local agent_dir
                    agent_dir=$(get_agent_dir "$agent" "$HOME" 2>/dev/null)
                    local link_path="$agent_dir/$skill_name"
                    if [[ -L "$link_path" ]]; then
                        echo -e "        ${GREEN}✓${NC} $agent (symlink)"
                    elif [[ -e "$link_path" ]]; then
                        echo -e "        ${RED}✗${NC} $agent (实际非 symlink)"
                    else
                        echo -e "        ${RED}✗${NC} $agent (缺失)"
                    fi
                done <<< "$link_agents"
            else
                echo "        (无)"
            fi

            echo "      复制 (copy):"
            if [[ -n "$copy_agents" ]]; then
                while IFS= read -r agent; do
                    [[ -z "$agent" ]] && continue
                    local agent_dir
                    agent_dir=$(get_agent_dir "$agent" "$HOME" 2>/dev/null)
                    local link_path="$agent_dir/$skill_name"
                    if [[ -d "$link_path" && ! -L "$link_path" ]]; then
                        echo -e "        ${GREEN}✓${NC} $agent (copy)"
                    elif [[ -e "$link_path" ]]; then
                        echo -e "        ${RED}✗${NC} $agent (实际非 copy)"
                    else
                        echo -e "        ${RED}✗${NC} $agent (缺失)"
                    fi
                done <<< "$copy_agents"
            else
                echo "        (无)"
            fi
        else
            echo "    Agents: (无)"
        fi
        echo
    done <<< "$skills"
}

# 检查配置与实际全局链接/复制的一致性
cmd_status() {
    local fix_mode=0

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix)
                fix_mode=1
                shift
                ;;
            *)
                print_error "未知参数: $1"
                return 1
                ;;
        esac
    done

    echo "检查 Skills 一致性状态..."
    echo "========================="
    echo

    local has_issues=0

    # 1. 检查配置中的 skills（仅全局 agents/agents_copy）
    if [[ -f "$SKILLS_YAML" ]]; then
        local skills
        skills=$(get_all_skills)

        while IFS= read -r skill_name; do
            [[ -z "$skill_name" ]] && continue

            local skill_source="$SKILLS_DIR/$skill_name"
            local link_agents
            link_agents=$(get_skill_agents_link "$skill_name")
            local copy_agents
            copy_agents=$(get_skill_agents_copy "$skill_name")

            if [[ -z "$link_agents" && -z "$copy_agents" ]]; then
                continue
            fi

            while IFS= read -r agent; do
                [[ -z "$agent" ]] && continue

                local agent_dir
                agent_dir=$(get_agent_dir "$agent" "$HOME" 2>/dev/null)
                if [[ -z "$agent_dir" ]]; then
                    continue
                fi

                local link_path="$agent_dir/$skill_name"

                if [[ -L "$link_path" ]]; then
                    local target
                    target=$(readlink "$link_path")
                    if [[ "$target" == "$skill_source" ]]; then
                        echo -e "${GREEN}[OK]${NC} $skill_name -> $agent"
                    else
                        echo -e "${YELLOW}[WRONG]${NC} $skill_name -> $agent (链接目标错误: $target)"
                        has_issues=1
                        if [[ $fix_mode -eq 1 ]]; then
                            if [[ -d "$skill_source" && -d "$agent_dir" ]]; then
                                if /bin/rm "$link_path" && /bin/ln -sf "$skill_source" "$link_path"; then
                                    echo "  已修复"
                                else
                                    print_error "修复失败: $link_path"
                                fi
                            else
                                echo "  无法修复: skill 或 agent 目录不存在"
                            fi
                        fi
                    fi
                elif [[ -e "$link_path" ]]; then
                    echo -e "${YELLOW}[WRONG]${NC} $skill_name -> $agent (期望链接，实际为目录/文件)"
                    has_issues=1
                    if [[ $fix_mode -eq 1 ]]; then
                        if [[ -d "$skill_source" && -d "$agent_dir" ]]; then
                            if /bin/rm -rf "$link_path" && /bin/ln -sf "$skill_source" "$link_path"; then
                                echo "  已修复"
                            else
                                print_error "修复失败: $link_path"
                            fi
                        else
                            echo "  无法修复: skill 或 agent 目录不存在"
                        fi
                    fi
                else
                    echo -e "${RED}[MISSING]${NC} $skill_name -> $agent (配置有，链接不存在)"
                    has_issues=1
                    if [[ $fix_mode -eq 1 ]]; then
                        if [[ -d "$skill_source" && -d "$agent_dir" ]]; then
                            if /bin/ln -sf "$skill_source" "$link_path"; then
                                echo "  已创建链接"
                            else
                                print_error "创建链接失败: $link_path"
                            fi
                        else
                            echo "  无法修复: skill 或 agent 目录不存在"
                        fi
                    fi
                fi
            done <<< "$link_agents"

            while IFS= read -r agent; do
                [[ -z "$agent" ]] && continue

                local agent_dir
                agent_dir=$(get_agent_dir "$agent" "$HOME" 2>/dev/null)
                if [[ -z "$agent_dir" ]]; then
                    continue
                fi

                local link_path="$agent_dir/$skill_name"

                if [[ -d "$link_path" && ! -L "$link_path" ]]; then
                    echo -e "${GREEN}[OK]${NC} $skill_name -> $agent (copy)"
                elif [[ -e "$link_path" ]]; then
                    echo -e "${YELLOW}[WRONG]${NC} $skill_name -> $agent (期望 copy，实际非目录)"
                    has_issues=1
                    if [[ $fix_mode -eq 1 ]]; then
                        if [[ -d "$skill_source" && -d "$agent_dir" ]]; then
                            if /bin/rm -rf "$link_path" && /bin/cp -r "$skill_source" "$link_path"; then
                                echo "  已修复"
                            else
                                print_error "修复失败: $link_path"
                            fi
                        else
                            echo "  无法修复: skill 或 agent 目录不存在"
                        fi
                    fi
                else
                    echo -e "${RED}[MISSING]${NC} $skill_name -> $agent (配置有，copy 不存在)"
                    has_issues=1
                    if [[ $fix_mode -eq 1 ]]; then
                        if [[ -d "$skill_source" && -d "$agent_dir" ]]; then
                            if /bin/cp -r "$skill_source" "$link_path"; then
                                echo "  已复制"
                            else
                                print_error "复制失败: $skill_source -> $link_path"
                            fi
                        else
                            echo "  无法修复: skill 或 agent 目录不存在"
                        fi
                    fi
                fi
            done <<< "$copy_agents"
        done <<< "$skills"
    fi

    # 2. 检查孤立的符号链接/复制目录（存在于 agent 目录但不在配置中）
    echo
    echo "检查孤立链接/复制..."

    for agent in $SUPPORTED_AGENTS; do
        local agent_dir
        agent_dir=$(get_agent_dir "$agent" "$HOME")

        [[ ! -d "$agent_dir" ]] && continue

        for link in "$agent_dir"/*; do
            [[ ! -e "$link" ]] && continue

            local skill_name
            skill_name=$(/usr/bin/basename "$link")
            local method=""
            if [[ -L "$link" ]]; then
                local target
                target=$(readlink "$link")
                if [[ "$target" == "$SKILLS_DIR"/* ]]; then
                    method="link"
                else
                    continue
                fi
            elif [[ -d "$link" && -d "$SKILLS_DIR/$skill_name" ]]; then
                method="copy"
            else
                continue
            fi

            # 检查是否在配置中
            local in_config=0
            if [[ -f "$SKILLS_YAML" ]] && yq -e ".skills.\"$skill_name\"" "$SKILLS_YAML" &>/dev/null; then
                local field
                field=$(agents_field_for_method "$method")
                local listed_agents=()
                local line
                while IFS= read -r line; do
                    [[ -n "$line" ]] && listed_agents+=("$line")
                done <<< "$(get_skill_agents_field "$skill_name" "$field")"
                if [[ "$field" == "agents_link" ]]; then
                    while IFS= read -r line; do
                        [[ -n "$line" ]] && listed_agents+=("$line")
                    done <<< "$(get_skill_agents_field "$skill_name" "agents")"
                fi

                if has_agent_in_list "$agent" "${listed_agents[@]}"; then
                    in_config=1
                fi
            fi

            if [[ $in_config -eq 0 ]]; then
                echo -e "${YELLOW}[ORPHAN]${NC} $skill_name @ $agent ($method 存在，配置无)"
                has_issues=1
                if [[ $fix_mode -eq 1 ]]; then
                    update_skills_yaml "$skill_name" "unknown" 0 "$method" "$agent"
                    echo "  已添加到配置"
                fi
            fi
        done
    done

    echo
    if [[ $has_issues -eq 0 ]]; then
        echo -e "${GREEN}所有检查通过，配置与实际状态一致${NC}"
    else
        if [[ $fix_mode -eq 0 ]]; then
            echo "发现不一致，运行 'skill-mgr status --fix' 自动修复"
        else
            echo "修复完成"
        fi
    fi
}

# 同步命令
cmd_sync() {
    local mode=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-agents)
                mode="from-agents"
                shift
                ;;
            --from-config)
                mode="from-config"
                shift
                ;;
            *)
                print_error "未知参数: $1"
                echo "用法: skill-mgr sync --from-agents | --from-config"
                return 1
                ;;
        esac
    done

    if [[ -z "$mode" ]]; then
        print_error "请指定同步方向: --from-agents 或 --from-config"
        echo "  --from-agents  从现有 agents 安装状态（link/copy）重建配置文件"
        echo "  --from-config  从配置文件创建符号链接"
        return 1
    fi

    if [[ "$mode" == "from-agents" ]]; then
        sync_from_agents
    else
        sync_from_config
    fi
}

# 从全局 agents 安装状态（link/copy）重建配置
sync_from_agents() {
    print_info "从 agents 安装状态（link/copy）重建配置文件..."

    # 初始化空的配置文件
    /bin/mkdir -p "$SKILLS_DIR"
    cat > "$SKILLS_YAML" << 'EOF'
# Skill installation registry
# Auto-managed by skill-mgr, can be manually edited

version: 1

skills: {}
EOF

    local found_any=0

    # 扫描所有 agent 目录（仅全局）
    for agent in $SUPPORTED_AGENTS; do
        local agent_dir
        agent_dir=$(get_agent_dir "$agent")

        [[ ! -d "$agent_dir" ]] && continue

        for link in "$agent_dir"/*; do
            [[ ! -e "$link" ]] && continue

            local skill_name
            skill_name=$(/usr/bin/basename "$link")
            local method=""
            if [[ -L "$link" ]]; then
                local target
                target=$(readlink "$link")
                if [[ "$target" == "$SKILLS_DIR"/* ]]; then
                    method="link"
                else
                    continue
                fi
            elif [[ -d "$link" && -d "$SKILLS_DIR/$skill_name" ]]; then
                method="copy"
            else
                continue
            fi

            print_info "发现: $skill_name -> $agent ($method)"
            update_skills_yaml "$skill_name" "unknown" 1 "$method" "$agent"
            found_any=1
        done
    done

    if [[ $found_any -eq 0 ]]; then
        print_info "未发现任何符号链接"
    else
        print_info "配置文件已更新: $SKILLS_YAML"
    fi
}

# 从配置创建全局符号链接/复制目录
sync_from_config() {
    if [[ ! -f "$SKILLS_YAML" ]]; then
        print_error "配置文件不存在: $SKILLS_YAML"
        return 1
    fi

    print_info "从配置文件创建符号链接..."

    local skills
    skills=$(get_all_skills)

    if [[ -z "$skills" ]]; then
        print_info "配置中没有 skills"
        return 0
    fi

    while IFS= read -r skill_name; do
        [[ -z "$skill_name" ]] && continue

        local skill_source="$SKILLS_DIR/$skill_name"

        # 检查 skill 目录是否存在
        if [[ ! -d "$skill_source" ]]; then
            print_warn "Skill 目录不存在，跳过: $skill_source"
            continue
        fi

        local link_agents
        link_agents=$(get_skill_agents_link "$skill_name")
        local copy_agents
        copy_agents=$(get_skill_agents_copy "$skill_name")

        local agent_dir
        local target_path

        while IFS= read -r agent; do
            [[ -z "$agent" ]] && continue
            agent_dir=$(get_agent_dir "$agent" "$HOME" 2>/dev/null)
            if [[ -z "$agent_dir" ]]; then
                print_warn "不支持的 agent: $agent"
                continue
            fi

            if [[ ! -d "$agent_dir" ]]; then
                print_info "创建 agent 目录: $agent_dir"
                /bin/mkdir -p "$agent_dir"
            fi

            target_path="$agent_dir/$skill_name"

            if [[ -L "$target_path" ]]; then
                local target
                target=$(readlink "$target_path")
                if [[ "$target" == "$skill_source" ]]; then
                    print_info "  ✓ $skill_name -> $agent (已存在)"
                    continue
                fi
                if ! /bin/rm "$target_path"; then
                    print_error "删除旧链接失败: $target_path"
                    continue
                fi
            elif [[ -e "$target_path" ]]; then
                print_warn "目标位置已存在非符号链接: $target_path，跳过"
                continue
            fi

            if ! /bin/ln -sf "$skill_source" "$target_path"; then
                print_error "创建符号链接失败: $target_path"
                continue
            fi
            print_info "  ✓ $skill_name -> $agent (已创建)"
        done <<< "$link_agents"

        while IFS= read -r agent; do
            [[ -z "$agent" ]] && continue
            agent_dir=$(get_agent_dir "$agent" "$HOME" 2>/dev/null)
            if [[ -z "$agent_dir" ]]; then
                print_warn "不支持的 agent: $agent"
                continue
            fi

            if [[ ! -d "$agent_dir" ]]; then
                print_info "创建 agent 目录: $agent_dir"
                /bin/mkdir -p "$agent_dir"
            fi

            target_path="$agent_dir/$skill_name"

            if [[ -d "$target_path" && ! -L "$target_path" ]]; then
                print_info "  ✓ $skill_name -> $agent (已存在 copy)"
                continue
            fi
            if [[ -e "$target_path" ]]; then
                print_warn "目标位置已存在非目录: $target_path，跳过"
                continue
            fi
            if ! /bin/cp -r "$skill_source" "$target_path"; then
                print_error "复制失败: $skill_source -> $target_path"
                continue
            fi
            print_info "  ✓ $skill_name -> $agent (copy 已创建)"
        done <<< "$copy_agents"
    done <<< "$skills"

    print_info "同步完成"
}

# 移除 skill 命令
cmd_remove() {
    local skill_name=""
    local agents=()
    local is_global=false
    local project_dir=""

    # 解析参数
    if [[ $# -eq 0 ]]; then
        print_error "缺少 skill 名称"
        echo "用法:"
        echo "  skill-mgr remove <skill>                    # 完全移除"
        echo "  skill-mgr remove <skill> -a <agents>        # 仅从指定 agents 移除（全局）"
        echo "  skill-mgr remove <skill> -a <agents> -g     # 从全局安装移除"
        echo "  skill-mgr remove <skill> -a <agents> -p <dir> # 从指定项目移除"
        return 1
    fi

    skill_name="$1"
    shift

    # 解析可选参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--agents)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                    agents+=("$1")
                    shift
                done
                ;;
            -g|--global)
                is_global=true
                shift
                ;;
            -p|--project)
                if [[ -z "$2" || "$2" =~ ^- ]]; then
                    print_error "-p 参数需要指定项目目录"
                    return 1
                fi
                project_dir="$2"
                shift 2
                ;;
            *)
                print_error "未知参数: $1"
                return 1
                ;;
        esac
    done

    # -p 和 -g 互斥
    if [[ "$is_global" == true && -n "$project_dir" ]]; then
        print_error "-g 和 -p 参数不能同时使用"
        return 1
    fi

    local skill_dir="$SKILLS_DIR/$skill_name"

    if [[ ${#agents[@]} -eq 0 ]]; then
        # 完全移除模式
        # 检查 skill 是否存在
        local has_record=0
        if [[ -f "$SKILLS_YAML" ]] && yq -e ".skills.\"$skill_name\"" "$SKILLS_YAML" &>/dev/null; then
            has_record=1
        fi
        if [[ ! -d "$skill_dir" ]] && [[ $has_record -eq 0 ]]; then
            print_error "Skill 不存在: $skill_name"
            return 1
        fi

        # 确认提示
        print_warn "即将完全移除 skill: $skill_name"
        echo
        echo "将执行以下操作:"
        [[ -d "$skill_dir" ]] && echo "  - 删除中央目录: $skill_dir"
        echo "  - 删除所有全局安装（link/copy）"
        echo "  - 从配置文件移除记录"
        echo
        if ! prompt_yes_no "确认移除? (y/N) " "N"; then
            print_info "取消操作"
            return 0
        fi

        print_info "移除 skill: $skill_name"

        # 1. 删除所有全局安装
        for agent in $SUPPORTED_AGENTS; do
            local agent_dir link_path
            agent_dir=$(get_agent_dir "$agent" "$HOME")
            link_path="$agent_dir/$skill_name"
            if [[ -e "$link_path" || -L "$link_path" ]]; then
                if /bin/rm -rf "$link_path"; then
                    print_info "  已删除全局安装: $link_path"
                else
                    print_error "  删除失败: $link_path"
                fi
            fi
        done

        print_warn "本地安装不在配置中，如需删除请使用 -p 指定项目目录"

        # 2. 删除中央目录
        if [[ -d "$skill_dir" ]]; then
            if /bin/rm -rf "$skill_dir"; then
                print_info "  已删除目录: $skill_dir"
            else
                print_error "  删除目录失败: $skill_dir"
            fi
        fi

        # 3. 从配置文件移除
        remove_skill_from_yaml "$skill_name"
        print_info "  已从配置移除"

        print_info "完成! Skill '$skill_name' 已完全移除"
    else
        # 部分移除模式 - 从指定位置移除
        # 确定 base 目录
        local base_dir
        if [[ "$is_global" == true ]]; then
            base_dir="$HOME"
            print_info "从全局安装移除 skill: $skill_name"
        elif [[ -n "$project_dir" ]]; then
            base_dir=$(normalize_base_dir "$project_dir")
            if [[ ! -d "$base_dir" ]]; then
                print_error "项目目录不存在: $base_dir"
                return 1
            fi
            print_info "从项目 $base_dir 移除 skill: $skill_name"
        else
            # 默认为当前目录（本地模式）
            base_dir="$(/bin/pwd)"
            print_info "从当前目录移除 skill: $skill_name"
        fi

        local mode
        if [[ "$is_global" == true ]]; then
            mode="global"
        else
            mode="local"
        fi

        for agent in "${agents[@]}"; do
            local agent_dir
            agent_dir=$(get_agent_dir "$agent" "$base_dir" 2>/dev/null)
            if [[ -z "$agent_dir" ]]; then
                print_error "不支持的 agent: $agent"
                continue
            fi

            local target_path="$agent_dir/$skill_name"
            local actual_method=""

            # 删除安装（符号链接或复制的目录）
            if [[ -L "$target_path" ]]; then
                # 符号链接
                if /bin/rm "$target_path"; then
                    print_info "  ✓ 已删除符号链接: $target_path"
                    actual_method="link"
                else
                    print_error "  删除失败: $target_path"
                    continue
                fi
            elif [[ -d "$target_path" ]]; then
                # 复制的目录
                print_warn "将删除目录: $target_path"
                if prompt_yes_no "确认删除? (y/N) " "N"; then
                    if /bin/rm -rf "$target_path"; then
                        print_info "  ✓ 已删除目录: $target_path"
                        actual_method="copy"
                    else
                        print_error "  删除失败: $target_path"
                        continue
                    fi
                else
                    print_warn "跳过 $agent"
                    continue
                fi
            else
                print_info "  - $agent: 未找到安装"
                continue
            fi

            # 更新配置文件（仅全局记录）
            if [[ "$mode" == "global" && -f "$SKILLS_YAML" ]]; then
                if yq -e ".skills.\"$skill_name\"" "$SKILLS_YAML" &>/dev/null; then
                    local field
                    field=$(agents_field_for_method "$actual_method")
                    remove_agent_from_skill_field "$skill_name" "$field" "$agent"
                    if [[ "$field" == "agents_link" ]]; then
                        remove_agent_from_skill_field "$skill_name" "agents" "$agent"
                    fi
                    remove_skill_if_empty "$skill_name"
                fi
            fi
        done

        print_info "完成"
    fi
}

# 主函数
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi

    local command="$1"
    shift
    
    case "$command" in
        add)
            cmd_add "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        sync)
            cmd_sync "$@"
            ;;
        remove)
            cmd_remove "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "未知命令: $command"
            show_help
            return 1
            ;;
    esac
}

# 执行主函数
if ! check_dependencies; then
    exit 1
fi
main "$@"

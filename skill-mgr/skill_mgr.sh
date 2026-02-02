#!/bin/bash

# Skill Manager - 管理 AI Agent Skills 的命令行工具
# 支持从 GitHub 或本地路径添加 skills 到中央仓库，并可选地创建符号链接到各 AI agent

# 确保 PATH 包含标准命令路径
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# 中央 skills 存储目录
SKILLS_DIR="$HOME/agent-settings/skills"

# 获取 agent 目录的函数（兼容 bash 3.2）
get_agent_dir() {
    local agent="$1"
    case "$agent" in
        cursor)
            echo "$HOME/.cursor/skills"
            ;;
        claude-code)
            echo "$HOME/.claude/skills"
            ;;
        codex)
            echo "$HOME/.codex/skills"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# 支持的 agents 列表
SUPPORTED_AGENTS="cursor claude-code codex"

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

# 显示帮助信息
show_help() {
    cat << EOF
Skill Manager - 管理 AI Agent Skills 的命令行工具

用法:
    skill-mgr add <source> [-a <agents...>]

参数:
    source              Skill 来源，支持三种格式:
                        - GitHub URL: https://github.com/owner/repo/tree/branch/path/to/skill
                        - 本地路径: /path/to/skill 或 ./skill 或 ../skill
                          (必须以 /, ./, ../ 开头，显式指定路径)
                        - Skill 名称: skill-creator (搜索中央目录)

选项:
    -a <agents...>      指定要链接的 agents，支持: cursor, claude-code, codex
                        可以指定多个，用空格分隔
                        不指定则仅下载到中央目录

示例:
    # 从 GitHub 添加 skill（仅下载到中央目录）
    skill-mgr add https://github.com/anthropics/skills/tree/main/skills/skill-creator

    # 从 GitHub 添加并链接到 cursor
    skill-mgr add https://github.com/anthropics/skills/tree/main/skills/skill-creator -a cursor

    # 从本地路径添加（必须用显式路径前缀）
    skill-mgr add /path/to/local/my-skill -a cursor
    skill-mgr add ./my-skill -a cursor
    skill-mgr add ../other-skills/my-skill -a cursor

    # 使用 skill 名称（搜索中央目录）
    skill-mgr add skill-creator -a cursor
    skill-mgr add creator -a cursor    # 模糊搜索

中央存储目录: $SKILLS_DIR
EOF
}

# 解析 GitHub URL
# 输入: https://github.com/owner/repo/tree/branch/path/to/skill
# 输出: 设置全局变量 OWNER, REPO, BRANCH, PATH, SKILL_NAME
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
        PATH="${BASH_REMATCH[4]}"
        
        # 从路径提取 skill 名称（最后一级目录）
        SKILL_NAME=$(/usr/bin/basename "$PATH")
        
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
    print_info "来源: https://github.com/$OWNER/$REPO (分支: $BRANCH, 路径: $PATH)"
    
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
        if ! /usr/bin/git sparse-checkout set "$PATH" 2>/dev/null; then
            print_error "Sparse checkout 失败，请检查路径是否正确"
            exit 1
        fi
        
        # 检查目录是否存在
        if [[ ! -d "$PATH" ]]; then
            print_error "下载的目录不存在: $PATH"
            exit 1
        fi
        
        # 检查 SKILL.md 是否存在
        if [[ ! -f "$PATH/SKILL.md" ]]; then
            print_error "目录中没有找到 SKILL.md 文件"
            exit 1
        fi
        
        # 复制到中央目录
        local target_dir="$SKILLS_DIR/$SKILL_NAME"
        
        # 检查目标是否已存在
        if [[ -e "$target_dir" ]]; then
            print_warn "Skill 已存在: $target_dir"
            read -p "是否覆盖? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "取消操作"
                exit 0
            fi
            /bin/rm -rf "$target_dir"
        fi
        
        # 复制文件
        /bin/mkdir -p "$SKILLS_DIR"
        /bin/cp -r "$PATH" "$target_dir"
        
        print_info "Skill 已保存到: $target_dir"
    )
    
    local exit_code=$?
    
    # 清理临时目录
    /bin/rm -rf "$temp_dir"
    
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
        read -p "是否覆盖? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "取消操作"
            return 0
        fi
        /bin/rm -rf "$target_dir"
    fi
    
    # 复制文件
    /bin/mkdir -p "$SKILLS_DIR"
    /bin/cp -r "$source_path" "$target_dir"
    
    print_info "Skill 已保存到: $target_dir"
    
    return 0
}

# 创建符号链接到指定 agents
create_symlinks() {
    local agents=("$@")
    
    if [[ ${#agents[@]} -eq 0 ]]; then
        print_info "未指定 agents，跳过创建符号链接"
        return 0
    fi
    
    print_info "创建符号链接到 agents..."
    
    local skill_source="$SKILLS_DIR/$SKILL_NAME"
    
    for agent in "${agents[@]}"; do
        # 检查 agent 是否支持
        local agent_dir
        if ! agent_dir=$(get_agent_dir "$agent"); then
            print_error "不支持的 agent: $agent"
            print_error "支持的 agents: $SUPPORTED_AGENTS"
            continue
        fi
        
        local link_target="$agent_dir/$SKILL_NAME"
        
        # 检查 agent 目录是否存在
        if [[ ! -d "$agent_dir" ]]; then
            print_warn "Agent 目录不存在: $agent_dir"
            print_warn "跳过 $agent"
            continue
        fi
        
        # 如果链接已存在，先删除
        if [[ -L "$link_target" ]]; then
            /bin/rm "$link_target"
        elif [[ -e "$link_target" ]]; then
            print_warn "目标位置已存在非符号链接文件: $link_target"
            read -p "是否删除并创建符号链接? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                /bin/rm -rf "$link_target"
            else
                print_warn "跳过 $agent"
                continue
            fi
        fi
        
        # 创建符号链接
        /bin/ln -sf "$skill_source" "$link_target"
        print_info "  ✓ $agent: $link_target -> $skill_source"
    done
    
    return 0
}

# 添加 skill 命令
cmd_add() {
    local source=""
    local agents=()
    
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
            *)
                print_error "未知参数: $1"
                show_help
                return 1
                ;;
        esac
    done
    
    # 判断 source 类型
    if parse_github_url "$source"; then
        # GitHub URL
        if ! download_from_github; then
            return 1
        fi
    elif [[ "$source" == /* || "$source" == ./* || "$source" == ../* ]]; then
        # 本地路径（必须以 /, ./, ../ 开头，显式指定）
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
        else
            print_error "未找到 skill '$source'"
            print_error "请提供："
            print_error "  - GitHub URL: https://github.com/owner/repo/tree/branch/path/to/skill"
            print_error "  - 本地路径: /path/to/skill 或 ./skill"
            print_error "  - 已存在的 skill 名称（将从 $SKILLS_DIR 搜索）"
            return 1
        fi
    fi
    
    # 创建符号链接
    if ! create_symlinks "${agents[@]}"; then
        return 1
    fi
    
    print_info "完成!"
    return 0
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
main "$@"

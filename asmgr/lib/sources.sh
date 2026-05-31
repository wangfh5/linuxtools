# lib/sources.sh — skill 来源获取与安装到 agents

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

# 安装 skill 到指定 agents（统一 link/copy 逻辑）
# 用法: install_to_agents <link|copy> <base_dir> <agents...>
# 输出变量: _installed_agents, _failed_agents
install_to_agents() {
    local mode="$1"
    local base_dir="$2"
    shift 2
    local agents=("$@")

    _installed_agents=()
    _failed_agents=()

    if [[ ${#agents[@]} -eq 0 ]]; then
        if [[ "$mode" == "link" ]]; then
            print_info "未指定 agents，跳过创建符号链接"
        else
            print_info "未指定 agents，跳过复制"
        fi
        return 0
    fi

    if [[ "$mode" == "link" ]]; then
        print_info "创建符号链接到 agents..."
    else
        print_info "复制 skill 到 agents..."
    fi

    local skill_source="$SKILLS_DIR/$SKILL_NAME"
    local any_installed=0

    for agent in "${agents[@]}"; do
        local agent_dir
        if ! agent_dir=$(get_agent_dir "$agent" "$base_dir"); then
            print_error "不支持的 agent: $agent"
            [[ "$mode" == "link" ]] && print_error "支持的 agents: $SUPPORTED_AGENTS"
            _failed_agents+=("$agent")
            continue
        fi

        local target_path="$agent_dir/$SKILL_NAME"

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

        if [[ "$mode" == "link" && ! -w "$agent_dir" ]]; then
            print_error "没有写权限: $agent_dir"
            print_warn "跳过 $agent"
            _failed_agents+=("$agent")
            continue
        fi

        if [[ "$mode" == "link" && -L "$target_path" ]]; then
            if ! /bin/rm "$target_path"; then
                print_error "删除旧链接失败: $target_path"
                _failed_agents+=("$agent")
                continue
            fi
        elif [[ -e "$target_path" ]]; then
            local prompt_msg
            if [[ "$mode" == "link" ]]; then
                print_warn "目标位置已存在非符号链接文件: $target_path"
                prompt_msg="是否删除并创建符号链接? (y/N) "
            else
                print_warn "目标位置已存在: $target_path"
                prompt_msg="是否覆盖? (y/N) "
            fi
            if prompt_yes_no "$prompt_msg" "N"; then
                if ! /bin/rm -rf "$target_path"; then
                    print_error "删除失败: $target_path"
                    _failed_agents+=("$agent")
                    continue
                fi
            else
                print_warn "跳过 $agent"
                _failed_agents+=("$agent")
                continue
            fi
        fi

        if [[ "$mode" == "link" ]]; then
            if ! /bin/ln -sf "$skill_source" "$target_path"; then
                print_error "创建符号链接失败: $target_path"
                _failed_agents+=("$agent")
                continue
            fi
            print_info "  ✓ $agent: $target_path -> $skill_source"
        else
            if ! /bin/cp -r "$skill_source" "$target_path"; then
                print_error "复制失败: $skill_source -> $target_path"
                _failed_agents+=("$agent")
                continue
            fi
            print_info "  ✓ $agent: $target_path (复制)"
        fi
        _installed_agents+=("$agent")
        any_installed=1
    done

    if [[ $any_installed -eq 1 ]]; then
        return 0
    fi
    return 1
}

create_symlinks() {
    install_to_agents "link" "$@"
}

copy_to_agents() {
    install_to_agents "copy" "$@"
}

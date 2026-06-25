# lib/project.sh — 项目级 skill/subagent 清单读写与链接重建
#
# 清单文件: $PROJECTS_DIR/<name>.yaml，每项目一个。结构对齐 skills.yaml，
# 去掉 source/updated_at，加平行 subagents 段与权威定位字段 path：
#
#   path: Projects/foo            # $HOME 内存相对路径；$HOME 外存绝对路径（以 / 开头）
#   skills:
#     <name>:
#       agents_link: [claude-code, codex]
#       agents_copy: []
#   subagents:
#     <name>:                     # <root>/agents/ 下的目录或 .md 文件
#       agents_link: [claude-code]
#       agents_copy: []
#
# 文件名由 path 派生（/ → __），从不反向解析；定位只看 path 字段。

# path → 文件名 stem（把 / 替换为 __）
project_name_from_path() {
    echo "${1//\//__}"
}

# 绝对目录 → 存入清单的 path（$HOME 内相对、$HOME 外绝对）
project_store_path() {
    local abs="$1"
    if [[ "$abs" == "$HOME/"* ]]; then
        echo "${abs#"$HOME"/}"
    else
        echo "$abs"
    fi
}

# 清单内的 path → 本机绝对目录
project_resolve_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        echo "$path"
    else
        echo "$HOME/$path"
    fi
}

# 绝对目录 → 清单文件绝对路径
project_manifest_file() {
    local abs="$1"
    local stored name
    stored="$(project_store_path "$abs")"
    name="$(project_name_from_path "$stored")"
    echo "$PROJECTS_DIR/$name.yaml"
}

# 当前目录 scope 的统一派发：解析 cwd 的清单文件，存在则作为首参交给 <fn>（连同后续 args），
# 否则打印 warn_no_manifest + hint_other_scopes。用法: run_on_cwd_manifest <fn> [args...]
run_on_cwd_manifest() {
    local fn="$1"; shift
    local d m
    d="$(current_pwd_dir)"
    m="$(project_manifest_file "$d")"
    if [[ -f "$m" ]]; then
        "$fn" "$m" "$@"
    else
        warn_no_manifest "$m"
        hint_other_scopes
    fi
}

# 在 $AGENTS_DIR 解析 subagent 名（目录或 .md 文件），输出实际条目名
resolve_subagent_name() {
    local query="$1"
    if [[ -e "$AGENTS_DIR/$query" ]]; then
        echo "$query"; return 0
    fi
    if [[ -e "$AGENTS_DIR/$query.md" ]]; then
        echo "$query.md"; return 0
    fi
    print_error "未找到 Subagent: $query (在 $AGENTS_DIR)" >&2
    return 1
}

# 以下清单读写仿 lib/yaml.sh，区别：目标=项目清单、section（skills/subagents）参数化、不写 source/updated_at
init_project_manifest() {
    local file="$1"
    local stored_path="$2"
    if [[ ! -f "$file" ]]; then
        /bin/mkdir -p "$PROJECTS_DIR"
        cat > "$file" << EOF
# Project-local skill/subagent registry — managed by asmgr
path: $stored_path
skills: {}
subagents: {}
EOF
    fi
}

pm_get_path() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1
    yq -r '.path // ""' "$file" 2>/dev/null
}

pm_entry_exists() {
    local file="$1" section="$2" name="$3"
    [[ -f "$file" ]] && yq -e ".${section}.\"$name\"" "$file" &>/dev/null
}

pm_get_entry_agents() {
    local file="$1" section="$2" name="$3" field="$4"
    [[ ! -f "$file" ]] && return 1
    yq -r ".${section}.\"$name\".$field // [] | .[]" "$file" 2>/dev/null
}

pm_list_entries() {
    local file="$1" section="$2"
    [[ ! -f "$file" ]] && return 1
    yq -r ".${section} // {} | keys | .[]" "$file" 2>/dev/null
}

pm_list_projects() {
    [[ ! -d "$PROJECTS_DIR" ]] && return 0
    local f
    for f in "$PROJECTS_DIR"/*.yaml; do
        [[ -e "$f" ]] || continue
        /usr/bin/basename "$f" .yaml
    done
}

# 合并 agents 进 section.name 的 link/copy 字段（method=link|copy），互斥另一字段
pm_update_entry() {
    local file="$1" section="$2" name="$3" method="$4"
    shift 4
    local agents=("$@")

    local _link_yaml _copy_yaml
    compute_agent_arrays \
        "$(pm_get_entry_agents "$file" "$section" "$name" "agents_link")" \
        "$(pm_get_entry_agents "$file" "$section" "$name" "agents_copy")" \
        "$method" "${agents[@]}"

    yq -i ".${section}.\"$name\" = {\"agents_link\": $_link_yaml, \"agents_copy\": $_copy_yaml}" "$file"
}

pm_remove_entry_agent() {
    local file="$1" section="$2" name="$3" field="$4" agent="$5"
    [[ ! -f "$file" ]] && return 1
    yq -i ".${section}.\"$name\".$field -= [\"$agent\"]" "$file"
}

pm_remove_entry_if_empty() {
    local file="$1" section="$2" name="$3"
    [[ ! -f "$file" ]] && return 0
    local nlink ncopy
    nlink=$(yq -r ".${section}.\"$name\".agents_link // [] | length" "$file" 2>/dev/null)
    ncopy=$(yq -r ".${section}.\"$name\".agents_copy // [] | length" "$file" 2>/dev/null)
    if [[ "${nlink:-0}" == "0" && "${ncopy:-0}" == "0" ]]; then
        yq -i "del(.${section}.\"$name\")" "$file"
    fi
}

# 若 skills 与 subagents 均空，删除整个清单文件（返回 0=已删）
pm_prune_project() {
    local file="$1"
    [[ ! -f "$file" ]] && return 0
    local nskills nsub
    nskills=$(yq -r '.skills // {} | length' "$file" 2>/dev/null)
    nsub=$(yq -r '.subagents // {} | length' "$file" 2>/dev/null)
    if [[ "${nskills:-0}" == "0" && "${nsub:-0}" == "0" ]]; then
        /bin/rm -f "$file"
        return 0
    fi
    return 1
}

# 确保清单存在且 path 字段为最新（add/scan 入口统一调用）
project_touch_manifest() {
    local base_dir="$1"
    local stored manifest
    stored="$(project_store_path "$base_dir")"
    manifest="$(project_manifest_file "$base_dir")"
    init_project_manifest "$manifest" "$stored"
    yq -i ".path = \"$stored\"" "$manifest"
    echo "$manifest"
}

# 把中央 subagent 链接进 base_dir/.claude/agents（目录与 .md 文件均 ln -sfn）
link_subagent_to_project() {
    local base_dir="$1" name="$2"
    local src="$AGENTS_DIR/$name"
    if [[ ! -e "$src" ]]; then
        print_warn "中央 Subagent 不存在，跳过: $src"
        return 1
    fi
    local tgt_dir target
    tgt_dir="$(get_subagent_target_dir "$base_dir")"
    /bin/mkdir -p "$tgt_dir"
    target="$tgt_dir/$name"
    if [[ -L "$target" ]]; then
        local cur; cur=$(readlink "$target")
        if [[ "$cur" == "$src" ]]; then
            print_info "  ✓ Subagent $name (已存在)"
            return 0
        fi
        /bin/rm "$target"
    elif [[ -e "$target" ]]; then
        print_warn "目标位置已存在非符号链接: $target，跳过"
        return 1
    fi
    if /bin/ln -sfn "$src" "$target"; then
        print_info "  ✓ Subagent $name -> claude-code"
        return 0
    fi
    print_error "创建 Subagent 链接失败: $target"
    return 1
}

unlink_subagent_from_project() {
    local base_dir="$1" name="$2"
    local tgt_dir target
    tgt_dir="$(get_subagent_target_dir "$base_dir")"
    target="$tgt_dir/$name"
    if [[ -L "$target" ]]; then
        /bin/rm "$target" && print_info "  ✓ 已删除 Subagent 链接: $target"
    elif [[ -e "$target" ]]; then
        print_warn "Subagent 目标非符号链接，跳过: $target"
    else
        echo "  - Subagent $name: 未找到链接"
    fi
}

# 内部：把一个 skill 的 link/copy agents 物化到目标目录（项目与全局共用）
_project_deploy_skill() {
    local project_dir="$1" name="$2" skill_source="$3" link_agents="$4" copy_agents="$5"
    local scope="${6:-project}"
    local agent agent_dir

    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        agent_dir=$(get_agent_dir "$agent" "$project_dir" "$scope" 2>/dev/null)
        if [[ -z "$agent_dir" ]]; then print_warn "不支持的 Agent: $agent"; continue; fi
        [[ ! -d "$agent_dir" ]] && /bin/mkdir -p "$agent_dir"
        mat_deploy_link "$skill_source" "$agent_dir" "$name" "$agent"
    done <<< "$link_agents"

    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        agent_dir=$(get_agent_dir "$agent" "$project_dir" "$scope" 2>/dev/null)
        if [[ -z "$agent_dir" ]]; then print_warn "不支持的 Agent: $agent"; continue; fi
        [[ ! -d "$agent_dir" ]] && /bin/mkdir -p "$agent_dir"
        mat_deploy_copy "$skill_source" "$agent_dir" "$name" "$agent"
    done <<< "$copy_agents"
}

# 按清单重建一个项目的全部链接
project_deploy_one() {
    local file="$1"
    if [[ ! -f "$file" ]]; then warn_no_manifest "$file"; return 1; fi
    local stored_path project_dir
    stored_path="$(pm_get_path "$file")"
    if [[ -z "$stored_path" ]]; then print_warn "清单缺少 path 字段，跳过: $file"; return 1; fi
    project_dir="$(project_resolve_path "$stored_path")"
    if [[ ! -d "$project_dir" ]]; then print_warn "项目路径不存在，跳过: $project_dir ($file)"; return 1; fi

    print_info "部署项目: $project_dir"

    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local skill_source="$SKILLS_DIR/$name"
        if [[ ! -d "$skill_source" ]]; then print_warn "中央 Skill 不存在，跳过: $skill_source"; continue; fi
        local link_agents copy_agents
        link_agents=$(pm_get_entry_agents "$file" "skills" "$name" "agents_link")
        copy_agents=$(pm_get_entry_agents "$file" "skills" "$name" "agents_copy")
        _project_deploy_skill "$project_dir" "$name" "$skill_source" "$link_agents" "$copy_agents" "project"
    done <<< "$(pm_list_entries "$file" "skills")"

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        link_subagent_to_project "$project_dir" "$name"
    done <<< "$(pm_list_entries "$file" "subagents")"
}

project_deploy_all() {
    local proj any=0
    while IFS= read -r proj; do
        [[ -z "$proj" ]] && continue
        any=1
        project_deploy_one "$PROJECTS_DIR/$proj.yaml"
    done <<< "$(pm_list_projects)"
    [[ $any -eq 0 ]] && print_warn "没有已登记的项目"
    # 部署是 best-effort（个别项目缺失只告警跳过），整体视为成功；显式 return 0 以免
    # 末句 [[ $any -eq 0 ]] 在”有项目”时求值为假、把退出码泄漏成 1（旧缺陷①）。
    return 0
}

# 扫描一个项目目录的现有链接，登记进其清单（现有绝对链接的迁移路径）
project_scan_one() {
    local project_dir="$1"
    if [[ ! -d "$project_dir" ]]; then print_error "项目目录不存在: $project_dir"; return 1; fi
    local manifest
    manifest="$(project_touch_manifest "$project_dir")"

    local found=0 agent

    for agent in $SUPPORTED_AGENTS; do
        local agent_dir; agent_dir=$(get_agent_dir "$agent" "$project_dir" "project")
        [[ ! -d "$agent_dir" ]] && continue
        local method sname
        while IFS=$'\t' read -r method sname; do
            [[ -z "$method" ]] && continue
            print_info "发现 Skill: $sname -> $agent ($method)"
            pm_update_entry "$manifest" "skills" "$sname" "$method" "$agent"
            found=1
        done <<< "$(mat_scan_central_links "$agent_dir" "$SKILLS_DIR" 1)"
    done

    local sub_dir; sub_dir="$(get_subagent_target_dir "$project_dir")"
    local method sname
    while IFS=$'\t' read -r method sname; do
        [[ -z "$method" ]] && continue
        print_info "发现 Subagent: $sname -> claude-code"
        pm_update_entry "$manifest" "subagents" "$sname" "link" "claude-code"
        found=1
    done <<< "$(mat_scan_central_links "$sub_dir" "$AGENTS_DIR" 0)"

    if [[ $found -eq 0 ]]; then
        print_warn "未在 $project_dir 发现指向中央目录的链接"
        pm_prune_project "$manifest" && print_info "清单为空，已删除: $manifest"
    else
        print_info "清单已更新: $manifest"
    fi
}

_status_fix_link() {
    local fix_mode="$1" src="$2" tgt_dir="$3" link_path="$4"
    [[ $fix_mode -ne 1 ]] && return 0
    if [[ -e "$src" && -d "$tgt_dir" ]]; then
        if /bin/rm -rf "$link_path" && /bin/ln -sfn "$src" "$link_path"; then echo "    已修复"; else print_error "    修复失败: $link_path"; fi
    else
        echo "    无法修复: 源或目标目录不存在"
    fi
}

_status_fix_copy() {
    local fix_mode="$1" src="$2" agent_dir="$3" link_path="$4"
    [[ $fix_mode -ne 1 ]] && return 0
    if [[ -d "$src" && -d "$agent_dir" ]]; then
        if /bin/rm -rf "$link_path" && /bin/cp -r "$src" "$link_path"; then echo "    已修复"; else print_error "    修复失败: $link_path"; fi
    else
        echo "    无法修复: 源或目标目录不存在"
    fi
}

# 检查 section.name 在各 agent 下 link 或 copy 的一致性（base_dir=项目目录）
_status_check_entry() {
    local base_dir="$1" name="$2" src="$3" method="$4" agents="$5" fix_mode="$6"
    local issue=0 agent agent_dir link_path
    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        agent_dir=$(get_agent_dir "$agent" "$base_dir" "project" 2>/dev/null)
        [[ -z "$agent_dir" ]] && continue
        link_path="$agent_dir/$name"
        local cls state actual
        cls=$(mat_classify "$link_path" "$src" "$method")
        IFS=$'\t' read -r state actual <<< "$cls"
        if [[ "$method" == "link" ]]; then
            case "$state" in
                ok)           print_status_tag OK "$name -> $agent" "  " ;;
                wrong_target) print_status_tag WRONG "$name -> $agent (链接目标错误: $actual)" "  "; issue=1; _status_fix_link "$fix_mode" "$src" "$agent_dir" "$link_path" ;;
                wrong_type)   print_status_tag WRONG "$name -> $agent (期望链接，实际为目录/文件)" "  "; issue=1; _status_fix_link "$fix_mode" "$src" "$agent_dir" "$link_path" ;;
                missing)      print_status_tag MISSING "$name -> $agent" "  "; issue=1; _status_fix_link "$fix_mode" "$src" "$agent_dir" "$link_path" ;;
            esac
        else
            case "$state" in
                ok)         print_status_tag OK "$name -> $agent (copy)" "  " ;;
                wrong_type) print_status_tag WRONG "$name -> $agent (期望 copy，实际非目录)" "  "; issue=1; _status_fix_copy "$fix_mode" "$src" "$agent_dir" "$link_path" ;;
                missing)    print_status_tag MISSING "$name -> $agent (copy 不存在)" "  "; issue=1; _status_fix_copy "$fix_mode" "$src" "$agent_dir" "$link_path" ;;
            esac
        fi
    done <<< "$agents"
    return $issue
}

_status_check_subagent() {
    local project_dir="$1" name="$2" fix_mode="$3"
    local src="$AGENTS_DIR/$name"
    local tgt_dir target issue=0
    tgt_dir="$(get_subagent_target_dir "$project_dir")"
    target="$tgt_dir/$name"
    local cls state actual
    cls=$(mat_classify "$target" "$src" "link")
    IFS=$'\t' read -r state actual <<< "$cls"
    case "$state" in
        ok)           print_status_tag OK "Subagent $name -> claude-code" "  " ;;
        wrong_target) print_status_tag WRONG "Subagent $name (链接目标错误: $actual)" "  "; issue=1; _status_fix_link "$fix_mode" "$src" "$tgt_dir" "$target" ;;
        wrong_type)   print_status_tag WRONG "Subagent $name (期望链接，实际为目录/文件)" "  "; issue=1; _status_fix_link "$fix_mode" "$src" "$tgt_dir" "$target" ;;
        missing)      print_status_tag MISSING "Subagent $name" "  "; issue=1; _status_fix_link "$fix_mode" "$src" "$tgt_dir" "$target" ;;
    esac
    return $issue
}

# 扫描项目内指向中央目录、但清单未声明的游离链接（--fix 删除）
_project_scan_orphans() {
    local file="$1" project_dir="$2" fix_mode="$3"
    local issue=0 agent

    for agent in $SUPPORTED_AGENTS; do
        local agent_dir; agent_dir=$(get_agent_dir "$agent" "$project_dir" "project")
        [[ ! -d "$agent_dir" ]] && continue
        local method sname
        while IFS=$'\t' read -r method sname; do
            [[ -z "$method" ]] && continue
            local field; field=$(agents_field_for_method "$method")
            local in_config=0
            if pm_entry_exists "$file" "skills" "$sname"; then
                local listed=() ln
                while IFS= read -r ln; do [[ -n "$ln" ]] && listed+=("$ln"); done <<< "$(pm_get_entry_agents "$file" "skills" "$sname" "$field")"
                has_agent_in_list "$agent" "${listed[@]}" && in_config=1
            fi
            if [[ $in_config -eq 0 ]]; then
                print_status_tag ORPHAN "$sname @ $agent ($method 存在，清单无)" "  "; issue=1
                if [[ $fix_mode -eq 1 ]]; then /bin/rm -rf "$agent_dir/$sname" && echo "    已删除游离链接"; fi
            fi
        done <<< "$(mat_scan_central_links "$agent_dir" "$SKILLS_DIR" 1)"
    done

    local sub_dir; sub_dir="$(get_subagent_target_dir "$project_dir")"
    local method sname
    while IFS=$'\t' read -r method sname; do
        [[ -z "$method" ]] && continue
        local in_config=0
        if pm_entry_exists "$file" "subagents" "$sname"; then
            local listed=() ln
            while IFS= read -r ln; do [[ -n "$ln" ]] && listed+=("$ln"); done <<< "$(pm_get_entry_agents "$file" "subagents" "$sname" "agents_link")"
            has_agent_in_list "claude-code" "${listed[@]}" && in_config=1
        fi
        if [[ $in_config -eq 0 ]]; then
            print_status_tag ORPHAN "Subagent $sname (存在，清单无)" "  "; issue=1
            if [[ $fix_mode -eq 1 ]]; then /bin/rm -f "$sub_dir/$sname" && echo "    已删除游离链接"; fi
        fi
    done <<< "$(mat_scan_central_links "$sub_dir" "$AGENTS_DIR" 0)"

    return $issue
}

# 检查单个项目清单的一致性（返回 0=全 OK, 1=有问题）
project_status_one() {
    local file="$1" fix_mode="$2"
    local stored_path project_dir proj_name
    proj_name=$(/usr/bin/basename "$file" .yaml)
    stored_path="$(pm_get_path "$file")"
    project_dir="$(project_resolve_path "$stored_path")"

    echo "项目: $proj_name ($project_dir)"
    if [[ ! -d "$project_dir" ]]; then
        print_warn "  项目路径不存在，跳过"
        return 0
    fi

    local found_issue=0 name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local skill_source="$SKILLS_DIR/$name"
        local link_agents copy_agents
        link_agents=$(pm_get_entry_agents "$file" "skills" "$name" "agents_link")
        copy_agents=$(pm_get_entry_agents "$file" "skills" "$name" "agents_copy")
        _status_check_entry "$project_dir" "$name" "$skill_source" "link" "$link_agents" "$fix_mode" || found_issue=1
        _status_check_entry "$project_dir" "$name" "$skill_source" "copy" "$copy_agents" "$fix_mode" || found_issue=1
    done <<< "$(pm_list_entries "$file" "skills")"

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _status_check_subagent "$project_dir" "$name" "$fix_mode" || found_issue=1
    done <<< "$(pm_list_entries "$file" "subagents")"

    _project_scan_orphans "$file" "$project_dir" "$fix_mode" || found_issue=1

    return $found_issue
}

project_status_all() {
    local fix_mode="$1"
    local proj any=0 issues=0
    while IFS= read -r proj; do
        [[ -z "$proj" ]] && continue
        any=1
        project_status_one "$PROJECTS_DIR/$proj.yaml" "$fix_mode" || issues=1
    done <<< "$(pm_list_projects)"
    [[ $any -eq 0 ]] && print_warn "没有已登记的项目"
    return $issues
}

_join_csv() {
    local out="" item
    for item in "$@"; do
        [[ -n "$out" ]] && out+=","
        out+="$item"
    done
    echo "$out"
}

project_list_one() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1
    local proj_name stored_path project_dir name
    proj_name=$(/usr/bin/basename "$file" .yaml)
    stored_path="$(pm_get_path "$file")"
    project_dir="$(project_resolve_path "$stored_path")"

    echo "  $proj_name"
    echo "    路径: $project_dir"

    local skills_list; skills_list=$(pm_list_entries "$file" "skills")
    if [[ -n "$skills_list" ]]; then
        echo "    skills:"
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            local la=() lc=() ln
            while IFS= read -r ln; do [[ -n "$ln" ]] && la+=("$ln"); done <<< "$(pm_get_entry_agents "$file" "skills" "$name" "agents_link")"
            while IFS= read -r ln; do [[ -n "$ln" ]] && lc+=("$ln"); done <<< "$(pm_get_entry_agents "$file" "skills" "$name" "agents_copy")"
            local desc="link: $(_join_csv "${la[@]}")"
            [[ ${#lc[@]} -gt 0 ]] && desc+="; copy: $(_join_csv "${lc[@]}")"
            echo "      - $name ($desc)"
        done <<< "$skills_list"
    fi

    local sub_list; sub_list=$(pm_list_entries "$file" "subagents")
    if [[ -n "$sub_list" ]]; then
        echo "    subagents:"
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            echo "      - $name (claude-code)"
        done <<< "$sub_list"
    fi
}

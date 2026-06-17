# lib/yaml.sh — skills.yaml 注册表读写

# 初始化 skills.yaml 文件
init_skills_yaml() {
    if [[ ! -f "$SKILLS_YAML" ]]; then
        /bin/mkdir -p "$SKILLS_DIR"
        cat > "$SKILLS_YAML" << 'EOF'
# Skill installation registry
# Auto-managed by asmgr, can be manually edited

skills: {}
EOF
    fi
}

## 注意：仅支持 agents_link（符号链接）与 agents_copy（复制）两种字段。

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

# skills.yaml 中是否存在某 skill 记录（文件不存在即视为不存在）。
# 全局侧与 project.sh 的 pm_entry_exists 对应。
skill_exists_in_yaml() {
    [[ -f "$SKILLS_YAML" ]] && yq -e ".skills.\"$1\"" "$SKILLS_YAML" &>/dev/null
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

# 把「现有 link/copy 列表 + 本次 method/agents」算成两个 yaml 数组字符串。
# method=copy → agents 进 copy、从 link 移除；否则进 link、从 copy 移除（两字段互斥）。
# 现有列表以换行串传入（调用方各自从 skills.yaml 或项目清单读出）。
# 输出全局 _link_yaml / _copy_yaml（沿用本仓库 _merged_agents/_filtered_agents 式输出变量约定）。
# 用法: compute_agent_arrays "<existing_link_lines>" "<existing_copy_lines>" <method> <agents...>
compute_agent_arrays() {
    local existing_link_str="$1" existing_copy_str="$2" method="$3"
    shift 3
    local agents=("$@")

    local existing_link=() existing_copy=() line
    while IFS= read -r line; do [[ -n "$line" ]] && existing_link+=("$line"); done <<< "$existing_link_str"
    while IFS= read -r line; do [[ -n "$line" ]] && existing_copy+=("$line"); done <<< "$existing_copy_str"

    local new_link=() new_copy=()
    if [[ "$method" == "copy" ]]; then
        merge_unique_agents "${existing_copy[@]}" "${agents[@]}"; new_copy=("${_merged_agents[@]}")
        filter_out_agents "${existing_link[@]}" --remove "${agents[@]}"; new_link=("${_filtered_agents[@]}")
    else
        merge_unique_agents "${existing_link[@]}" "${agents[@]}"; new_link=("${_merged_agents[@]}")
        filter_out_agents "${existing_copy[@]}" --remove "${agents[@]}"; new_copy=("${_filtered_agents[@]}")
    fi

    _link_yaml=$(build_yaml_array "${new_link[@]}")
    _copy_yaml=$(build_yaml_array "${new_copy[@]}")
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

    if skill_exists_in_yaml "$skill_name"; then
        exists=1
        current_source=$(yq -r ".skills.\"$skill_name\".source // \"\"" "$SKILLS_YAML" 2>/dev/null)
        current_added_at=$(yq -r ".skills.\"$skill_name\".added_at // \"\"" "$SKILLS_YAML" 2>/dev/null)
    fi

    # source：传入 unknown 表示"不改现有 source"；如果是新建记录则写入 unknown。
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

    local _link_yaml _copy_yaml
    compute_agent_arrays \
        "$(get_skill_agents_link "$skill_name")" \
        "$(get_skill_agents_field "$skill_name" "agents_copy")" \
        "$method" "${agents[@]}"

    # 整块重写，保证字段顺序：agents_link、agents_copy、source、added_at；
    # source/added_at 来自外部输入或系统时间，必须经 strenv() 进入 yq，避免表达式注入。
    SOURCE_VALUE="$final_source" ADDED_AT_VALUE="$final_added_at" \
        yq -i ".skills.\"$skill_name\" = {\"agents_link\": $_link_yaml, \"agents_copy\": $_copy_yaml, \"source\": strenv(SOURCE_VALUE), \"added_at\": strenv(ADDED_AT_VALUE)}" "$SKILLS_YAML"
}

# 从 skills.yaml 读取 skill 的 link/copy agents 列表
get_skill_agents_link() {
    local skill_name="$1"
    [[ ! -f "$SKILLS_YAML" ]] && return 1
    yq -r ".skills.\"$skill_name\".agents_link // [] | .[]" "$SKILLS_YAML" 2>/dev/null
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

# 保留无全局安装的 skill 记录：agents_link/agents_copy 为空时，source/added_at
# 仍是跨机器恢复时唯一可追溯的来源信息。完全删除只由 remove_skill_from_yaml 执行。
preserve_skill_install_entry_if_empty() {
    local skill_name="$1"
    [[ ! -f "$SKILLS_YAML" ]] && return 0
    skill_exists_in_yaml "$skill_name" || return 0
    local remaining_link remaining_copy
    remaining_link=$(yq -r ".skills.\"$skill_name\".agents_link // [] | length" "$SKILLS_YAML" 2>/dev/null)
    remaining_copy=$(yq -r ".skills.\"$skill_name\".agents_copy // [] | length" "$SKILLS_YAML" 2>/dev/null)
    if [[ "${remaining_link:-0}" == "0" && "${remaining_copy:-0}" == "0" ]]; then
        yq -i ".skills.\"$skill_name\".agents_link = [] | .skills.\"$skill_name\".agents_copy = []" "$SKILLS_YAML"
    fi
}

# 从 skills.yaml 获取所有 skills
get_all_skills() {
    [[ ! -f "$SKILLS_YAML" ]] && return 1
    yq -r '.skills | keys | .[]' "$SKILLS_YAML" 2>/dev/null
}

# 从 agents 实态重扫前只清空安装列表，不抹掉 source/added_at。
reset_all_skill_install_entries() {
    [[ ! -f "$SKILLS_YAML" ]] && return 0
    local skill_name
    while IFS= read -r skill_name; do
        [[ -z "$skill_name" ]] && continue
        yq -i ".skills.\"$skill_name\".agents_link = [] | .skills.\"$skill_name\".agents_copy = []" "$SKILLS_YAML"
    done <<< "$(get_all_skills)"
}

# 从 skills.yaml 完全移除 skill 记录
remove_skill_from_yaml() {
    local skill_name="$1"
    [[ ! -f "$SKILLS_YAML" ]] && return 0
    yq -i "del(.skills.\"$skill_name\")" "$SKILLS_YAML"
}

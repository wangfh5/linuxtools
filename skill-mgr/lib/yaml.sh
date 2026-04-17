# lib/yaml.sh — skills.yaml 注册表读写

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

remove_skill_if_empty() {
    local skill_name="$1"
    [[ ! -f "$SKILLS_YAML" ]] && return 0
    local remaining_link remaining_copy
    remaining_link=$(yq -r ".skills.\"$skill_name\".agents_link // [] | length" "$SKILLS_YAML" 2>/dev/null)
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

# 从 skills.yaml 完全移除 skill 记录
remove_skill_from_yaml() {
    local skill_name="$1"
    [[ ! -f "$SKILLS_YAML" ]] && return 0
    yq -i "del(.skills.\"$skill_name\")" "$SKILLS_YAML"
}

# lib/plugin.sh — Claude Code Plugin / Marketplace support
#
# 仅对 Claude Code 生效。数据源：
#   ~/.claude/plugins/known_marketplaces.json  —— marketplace 注册表
#   claude plugin list                         —— 已启用 plugin 列表
# skills.yaml 扩展：顶层 `claude_code:` 段，含 marketplaces（map）和 plugins（list）。
# 首次写入时自动将 `version` 升到 2。

CLAUDE_PLUGINS_DIR="$HOME/.claude/plugins"
CLAUDE_KNOWN_MKT="$CLAUDE_PLUGINS_DIR/known_marketplaces.json"

# 检查 claude CLI 是否可用
check_claude_cli() {
    if ! command -v claude &>/dev/null; then
        print_error "未找到 claude CLI"
        print_error "请先安装 Claude Code: https://docs.claude.com/en/docs/claude-code"
        return 1
    fi
    return 0
}

# 确保 skills.yaml 有 claude_code 段，并把 version 提到 2
ensure_claude_code_section() {
    init_skills_yaml
    yq -i '
        .version = 2 |
        .claude_code.marketplaces = (.claude_code.marketplaces // {}) |
        .claude_code.plugins = (.claude_code.plugins // [])
    ' "$SKILLS_YAML"
}

# 写入/更新 marketplace 记录
# 用法: update_marketplace_in_yaml <name> <source> [touch_added_at:0|1]
update_marketplace_in_yaml() {
    local name="$1"
    local source="$2"
    local touch_added_at="${3:-1}"

    ensure_claude_code_section

    local timestamp current_added_at
    timestamp=$(now_timestamp_local)
    current_added_at=$(yq -r ".claude_code.marketplaces.\"$name\".added_at // \"\"" "$SKILLS_YAML" 2>/dev/null)

    local final_added_at="$current_added_at"
    if [[ -z "$final_added_at" || "$touch_added_at" == "1" ]]; then
        final_added_at="$timestamp"
    fi

    yq -i ".claude_code.marketplaces.\"$name\" = {\"source\": \"$source\", \"added_at\": \"$final_added_at\"}" "$SKILLS_YAML"
}

get_all_marketplaces_from_yaml() {
    [[ ! -f "$SKILLS_YAML" ]] && return 1
    yq -r '.claude_code.marketplaces // {} | keys | .[]' "$SKILLS_YAML" 2>/dev/null
}

get_marketplace_source_from_yaml() {
    local name="$1"
    [[ ! -f "$SKILLS_YAML" ]] && return 1
    yq -r ".claude_code.marketplaces.\"$name\".source // \"\"" "$SKILLS_YAML" 2>/dev/null
}

# 写入/更新 plugin 记录（list 里按 name+marketplace 唯一）
# 用法: update_plugin_in_yaml <plugin_name> <marketplace> <scope>
update_plugin_in_yaml() {
    local plugin="$1"
    local marketplace="$2"
    local scope="${3:-user}"

    ensure_claude_code_section

    local timestamp
    timestamp=$(now_timestamp_local)

    # 先删掉同 name@mkt 的旧条目，再 append
    yq -i "del(.claude_code.plugins[] | select(.name == \"$plugin\" and .marketplace == \"$marketplace\"))" "$SKILLS_YAML"
    yq -i ".claude_code.plugins += [{\"name\": \"$plugin\", \"marketplace\": \"$marketplace\", \"scope\": \"$scope\", \"added_at\": \"$timestamp\"}]" "$SKILLS_YAML"
}

# 遍历 yaml plugins，每行输出: <name>\t<marketplace>\t<scope>
get_all_plugins_from_yaml() {
    [[ ! -f "$SKILLS_YAML" ]] && return 1
    yq -r '.claude_code.plugins // [] | .[] | [.name, .marketplace, (.scope // "user")] | @tsv' "$SKILLS_YAML" 2>/dev/null
}

# 从 known_marketplaces.json 读出 claude 已装的 marketplaces（每行一个 name）
cc_installed_marketplaces() {
    [[ ! -f "$CLAUDE_KNOWN_MKT" ]] && return 0
    jq -r 'keys[]' "$CLAUDE_KNOWN_MKT" 2>/dev/null
}

# 读取某个 marketplace 的原始 source 字符串（github 用 repo，否则 url/path）
cc_marketplace_source() {
    local name="$1"
    [[ ! -f "$CLAUDE_KNOWN_MKT" ]] && return 1
    jq -r --arg n "$name" '
        .[$n] | if .source.source == "github" then .source.repo
                elif .source.url then .source.url
                elif .source.path then .source.path
                else (.source | tostring) end
    ' "$CLAUDE_KNOWN_MKT" 2>/dev/null
}

# 解析 claude plugin list 输出，提取 name@marketplace 形式
# claude plugin list 的文本格式未锁定，这里只做容忍式解析
cc_installed_plugins() {
    check_claude_cli || return 1
    local output
    output=$(claude plugin list 2>/dev/null)
    [[ -z "$output" || "$output" == *"No plugins installed"* ]] && return 0
    # 抓取形如 name@marketplace 的 token
    echo "$output" | grep -oE '[A-Za-z0-9._-]+@[A-Za-z0-9._-]+' | sort -u
}

# 从 yaml 部署 Claude Code plugin/marketplace 到本机
# 调用方：sync_from_config（已在那里检查过 claude CLI 存在）
plugin_sync_apply() {
    check_claude_cli || return 1

    print_info "从 yaml 部署 Claude Code plugin/marketplace..."
    echo

    local yaml_mkts actual_mkts
    yaml_mkts=$(get_all_marketplaces_from_yaml)
    actual_mkts=$(cc_installed_marketplaces)

    echo "# marketplaces"
    if [[ -z "$yaml_mkts" ]]; then
        echo "  (yaml 无记录)"
    else
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if echo "$actual_mkts" | grep -qx "$name"; then
                echo "  [skip] $name 已存在"
                continue
            fi
            local source
            source=$(get_marketplace_source_from_yaml "$name")
            print_info "  claude plugin marketplace add \"$source\""
            if ! claude plugin marketplace add "$source"; then
                print_error "marketplace add 失败: $source（继续）"
            fi
        done <<< "$yaml_mkts"
    fi

    echo
    echo "# plugins"
    local yaml_plugins actual_plugins
    yaml_plugins=$(get_all_plugins_from_yaml)
    actual_plugins=$(cc_installed_plugins)
    if [[ -z "$yaml_plugins" ]]; then
        echo "  (yaml 无记录)"
    else
        while IFS=$'\t' read -r name marketplace scope; do
            [[ -z "$name" ]] && continue
            local key="$name@$marketplace"
            if echo "$actual_plugins" | grep -qx "$key"; then
                echo "  [skip] $key 已启用"
                continue
            fi
            print_info "  claude plugin install \"$key\" -s \"$scope\""
            if ! claude plugin install "$key" -s "$scope"; then
                print_error "plugin install 失败: $key（继续）"
            fi
        done <<< "$yaml_plugins"
    fi

    echo
    print_info "Plugin/marketplace 部署完成"
}

# 反向 sync：从 claude 当前状态合并到 skills.yaml（不删除 yaml 中 claude 未启用的条目）
plugin_sync_from_claude() {
    check_claude_cli || return 1
    ensure_claude_code_section

    print_info "从 claude 实际状态导入到 skills.yaml（合并模式）"
    echo

    local added_mkt=0 added_plugin=0

    echo "# marketplaces"
    local mkt_list
    mkt_list=$(cc_installed_marketplaces)
    if [[ -z "$mkt_list" ]]; then
        echo "  (claude 未注册任何 marketplace)"
    else
        local name
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if yq -e ".claude_code.marketplaces.\"$name\"" "$SKILLS_YAML" &>/dev/null; then
                echo "  [skip] $name（yaml 已有）"
                continue
            fi
            local source
            source=$(cc_marketplace_source "$name")
            [[ -z "$source" || "$source" == "null" ]] && source="unknown"
            update_marketplace_in_yaml "$name" "$source" 1
            echo "  [add]  $name ($source)"
            added_mkt=$((added_mkt+1))
        done <<< "$mkt_list"
    fi

    echo
    echo "# plugins"
    local plugin_list
    plugin_list=$(cc_installed_plugins)
    if [[ -z "$plugin_list" ]]; then
        echo "  (claude 未启用任何 plugin)"
    else
        local spec plugin marketplace exists
        while IFS= read -r spec; do
            [[ -z "$spec" ]] && continue
            plugin="${spec%@*}"
            marketplace="${spec##*@}"
            exists=$(yq -r ".claude_code.plugins // [] | map(select(.name == \"$plugin\" and .marketplace == \"$marketplace\")) | length" "$SKILLS_YAML" 2>/dev/null)
            if [[ "${exists:-0}" != "0" ]]; then
                echo "  [skip] $spec（yaml 已有）"
                continue
            fi
            update_plugin_in_yaml "$plugin" "$marketplace" "user"
            echo "  [add]  $spec (scope=user)"
            added_plugin=$((added_plugin+1))
        done <<< "$plugin_list"
    fi

    echo
    print_info "导入完成：新增 $added_mkt 个 marketplace、$added_plugin 个 plugin"
    print_info "（合并模式：yaml 中 claude 未启用的条目未被删除，如需清理请手工编辑 $SKILLS_YAML）"
}

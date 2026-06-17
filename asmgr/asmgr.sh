#!/bin/bash

# asmgr — agent-settings 中央配置仓库的命令行管家
# 统一管理 skills、subagents、项目局域清单与 Claude Code plugin/marketplace，
# 跨 cursor / claude-code / codex / gemini / opencode / pi / omp，一套 scope 模型（默认 cwd / -g / -p / --all）。

# 确保 PATH 包含标准命令路径（避免用户环境 PATH 缺失导致的 command not found）
# 同时包含 Homebrew 默认路径（Apple Silicon: /opt/homebrew/bin）。
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"



# 定位脚本实际所在目录（解析 symlink），用于 source lib/*
_script="${BASH_SOURCE[0]}"
while [[ -L "$_script" ]]; do
    _dir=$(dirname "$_script")
    _script=$(readlink "$_script")
    [[ "$_script" != /* ]] && _script="$_dir/$_script"
done
SCRIPT_DIR=$(cd "$(dirname "$_script")" && pwd)
unset _script _dir

source "$SCRIPT_DIR/lib/core.sh" || { echo "error: failed to load lib/core.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/materialize.sh" || { echo "error: failed to load lib/materialize.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/yaml.sh" || { echo "error: failed to load lib/yaml.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/plugin.sh" || { echo "error: failed to load lib/plugin.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/sources.sh" || { echo "error: failed to load lib/sources.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/project.sh" || { echo "error: failed to load lib/project.sh" >&2; exit 1; }

# 显示帮助信息
show_help() {
    cat << EOF
asmgr (agent-setting manager) — agent-settings 中央配置仓库的命令行管家
（统一管理 skills / subagents / 项目局域清单 / Claude Code plugin）

用法:
    asmgr <command> [options]

scope 约定（所有命令通用，决定操作落在哪里）:
    默认（无 flag）  当前目录项目（读写 ./.<agent>/ 与对应项目清单）
    -g, --global    全局（家目录 ~/.<agent>/）
    -p <dir>        指定项目目录
    --all           全局 + 所有已登记项目（仅 list / status / sync --from-config）

命令（scope 默认均为「当前目录项目」，除非另行说明）:
    add <source> [-a <agents...>] [-s] [-g|-p <dir>] [-c]  添加 skill/subagent 并链接到 agents
    list   [-g | -p <dir> | --all]                列出 skills/项目
    status [--fix] [-g | -p <dir> | --all]        检查链接一致性（--fix 自动修复）
    sync --from-agents [-g | -p <dir>]            从现有安装（link/copy）反向重建配置
    sync --from-config [-g | -p <dir> | --all]    从配置正向重建链接（全局 scope 下 config 即真相：删除未声明的游离链接）
    remove <skill> [-a <agents...>] [-s] [-g|-p <dir>]  从指定 scope 移除 skill/subagent
    remove <skill>（不带 -a/-s/scope）             完全移除（中央目录 + 全局安装 + 配置）

项目局域清单:
    集中存放在 $PROJECTS_DIR/<name>.yaml（文件名由 \$HOME 相对路径派生，/ → __），
    随 agent-settings 一起 git 同步。换新机器一键恢复: asmgr sync --from-config --all

Claude Code plugin / marketplace（仅对 claude-code 生效，依赖 claude CLI）:
    plugin / marketplace 本身请通过官方 claude plugin CLI 安装/卸载（见官方文档）。
    asmgr 不包装安装/卸载，仅在【全局 scope 的 sync】里随带读写 skills.yaml 的 claude_code 段：
      sync --from-agents -g          把 claude 当前 marketplace+plugin 状态合并写入 yaml
      sync --from-config -g / --all  把 yaml 中声明的 marketplace+plugin 部署到本机 claude
    （当前目录 / -p 项目级 sync 只处理 skills，不涉及 plugin/marketplace。）

add 命令参数:
    source              Skill 来源，支持三种格式:
                        - GitHub URL: https://github.com/owner/repo/tree/branch/path/to/skill
                        - 本地路径: /path/to/skill 或 ./skill 或 ../skill
                          (必须以 /, ./, ../ 开头，显式指定路径)
                        - Skill 名称: skill-creator (搜索中央目录)

    -a <agents...>      指定要链接的 agents，支持: cursor, claude-code, codex, gemini, opencode, pi, omp
                        可指定多个，用空格分隔；不指定则仅下载到中央目录

    -g, --global        全局安装（家目录）
                        创建 ~/.cursor/skills/, ~/.claude/skills/, ~/.codex/skills/, ~/.gemini/skills/,
                             ~/.config/opencode/skills/, ~/.pi/agent/skills/, ~/.omp/agent/skills/

    -p, --project <dir> 指定项目根目录（局域安装），默认为当前目录；不能与 -g 同用
                        创建 <dir>/.cursor/skills/, <dir>/.claude/skills/, <dir>/.codex/skills/,
                             <dir>/.gemini/skills/, <dir>/.opencode/skills/, <dir>/.pi/skills/, <dir>/.omp/skills/

    -c, --copy          复制模式（复制整个目录而非符号链接），适用于不支持符号链接的 agent
                        默认为符号链接模式

    -s, --subagent      把中央 agents/ 下的 subagent（目录或 .md）链接到 .claude/agents
                        固定 claude-code、忽略 -a；项目/局域 scope 会写入清单 subagents 段

    注意: 默认是当前目录项目安装并写入项目清单；用 -g 才是全局安装

remove 命令参数:
    -a <agents...>      指定要移除的 agents
    -s, --subagent      移除 subagent（从 .claude/agents 解链 + 更新清单）
    -g, --global        从全局安装移除
    -p, --project <dir> 从指定项目移除
                        不带 -a/-s/-g/-p 时 → 完全移除（中央目录 + 全局安装 + 配置）

示例:
    # ---- add：scope 由 flag 决定 ----
    # 当前目录项目（默认）：创建 ./.cursor/skills/my-skill
    asmgr add ./my-skill -a cursor
    # 全局（-g）：创建 ~/.cursor/skills/my-skill
    asmgr add ./my-skill -a cursor -g
    # 指定项目（-p）：创建 ~/projects/foo/.cursor/skills/my-skill
    asmgr add ./my-skill -a cursor -p ~/projects/foo
    # 复制模式（-c，适用于不支持符号链接的 agent），可与 symlink 混用
    asmgr add ./my-skill -a cursor -g        # symlink
    asmgr add ./my-skill -a codex  -g -c     # copy
    # 多 agents / 从 GitHub 添加
    asmgr add skill-creator -a cursor claude-code -g
    asmgr add https://github.com/anthropics/skills/tree/main/skills/skill-creator -a cursor

    # ---- 全局 skills 的查看 / 检查 / 同步（注意都要 -g）----
    asmgr list -g                  # 列出全局安装的 skills
    asmgr status -g                # 检查全局链接一致性
    asmgr status -g --fix          # 并自动修复
    asmgr sync --from-agents -g    # 首次/迁移：从全局现有安装反向生成 skills.yaml（含 plugin）
    asmgr sync --from-config -g    # 仅按 skills.yaml 重建全局链接（含 plugin）

    # ---- 项目局域 skill/subagent 工作流（默认 = 当前目录项目）----
    cd ~/Projects/foo
    asmgr add paper-writing-mentor -a claude-code codex   # 登记 skill，写入项目清单
    asmgr add paper-writing-mentor -s                     # 登记 subagent → .claude/agents
    asmgr sync --from-agents                              # 扫当前目录现有链接，生成项目清单
    asmgr list                                            # 查看当前项目清单
    asmgr status --fix                                    # 检查并修复当前项目
    asmgr remove paper-writing-mentor -a claude-code codex
    asmgr remove paper-writing-mentor -s

    # ---- 跨机恢复 / 完全移除 ----
    asmgr sync --from-config --all     # git pull agent-settings 后，一键恢复全局 + 所有项目
    asmgr remove skill-creator         # 完全移除（中央目录 + 全局安装 + 配置）
    asmgr remove skill-creator -a cursor -g            # 仅从全局 cursor 移除
    asmgr remove skill-creator -a cursor -p ~/projects/foo  # 仅从指定项目移除

    # ---- Claude Code plugin 工作流 ----
    #   1) 用官方 CLI 安装 marketplace 和 plugin：
    #        claude plugin marketplace add openai/codex-plugin-cc
    #        claude plugin install codex@openai-codex
    #   2) 写入 yaml 以便跨机同步（全局 scope 才会带上 plugin）：
    #        asmgr sync --from-agents -g
    #   3) 新机器 clone agent-settings 后：
    #        asmgr sync --from-config -g      # 或 --all

中央存储目录: $SKILLS_DIR
配置文件: $SKILLS_YAML
Claude Code plugins: $CLAUDE_PLUGINS_DIR
EOF
}


# 添加 skill 命令
cmd_add() {
    local source=""
    local agents=()
    local is_global=false
    local project_dir=""
    local use_copy=false
    local source_by_name=false
    local is_subagent=false

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
                require_project_dir_arg "$2" || return 1
                project_dir="$2"
                shift 2
                ;;
            -c|--copy)
                use_copy=true
                shift
                ;;
            -s|--subagent)
                is_subagent=true
                shift
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                return 1
                ;;
        esac
    done

    # 解析 scope → base 目录（含 -g/-p 互斥与 -p 存在性校验）
    resolve_base_dir "$is_global" "$project_dir" || return 1
    local base_dir="$RESOLVED_BASE_DIR"

    # subagent 分支：在中央 agents/ 解析，链接到 .claude/agents，记录到项目清单 subagents 段
    if [[ "$is_subagent" == true ]]; then
        if [[ "$use_copy" == true ]]; then
            print_warn "Subagent 不支持 copy 模式，按 link 处理"
        fi
        if [[ ${#agents[@]} -gt 0 ]]; then
            print_warn "Subagent 固定链接到 claude-code(.claude/agents)，忽略 -a 指定的: ${agents[*]}"
        fi
        local sub_name
        sub_name=$(resolve_subagent_name "$source") || return 1
        if ! link_subagent_to_project "$base_dir" "$sub_name"; then
            print_error "Subagent 链接失败"
            return 1
        fi
        if [[ "$is_global" == true ]]; then
            print_warn "全局 Subagent 暂不写入配置记录（每机一次，非跨机痛点）"
        else
            local manifest
            manifest="$(project_touch_manifest "$base_dir")"
            pm_update_entry "$manifest" "subagents" "$sub_name" "link" "claude-code"
            print_info "已记录到项目清单: $manifest"
        fi
        info_done "添加" "$sub_name"
        return 0
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
            print_info "找到 Skill: $found_path"
            # 直接使用中央目录中的 skill，不需要复制
            if ! link_from_central "$found_path"; then
                return 1
            fi
            source_by_name=true
        else
            print_error "未找到 Skill '$source'"
            print_error "请提供："
            print_error "  - GitHub URL: https://github.com/owner/repo/tree/branch/path/to/skill"
            print_error "  - 本地路径: /path/to/skill 或 ./skill"
            print_error "  - 已存在的 Skill 名称（将从 $SKILLS_DIR 搜索）"
            return 1
        fi
    fi

    # 创建符号链接或复制（传递 base_dir）
    local installed_agents=()
    local failed_agents=()
    local install_scope="project"
    [[ "$is_global" == true ]] && install_scope="global"
    if [[ "$use_copy" == true ]]; then
        copy_to_agents "$install_scope" "$base_dir" "${agents[@]}"
    else
        create_symlinks "$install_scope" "$base_dir" "${agents[@]}"
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
    if [[ ${#installed_agents[@]} -gt 0 ]]; then
        local method="link"
        [[ "$use_copy" == true ]] && method="copy"
        if [[ "$is_global" == true ]]; then
            update_skills_yaml "$SKILL_NAME" "$source_str" 1 "$method" "${installed_agents[@]}"
        else
            # 项目/本地 scope：记录到项目清单 skills 段（path 由 base_dir 现场派生）
            local manifest
            manifest="$(project_touch_manifest "$base_dir")"
            pm_update_entry "$manifest" "skills" "$SKILL_NAME" "$method" "${installed_agents[@]}"
            print_info "已记录到项目清单: $manifest"
        fi
    fi

    if [[ ${#failed_agents[@]} -gt 0 ]]; then
        print_warn "以下 agents 未成功安装: ${failed_agents[*]}"
    fi

    if [[ ${#agents[@]} -gt 0 && ${#installed_agents[@]} -eq 0 ]]; then
        print_error "未能成功安装到任何 agent"
        return 1
    fi

    info_done "添加" "$SKILL_NAME"
    return 0
}

# 当前项目清单的列出动作（带 cwd 专属表头），供 run_on_cwd_manifest 调用
_list_cwd_one() {
    echo "当前项目:"; echo "========="; echo
    project_list_one "$1"
}

# 列出命令（默认=当前目录项目；-g 全局；-p 指定项目；--all 全部）
cmd_list() {
    local scope="cwd" project_dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -g|--global) scope="global"; shift ;;
            -p|--project)
                require_project_dir_arg "$2" || return 1
                project_dir="$2"; scope="project"; shift 2 ;;
            --all) scope="all"; shift ;;
            *) print_error "未知参数: $1"; return 1 ;;
        esac
    done

    case "$scope" in
        global)
            list_global
            ;;
        cwd)
            run_on_cwd_manifest _list_cwd_one
            ;;
        project)
            local d m; d=$(normalize_base_dir "$project_dir"); m="$(project_manifest_file "$d")"
            if [[ -f "$m" ]]; then project_list_one "$m"; else warn_no_manifest "$m"; fi
            ;;
        all)
            list_global
            echo; echo "已注册的项目:"; echo "============="; echo
            local p _any_proj=0
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                _any_proj=1
                project_list_one "$PROJECTS_DIR/$p.yaml"
            done <<< "$(pm_list_projects)"
            [[ $_any_proj -eq 0 ]] && print_warn "没有已登记的项目"
            ;;
    esac
    return 0
}

# 打印一个 skill 在某组 agents 下的安装状态行（list 用）。
# 宽松判定：link 只问「目标是不是符号链接」（指向何处由 status 负责），copy 问「是否实体目录」。
# 用法: _list_agents_status <skill_name> <method:link|copy> <agents_lines>
_list_agents_status() {
    local skill_name="$1" method="$2" agents="$3"
    local src="$SKILLS_DIR/$skill_name"
    local agent agent_dir link_path cls state actual
    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        agent_dir=$(get_agent_dir "$agent" "$HOME" "global" 2>/dev/null)
        link_path="$agent_dir/$skill_name"
        cls=$(mat_classify "$link_path" "$src" "$method")
        IFS=$'\t' read -r state actual <<< "$cls"
        if [[ "$method" == "link" ]]; then
            case "$state" in
                ok|wrong_target) echo -e "        ${GREEN}✓${NC} $agent (symlink)" ;;
                wrong_type)      echo -e "        ${RED}✗${NC} $agent (实际非 symlink)" ;;
                *)               echo -e "        ${RED}✗${NC} $agent (缺失)" ;;
            esac
        else
            case "$state" in
                ok)         echo -e "        ${GREEN}✓${NC} $agent (copy)" ;;
                wrong_type) echo -e "        ${RED}✗${NC} $agent (实际非 copy)" ;;
                *)          echo -e "        ${RED}✗${NC} $agent (缺失)" ;;
            esac
        fi
    done <<< "$agents"
}

# 列出所有全局 skills 及其安装状态
list_global() {
    if [[ ! -f "$SKILLS_YAML" ]]; then
        print_warn "配置文件不存在: $SKILLS_YAML"
        print_info "运行 'asmgr sync --from-agents' 从全局 agents 安装状态（link/copy）生成配置"
        return 0
    fi

    local skills
    skills=$(get_all_skills)

    if [[ -z "$skills" ]]; then
        print_warn "没有已注册的 Skills"
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
                _list_agents_status "$skill_name" "link" "$link_agents"
            else
                echo "        (无)"
            fi

            echo "      复制 (copy):"
            if [[ -n "$copy_agents" ]]; then
                _list_agents_status "$skill_name" "copy" "$copy_agents"
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
# 检查某 skill 在一组 agents 下、某 method（link|copy）的全局安装一致性（返回 0=全 OK, 1=有问题）。
# 全局侧的逐条检查器，对应 project.sh 的 _status_check_entry（消息/缩进/修复命令各自独立）。
_status_check_global_entry() {
    local skill_name="$1" skill_source="$2" method="$3" agents="$4" fix_mode="$5"
    local issue=0 agent agent_dir link_path cls state actual
    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        agent_dir=$(get_agent_dir "$agent" "$HOME" "global" 2>/dev/null)
        [[ -z "$agent_dir" ]] && continue
        link_path="$agent_dir/$skill_name"
        cls=$(mat_classify "$link_path" "$skill_source" "$method")
        IFS=$'\t' read -r state actual <<< "$cls"
        if [[ "$method" == "link" ]]; then
            case "$state" in
                ok)
                    print_status_tag OK "$skill_name -> $agent" ;;
                wrong_target)
                    print_status_tag WRONG "$skill_name -> $agent (链接目标错误: $actual)"
                    issue=1
                    if [[ $fix_mode -eq 1 && -d "$skill_source" && -d "$agent_dir" ]]; then
                        if /bin/rm "$link_path" && /bin/ln -sf "$skill_source" "$link_path"; then echo "  已修复"; else print_error "修复失败: $link_path"; fi
                    elif [[ $fix_mode -eq 1 ]]; then echo "  无法修复: 源或目标目录不存在"; fi ;;
                wrong_type)
                    print_status_tag WRONG "$skill_name -> $agent (期望链接，实际为目录/文件)"
                    issue=1
                    if [[ $fix_mode -eq 1 && -d "$skill_source" && -d "$agent_dir" ]]; then
                        if /bin/rm -rf "$link_path" && /bin/ln -sf "$skill_source" "$link_path"; then echo "  已修复"; else print_error "修复失败: $link_path"; fi
                    elif [[ $fix_mode -eq 1 ]]; then echo "  无法修复: 源或目标目录不存在"; fi ;;
                missing)
                    print_status_tag MISSING "$skill_name -> $agent (配置有，链接不存在)"
                    issue=1
                    if [[ $fix_mode -eq 1 && -d "$skill_source" && -d "$agent_dir" ]]; then
                        if /bin/ln -sf "$skill_source" "$link_path"; then echo "  已创建链接"; else print_error "创建链接失败: $link_path"; fi
                    elif [[ $fix_mode -eq 1 ]]; then echo "  无法修复: 源或目标目录不存在"; fi ;;
            esac
        else
            case "$state" in
                ok)
                    print_status_tag OK "$skill_name -> $agent (copy)" ;;
                wrong_type)
                    print_status_tag WRONG "$skill_name -> $agent (期望 copy，实际非目录)"
                    issue=1
                    if [[ $fix_mode -eq 1 && -d "$skill_source" && -d "$agent_dir" ]]; then
                        if /bin/rm -rf "$link_path" && /bin/cp -r "$skill_source" "$link_path"; then echo "  已修复"; else print_error "修复失败: $link_path"; fi
                    elif [[ $fix_mode -eq 1 ]]; then echo "  无法修复: 源或目标目录不存在"; fi ;;
                missing)
                    print_status_tag MISSING "$skill_name -> $agent (配置有，copy 不存在)"
                    issue=1
                    if [[ $fix_mode -eq 1 && -d "$skill_source" && -d "$agent_dir" ]]; then
                        if /bin/cp -r "$skill_source" "$link_path"; then echo "  已复制"; else print_error "复制失败: $skill_source -> $link_path"; fi
                    elif [[ $fix_mode -eq 1 ]]; then echo "  无法修复: 源或目标目录不存在"; fi ;;
            esac
        fi
    done <<< "$agents"
    return $issue
}

# 检查单个 skill 的所有已配置安装（link + copy agents）
# 返回 0=全部一致, 1=有不一致
status_check_configured_skill() {
    local skill_name="$1"
    local fix_mode="$2"
    local found_issue=0

    local skill_source="$SKILLS_DIR/$skill_name"
    local link_agents copy_agents
    link_agents=$(get_skill_agents_link "$skill_name")
    copy_agents=$(get_skill_agents_copy "$skill_name")

    if [[ -z "$link_agents" && -z "$copy_agents" ]]; then
        return 0
    fi

    _status_check_global_entry "$skill_name" "$skill_source" "link" "$link_agents" "$fix_mode" || found_issue=1
    _status_check_global_entry "$skill_name" "$skill_source" "copy" "$copy_agents" "$fix_mode" || found_issue=1

    return $found_issue
}

# 判定全局某条 (skill, method, agent) 链接是否游离：skills.yaml 无此 skill，
# 或该 method 对应字段未列出此 agent。返回 0=游离, 1=已登记。
_skill_orphan_at() {
    local skill_name="$1" method="$2" agent="$3"
    skill_exists_in_yaml "$skill_name" || return 0
    local field
    field=$(agents_field_for_method "$method")
    local listed_agents=() line
    while IFS= read -r line; do
        [[ -n "$line" ]] && listed_agents+=("$line")
    done <<< "$(get_skill_agents_field "$skill_name" "$field")"
    has_agent_in_list "$agent" "${listed_agents[@]}" && return 1
    return 0
}

# 枚举全局游离链接：指向中央 SKILLS_DIR 但 skills.yaml 未声明的条目。
# 每行输出 "<agent>\t<method>\t<name>"。供 status（报告/登记）与 sync（删除）共用。
scan_global_orphans() {
    local agent agent_dir method skill_name
    for agent in $SUPPORTED_AGENTS; do
        agent_dir=$(get_agent_dir "$agent" "$HOME" "global")
        [[ ! -d "$agent_dir" ]] && continue
        while IFS=$'\t' read -r method skill_name; do
            [[ -z "$method" ]] && continue
            _skill_orphan_at "$skill_name" "$method" "$agent" \
                && printf '%s\t%s\t%s\n' "$agent" "$method" "$skill_name"
        done <<< "$(mat_scan_central_links "$agent_dir" "$SKILLS_DIR" 1)"
    done
}

# 扫描孤立的安装（agent 目录存在但配置中未声明）
# 返回 0=无孤立, 1=有孤立。--fix 把游离链接登记进配置（reality→config，对齐 --from-agents）。
status_scan_orphans() {
    local fix_mode=$1
    local found_issue=0

    echo
    echo "检查孤立链接/复制..."

    local agent method skill_name
    while IFS=$'\t' read -r agent method skill_name; do
        [[ -z "$agent" ]] && continue
        print_status_tag ORPHAN "$skill_name @ $agent ($method 存在，配置无)"
        found_issue=1
        if [[ $fix_mode -eq 1 ]]; then
            update_skills_yaml "$skill_name" "unknown" 0 "$method" "$agent"
            echo "  已添加到配置"
        elif [[ "$method" == "copy" ]]; then
            # copy 游离 sync --from-config 不会清理（无法与用户数据区分），提示手动处置
            echo "  copy 游离：--fix 登记或手动删除"
        fi
    done <<< "$(scan_global_orphans)"

    return $found_issue
}

# 状态命令（默认=当前目录项目；-g 全局；-p 指定项目；--all 全部）
cmd_status() {
    local fix_mode=0 scope="cwd" project_dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix) fix_mode=1; shift ;;
            -g|--global) scope="global"; shift ;;
            -p|--project)
                require_project_dir_arg "$2" || return 1
                project_dir="$2"; scope="project"; shift 2 ;;
            --all) scope="all"; shift ;;
            *) print_error "未知参数: $1"; return 1 ;;
        esac
    done

    case "$scope" in
        global)
            status_global "$fix_mode"
            ;;
        cwd)
            run_on_cwd_manifest project_status_one "$fix_mode"
            ;;
        project)
            local d m; d=$(normalize_base_dir "$project_dir"); m="$(project_manifest_file "$d")"
            if [[ -f "$m" ]]; then project_status_one "$m" "$fix_mode"; else warn_no_manifest "$m"; fi
            ;;
        all)
            local grc prc
            status_global "$fix_mode"; grc=$?
            echo; echo "检查项目链接一致性..."; echo "====================="; echo
            project_status_all "$fix_mode"; prc=$?
            [[ $grc -ne 0 || $prc -ne 0 ]] && return 1 || return 0
            ;;
    esac
}

# 检查全局配置与实际全局链接/复制的一致性
status_global() {
    local fix_mode="${1:-0}"

    echo "检查 Skills 一致性状态..."
    echo "========================="
    echo

    local has_issues=0

    if [[ -f "$SKILLS_YAML" ]]; then
        local skills
        skills=$(get_all_skills)
        while IFS= read -r skill_name; do
            [[ -z "$skill_name" ]] && continue
            status_check_configured_skill "$skill_name" "$fix_mode" || has_issues=1
        done <<< "$skills"
    fi

    status_scan_orphans "$fix_mode" || has_issues=1

    echo
    if [[ $has_issues -eq 0 ]]; then
        echo -e "${GREEN}所有检查通过，配置与实际状态一致${NC}"
    else
        if [[ $fix_mode -eq 0 ]]; then
            echo "发现不一致，运行 'asmgr status --fix' 自动修复"
        else
            info_done "修复"
        fi
    fi

    # 缺陷②修复：发现不一致即返回非零，与 project_status_one 的退出码语义对齐
    # （检测期已置位的 has_issues；--fix 后仍返回非零，与项目侧一致）。
    return $has_issues
}

# 同步命令
cmd_sync() {
    local mode="" scope="cwd" project_dir=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-agents) mode="from-agents"; shift ;;
            --from-config) mode="from-config"; shift ;;
            -g|--global) scope="global"; shift ;;
            -p|--project)
                require_project_dir_arg "$2" || return 1
                project_dir="$2"; scope="project"; shift 2 ;;
            --all) scope="all"; shift ;;
            *)
                print_error "未知参数: $1"
                echo "用法: asmgr sync --from-agents | --from-config [-g | -p <dir> | --all]"
                return 1
                ;;
        esac
    done

    if [[ -z "$mode" ]]; then
        print_error "请指定同步方向: --from-agents 或 --from-config"
        echo "  --from-agents  从现有安装状态（link/copy）重建配置（默认=当前目录项目；-g=全局 skills.yaml）"
        echo "  --from-config  从配置创建符号链接（默认=当前项目；-g=全局；--all=全局+所有项目）"
        return 1
    fi

    if [[ "$mode" == "from-agents" ]]; then
        case "$scope" in
            global) sync_from_agents ;;
            project) local d; d=$(normalize_base_dir "$project_dir"); project_scan_one "$d" ;;
            cwd) project_scan_one "$(/bin/pwd)" ;;
            all) print_error "--all 不适用于 --from-agents（无法发现所有项目目录）"; return 1 ;;
        esac
    else
        case "$scope" in
            global) sync_from_config ;;
            project) local d; d=$(normalize_base_dir "$project_dir"); project_deploy_one "$(project_manifest_file "$d")" ;;
            cwd)
                run_on_cwd_manifest project_deploy_one
                ;;
            all)
                local grc prc
                sync_from_config; grc=$?
                echo; print_info "部署所有项目..."
                project_deploy_all; prc=$?
                [[ $grc -ne 0 || $prc -ne 0 ]] && return 1 || return 0
                ;;
        esac
    fi
}

# 从全局 agents 安装状态（link/copy）重建配置
sync_from_agents() {
    print_info "从 agents 安装状态（link/copy）重建配置文件..."

    # 初始化配置文件；重扫只让安装列表跟随实态，不抹掉已有 source/added_at。
    init_skills_yaml
    reset_all_skill_install_entries

    local found_any=0

    # 扫描所有 agent 目录（仅全局）
    for agent in $SUPPORTED_AGENTS; do
        local agent_dir
        agent_dir=$(get_agent_dir "$agent" "$HOME" "global")

        [[ ! -d "$agent_dir" ]] && continue

        local method skill_name
        while IFS=$'\t' read -r method skill_name; do
            [[ -z "$method" ]] && continue
            print_info "发现: $skill_name -> $agent ($method)"
            update_skills_yaml "$skill_name" "unknown" 0 "$method" "$agent"
            found_any=1
        done <<< "$(mat_scan_central_links "$agent_dir" "$SKILLS_DIR" 1)"
    done

    if [[ $found_any -eq 0 ]]; then
        print_warn "未发现任何符号链接"
    else
        print_info "配置文件已更新: $SKILLS_YAML"
    fi

    # 顺带把 Claude Code plugin/marketplace 的实际状态合并进 yaml
    if command -v claude &>/dev/null; then
        echo
        plugin_sync_from_claude
    else
        echo
        print_info "未检测到 claude CLI，跳过 Claude Code plugin/marketplace 导入"
    fi
}

# 删除全局游离链接（指向中央目录但 skills.yaml 未声明）。config→reality 的清理半边。
# 只删符号链接：copy 的“游离”靠同名碰撞判定（见 mat_scan_central_links），无法与用户
# 自有目录区分，rm -rf 会误删数据；与 mat_deploy_copy 保护实体占位的策略对齐，copy 游离
# 仅由 status 报告、交用户处置。
sync_prune_orphans() {
    local agent method skill_name agent_dir
    while IFS=$'\t' read -r agent method skill_name; do
        [[ -z "$agent" ]] && continue
        [[ "$method" != "link" ]] && continue
        agent_dir=$(get_agent_dir "$agent" "$HOME" "global")
        if /bin/rm -f "$agent_dir/$skill_name"; then
            print_info "  ✓ 已删除游离链接: $skill_name @ $agent"
        else
            print_error "删除游离链接失败: $agent_dir/$skill_name"
        fi
    done <<< "$(scan_global_orphans)"
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
        print_warn "没有已注册的 Skills"
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

        local link_agents copy_agents
        link_agents=$(get_skill_agents_link "$skill_name")
        copy_agents=$(get_skill_agents_copy "$skill_name")

        # 全局 scope = 以 $HOME 为 base，复用共享物化逻辑
        _project_deploy_skill "$HOME" "$skill_name" "$skill_source" "$link_agents" "$copy_agents" "global"
    done <<< "$skills"

    # config 即真相：删除指向中央目录但 yaml 未声明的游离链接（对齐项目侧 --fix 行为）
    sync_prune_orphans

    info_done "同步"

    # 如果 yaml 里有 claude_code 段，就同时部署 marketplace/plugin
    local has_cc_section
    has_cc_section=$(yq -r '.claude_code // "" | length' "$SKILLS_YAML" 2>/dev/null)
    if [[ -n "$has_cc_section" && "$has_cc_section" != "0" ]]; then
        echo
        if command -v claude &>/dev/null; then
            plugin_sync_apply
        else
            print_warn "yaml 中包含 claude_code 段，但未检测到 claude CLI，跳过 plugin/marketplace 部署"
        fi
    fi
}

# 移除 skill 命令
# 完全移除 skill（中央目录 + 所有全局安装 + 配置记录）
remove_skill_completely() {
    local skill_name="$1"
    local skill_dir="$SKILLS_DIR/$skill_name"

    local has_record=0
    if skill_exists_in_yaml "$skill_name"; then
        has_record=1
    fi
    if [[ ! -d "$skill_dir" ]] && [[ $has_record -eq 0 ]]; then
        print_error "未找到 Skill '$skill_name'"
        return 1
    fi

    print_warn "即将完全移除 Skill: $skill_name"
    echo
    echo "将执行以下操作:"
    [[ -d "$skill_dir" ]] && echo "  - 删除中央目录: $skill_dir"
    echo "  - 删除所有全局安装（link/copy）"
    echo "  - 从配置文件移除记录"
    echo
    if ! prompt_yes_no "是否移除? (y/N) " "N"; then
        print_info "取消操作"
        return 0
    fi

    print_info "移除 Skill: $skill_name"

    for agent in $SUPPORTED_AGENTS; do
        local agent_dir link_path
        agent_dir=$(get_agent_dir "$agent" "$HOME" "global")
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

    if [[ -d "$skill_dir" ]]; then
        if /bin/rm -rf "$skill_dir"; then
            print_info "  已删除目录: $skill_dir"
        else
            print_error "  删除目录失败: $skill_dir"
        fi
    fi

    remove_skill_from_yaml "$skill_name"
    print_info "  已从配置移除"
    info_done "移除" "Skill '$skill_name'"
}

# 从指定 agents 移除 skill 安装
# 用法: remove_skill_from_agents <skill_name> <base_dir> <mode:global|project> <agents...>
remove_skill_from_agents() {
    local skill_name="$1"
    local base_dir="$2"
    local mode="$3"
    shift 3
    local agents=("$@")

    for agent in "${agents[@]}"; do
        local agent_dir
        agent_dir=$(get_agent_dir "$agent" "$base_dir" "$mode" 2>/dev/null)
        if [[ -z "$agent_dir" ]]; then
            print_error "不支持的 Agent: $agent"
            continue
        fi

        local target_path="$agent_dir/$skill_name"
        local actual_method=""

        if [[ -L "$target_path" ]]; then
            if /bin/rm "$target_path"; then
                print_info "  ✓ 已删除符号链接: $target_path"
                actual_method="link"
            else
                print_error "  删除失败: $target_path"
                continue
            fi
        elif [[ -d "$target_path" ]]; then
            print_warn "将删除目录: $target_path"
            if prompt_yes_no "是否删除? (y/N) " "N"; then
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
            echo "  - $agent: 未找到安装"
            continue
        fi

        if [[ "$mode" == "global" && -f "$SKILLS_YAML" ]]; then
            if skill_exists_in_yaml "$skill_name"; then
                local field
                field=$(agents_field_for_method "$actual_method")
                remove_agent_from_skill_field "$skill_name" "$field" "$agent"
                preserve_skill_install_entry_if_empty "$skill_name"
            fi
        elif [[ "$mode" == "project" ]]; then
            local manifest
            manifest="$(project_manifest_file "$base_dir")"
            if [[ -f "$manifest" ]]; then
                local field
                field=$(agents_field_for_method "$actual_method")
                pm_remove_entry_agent "$manifest" "skills" "$skill_name" "$field" "$agent"
                pm_remove_entry_if_empty "$manifest" "skills" "$skill_name"
            fi
        fi
    done

    if [[ "$mode" == "project" ]]; then
        local manifest
        manifest="$(project_manifest_file "$base_dir")"
        [[ -f "$manifest" ]] && pm_prune_project "$manifest" && print_info "项目清单已空，已删除: $manifest"
    fi

    info_done "移除"
}

cmd_remove() {
    local skill_name=""
    local agents=()
    local is_global=false
    local project_dir=""
    local is_subagent=false

    if [[ $# -eq 0 ]]; then
        print_error "缺少 Skill 名称"
        echo "用法:"
        echo "  asmgr remove <skill>                    # 完全移除"
        echo "  asmgr remove <skill> -a <agents>        # 仅从指定 agents 移除（全局）"
        echo "  asmgr remove <skill> -a <agents> -g     # 从全局安装移除"
        echo "  asmgr remove <skill> -a <agents> -p <dir> # 从指定项目移除"
        return 1
    fi

    skill_name="$1"
    shift

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
                require_project_dir_arg "$2" || return 1
                project_dir="$2"
                shift 2
                ;;
            -s|--subagent)
                is_subagent=true
                shift
                ;;
            *)
                print_error "未知参数: $1"
                return 1
                ;;
        esac
    done

    if [[ "$is_global" == true && -n "$project_dir" ]]; then
        print_error "-g 和 -p 参数不能同时使用"
        return 1
    fi

    # subagent 分支：从 .claude/agents 解链 + 更新项目清单 subagents 段
    if [[ "$is_subagent" == true ]]; then
        resolve_base_dir "$is_global" "$project_dir" || return 1
        local base_dir="$RESOLVED_BASE_DIR"
        local sub_name
        sub_name=$(resolve_subagent_name "$skill_name") || sub_name="$skill_name"
        unlink_subagent_from_project "$base_dir" "$sub_name"
        if [[ "$is_global" != true ]]; then
            local manifest
            manifest="$(project_manifest_file "$base_dir")"
            if [[ -f "$manifest" ]]; then
                pm_remove_entry_agent "$manifest" "subagents" "$sub_name" "agents_link" "claude-code"
                pm_remove_entry_if_empty "$manifest" "subagents" "$sub_name"
                pm_prune_project "$manifest" && print_info "项目清单已空，已删除: $manifest"
            fi
        fi
        info_done "移除"
        return 0
    fi

    if [[ ${#agents[@]} -eq 0 ]]; then
        remove_skill_completely "$skill_name"
    else
        resolve_base_dir "$is_global" "$project_dir" || return 1
        local base_dir="$RESOLVED_BASE_DIR"
        if [[ "$is_global" == true ]]; then
            print_info "从全局安装移除 Skill: $skill_name"
        elif [[ -n "$project_dir" ]]; then
            print_info "从项目 $base_dir 移除 Skill: $skill_name"
        else
            print_info "从当前目录移除 Skill: $skill_name"
        fi

        local mode
        if [[ "$is_global" == true ]]; then
            mode="global"
        else
            mode="project"
        fi

        remove_skill_from_agents "$skill_name" "$base_dir" "$mode" "${agents[@]}"
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

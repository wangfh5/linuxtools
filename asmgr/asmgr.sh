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

# 本机配置（可选）。config.sh 不纳入版本控制。
if [[ -z "${ASMGR_HOME:-}" && -f "$SCRIPT_DIR/config.sh" ]]; then
    source "$SCRIPT_DIR/config.sh" || exit 1
fi

source "$SCRIPT_DIR/lib/core.sh" || { echo "error: failed to load lib/core.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/interactive.sh" || { echo "error: failed to load lib/interactive.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/materialize.sh" || { echo "error: failed to load lib/materialize.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/yaml.sh" || { echo "error: failed to load lib/yaml.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/plugin.sh" || { echo "error: failed to load lib/plugin.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/sources.sh" || { echo "error: failed to load lib/sources.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/project.sh" || { echo "error: failed to load lib/project.sh" >&2; exit 1; }

# 显示顶层帮助（精简总览 + 关键行为前置；单命令详情见 show_help_<cmd>）
show_help() {
    cat << EOF
asmgr (agent-setting manager) — agent-settings 中央配置仓库的命令行管家
（统一管理 skills / subagents / 项目局域清单 / Claude Code plugin）

用法:
    asmgr <command> [options]
    asmgr help <command>    查看单个命令的详细帮助（如: asmgr help add）

scope 约定（所有命令通用。默认 = 当前目录项目，-g 才是全局）:
    默认（无 flag）  当前目录项目: 读写 ./.<agent>/，登记写进项目清单
    -g, --global    全局: 家目录 ~/.<agent>/，登记写进 skills.yaml
    -p <dir>        指定项目根目录
    --all           全局 + 所有已登记项目（仅 list / status / sync --from-config 支持）

命令:
    add      添加 skill/subagent 并链接到 agents（省略 source 进入交互选择器）
    list     列出 skills / 项目清单及安装状态
    status   检查配置与实际链接的一致性（--fix 自动修复）
    sync     配置与实际安装双向同步（--from-agents 反向 / --from-config 正向）
    remove   移除 skill/subagent

[!] 关键行为（最容易被误读，操作前务必确认）:
    1. add <显式 source> 不带 -a  →  仅下载/复制到中央目录，不建任何链接
    2. remove <skill> 不带 flag  →  完全移除: 中央目录 + 全局安装 + 配置记录
    3. status --fix 的游离处置随 scope 相反  →  全局: 登记进配置; 项目: 直接删除链接
    4. sync --from-config -g/--all 以配置为真相  →  删除 yaml 未声明的全局游离链接
    5. 中央 skills/ 的增删一律走 asmgr，请勿手工 cp/rm

路径（中央仓库根 = agent-settings，可在 config.sh 用 ASMGR_HOME 改）:
    skills/        中央 skill 实体 + skills.yaml（全局注册表）
    agents/        中央 subagent 实体
    projects/      项目清单（每项目一个 <name>.yaml）
EOF
}

# add — 详细帮助
show_help_add() {
    cat << EOF
asmgr add — 添加 skill/subagent 到中央目录并链接到 agents

用法:
    asmgr add [source] [-a <agents...>] [-s] [-g|-p <dir>] [-c]

scope（决定链接落点与登记文件）:
    默认（无 flag）  当前目录项目: 链接建在 ./.<agent>/，登记写进项目清单
    -g, --global    全局: 链接建在 ~/.<agent>/，登记写进 skills.yaml
    -p <dir>        指定项目根目录（不能与 -g 同用）

source（可省略）:
    省略          从中央目录进入交互式选择器（skills → agents → scope → link/copy；
                  有 fzf 且在 TTY 时多选，否则退化为编号输入）
    GitHub URL    https://github.com/owner/repo
                  https://github.com/owner/repo/tree/branch
                  https://github.com/owner/repo/tree/branch/path/to/skill
    本地路径      /path/to/skill 或 ./skill 或 ../skill（必须以 / ./ ../ 开头，显式指定）
    Skill 名称    在中央目录搜索（支持模糊；多个命中时交互选择）

参数:
    -a <agents...>    指定要链接的 agents，空格分隔多个:
                      cursor claude-code codex gemini opencode pi omp
                      交互模式下省略则进入 agents 选择器
    -c, --copy        复制整个目录而非符号链接（默认 symlink；交互模式下跳过 link/copy 选择）
    -s, --subagent    链接中央 agents/ 下【已存在】的 subagent（目录或 .md，按名称，不下载）到
                      .claude/agents；固定 claude-code、忽略 -a、不支持 -c；
                      项目 scope 写入清单 subagents 段；-g 不写配置记录（每机一次的本地动作）

[!] 关键行为: 显式传入 source（GitHub URL / 本地路径）且不带 -a 时，仅把 skill 落入
    中央目录（并在 skills.yaml 登记 source），不创建任何链接、不装进任何 agent；
    按名称搜索（条目已在中央目录）时不带 -a 则无任何实际操作。两者均不报错。
    要安装必须显式 -a，或省略 source 走交互选择器。
    中央 skills/ 的增删一律走 asmgr（add/remove），请勿手工 cp/rm。

链接目标目录（<base> = 项目目录或 \$HOME）:
    cursor       <base>/.cursor/skills
    claude-code  <base>/.claude/skills
    codex        <base>/.agents/skills
    gemini       <base>/.gemini/skills
    opencode     <base>/.opencode/skills（全局: ~/.config/opencode/skills）
    pi           <base>/.pi/skills（全局: ~/.pi/agent/skills）
    omp          <base>/.omp/skills（全局: ~/.omp/agent/skills）

示例:
    asmgr add                                  # 交互选择 skills / agents / scope / link-copy
    asmgr add ./my-skill -a cursor             # 当前目录项目: ./.cursor/skills/my-skill
    asmgr add ./my-skill -a cursor -g          # 全局: ~/.cursor/skills/my-skill
    asmgr add ./my-skill -a cursor -p ~/p/foo  # 指定项目
    asmgr add skill-creator -a cursor claude-code -g   # 按名称从中央目录链接
    asmgr add https://github.com/anthropics/skills/tree/main/skills/skill-creator -a cursor
    asmgr add ./my-skill                       # 仅复制进中央目录，不建任何链接（见上关键行为）
    asmgr add some-subagent -s                 # 链接 subagent 到 ./.claude/agents
EOF
}

# list — 详细帮助
show_help_list() {
    cat << EOF
asmgr list — 列出 skills / 项目清单及安装状态

用法:
    asmgr list [-g | -p <dir> | --all]

scope:
    默认（无 flag）  当前目录项目: 显示其清单内容（无清单则提示）
    -g, --global    全局: skills.yaml 中每个 skill 的来源与各 agent 的 link/copy 实况
    -p <dir>        指定项目的清单
    --all           全局 + 所有已登记项目
EOF
}

# status — 详细帮助
show_help_status() {
    cat << EOF
asmgr status — 检查配置声明与实际安装（link/copy）的一致性

用法:
    asmgr status [--fix] [-g | -p <dir> | --all]

scope:
    默认（无 flag）  当前目录项目（按项目清单检查）
    -g, --global    全局（按 skills.yaml 检查；并把中央目录直接子目录视作 registry 真相核对）
    -p <dir>        指定项目
    --all           全局 + 所有已登记项目

检查结果标签:
    [OK]      一致
    [MISSING] 配置有、链接/副本不存在
    [WRONG]   安装方式不符或链接目标错误
    [ORPHAN]  实际存在指向中央目录的链接/副本、配置未声明（游离）
    [STALE]   skills.yaml 有记录、中央目录已不存在（仅全局）
发现问题即退出码非零（--fix 修复后亦然）。

[!] --fix 副作用（两个 scope 语义相反）:
    全局（-g / --all 的全局部分）:
        游离安装 → 登记进 skills.yaml（采纳，不删除）；补齐/修复声明过的安装；
        补登中央目录新增 skill；删除 stale 记录及其全局安装
    项目（默认 / -p）:
        修复/补齐声明过的安装；清单未声明的游离链接/副本 → 直接删除
EOF
}

# sync — 详细帮助
show_help_sync() {
    cat << EOF
asmgr sync — 配置与实际安装双向同步

用法:
    asmgr sync --from-agents | --from-config [-g | -p <dir> | --all]

--from-agents  实态 → 配置（首次使用 / 迁移）:
    -g              扫描全局各 agent 目录，重建 skills.yaml 的 agents_link/agents_copy
                    （保留 source/updated_at）；有 claude CLI 时把 plugin/marketplace
                    实况合并写入 yaml 的 claude_code 段
    默认 / -p <dir> 扫描项目目录现有链接，生成/更新项目清单（含 subagents）
    --all           不适用（无法枚举所有项目目录）

--from-config  配置 → 实态（新机部署 / 重建链接）:
    -g / --all      按 skills.yaml 重建全局链接/副本；yaml 有 claude_code 段时同时部署
                    plugin/marketplace（需 claude CLI）
                    [!] 以配置为真相: 会删除 yaml 未声明的全局游离符号链接
                        （copy 游离不清理，仅 status 报告）
    默认 / -p <dir> 按项目清单重建该项目的链接（含 subagents）；不清理游离

跨机恢复: git pull agent-settings 后 → asmgr sync --from-config --all
EOF
}

# remove — 详细帮助
show_help_remove() {
    cat << EOF
asmgr remove — 移除 skill/subagent

用法:
    asmgr remove <skill>                                    # 完全移除（见下方 [!]）
    asmgr remove <skill> -a <agents...> [-s] [-g|-p <dir>]  # 从指定 scope 移除

部分移除参数（带 -a 或 -s 才是部分移除，中央目录保留）:
    -a <agents...>    从这些 agent 移除（symlink 直接删；copy 目录删除前确认）
    -g, --global      从全局安装移除（登记在 skills.yaml）
    -p <dir>          从指定项目移除
    （无 scope flag = 当前目录项目）
    -s, --subagent    移除 subagent: 从 .claude/agents 解链并更新清单（固定 claude-code）
    全局部分移除清空最后一个 agent 后，yaml 中保留该 skill 记录及 source（供重新安装）；
    只有完全移除才删除记录

[!] 完全移除（不带 -a/-s；注意仅带 -g 或 -p 也是完全移除）: 删除中央目录
    $SKILLS_DIR/<skill> + 所有全局安装 + skills.yaml 记录（执行前有 y/N 确认；
    项目安装不受影响）。局部移除必须显式给 -a（或 -s）。

<skill> 按已存在的安装名称精确匹配，不接收路径。

示例:
    asmgr remove my-skill                        # 完全移除（中央目录 + 全局安装 + 配置）
    asmgr remove my-skill -a cursor -g           # 仅从全局 cursor 移除
    asmgr remove my-skill -a cursor              # 仅从当前目录项目移除
    asmgr remove my-skill -a cursor -p ~/p/foo   # 仅从指定项目移除
    asmgr remove my-subagent -s                  # 移除 subagent 链接
EOF
}

# 分命令帮助路由: asmgr help <cmd> / asmgr <cmd> --help
show_cmd_help() {
    case "$1" in
        add)    show_help_add ;;
        list)   show_help_list ;;
        status) show_help_status ;;
        sync)   show_help_sync ;;
        remove) show_help_remove ;;
        *)
            print_error "未知命令: $1"
            echo "可用命令: add list status sync remove"
            echo "总览: asmgr --help"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------- #
#                             Add skills/subagents                             #
# ---------------------------------------------------------------------------- #

cmd_add_interactive() {
    local is_global="$1"
    local project_dir="$2"
    local use_copy="$3"
    local is_subagent="$4"
    local agents_specified="$5"
    local scope_specified="$6"
    local method_specified="$7"
    shift 7
    local agents=("$@")

    local selected_items=()
    if [[ "$is_subagent" == true ]]; then
        asmgr_interactive_select_subagents || return 1
    else
        asmgr_interactive_select_skills || return 1
    fi
    selected_items=("${_interactive_selected[@]}")

    if [[ "$is_subagent" != true && ( "$agents_specified" != true || ${#agents[@]} -eq 0 ) ]]; then
        asmgr_interactive_select_agents || return 1
        agents=("${_interactive_selected[@]}")
    fi

    if [[ "$scope_specified" != true ]]; then
        asmgr_interactive_prompt_scope || return 1
        is_global="$_interactive_is_global"
        project_dir="$_interactive_project_dir"
    fi

    if [[ "$is_subagent" != true && "$method_specified" != true ]]; then
        asmgr_interactive_prompt_method || return 1
        use_copy="$_interactive_use_copy"
    fi

    local item failed=() args=()
    for item in "${selected_items[@]}"; do
        args=("$item")
        if [[ "$is_subagent" == true ]]; then
            args+=("-s")
        elif [[ ${#agents[@]} -gt 0 ]]; then
            args+=("-a" "${agents[@]}")
        fi
        if [[ "$is_global" == true ]]; then
            args+=("-g")
        elif [[ -n "$project_dir" ]]; then
            args+=("-p" "$project_dir")
        fi
        [[ "$use_copy" == true ]] && args+=("-c")

        cmd_add "${args[@]}" || failed+=("$item")
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        print_warn "以下条目未成功安装: ${failed[*]}"
        return 1
    fi
    return 0
}

# 添加 skill 命令
cmd_add() {
    local source=""
    local agents=()
    local is_global=false
    local project_dir=""
    local use_copy=false
    local source_by_name=false
    local source_materialized=false
    local is_subagent=false
    local agents_specified=false
    local scope_specified=false
    local method_specified=false

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--agents)
                shift
                local agents_before=${#agents[@]}
                # 收集所有 agents，直到遇到下一个选项或参数结束
                while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                    agents+=("$1")
                    shift
                done
                [[ ${#agents[@]} -gt $agents_before ]] && agents_specified=true
                ;;
            -g|--global)
                is_global=true
                scope_specified=true
                shift
                ;;
            -p|--project)
                require_project_dir_arg "$2" || return 1
                project_dir="$2"
                scope_specified=true
                shift 2
                ;;
            -c|--copy)
                use_copy=true
                method_specified=true
                shift
                ;;
            -s|--subagent)
                is_subagent=true
                shift
                ;;
            --)
                shift
                if [[ -z "$source" && $# -gt 0 ]]; then
                    source="$1"
                    shift
                fi
                if [[ $# -gt 0 ]]; then
                    print_error "未知参数: $1"
                    echo "用法: asmgr add [source] [-a <agents...>] [-s] [-g|-p <dir>] [-c]"
                    echo "详情: asmgr help add"
                    return 1
                fi
                ;;
            -*)
                print_error "未知参数: $1"
                echo "用法: asmgr add [source] [-a <agents...>] [-s] [-g|-p <dir>] [-c]"
                echo "详情: asmgr help add"
                return 1
                ;;
            *)
                if [[ -z "$source" ]]; then
                    source="$1"
                    shift
                else
                    print_error "未知参数: $1"
                    echo "用法: asmgr add [source] [-a <agents...>] [-s] [-g|-p <dir>] [-c]"
                    echo "详情: asmgr help add"
                    return 1
                fi
                ;;
        esac
    done

    validate_scope_flags "$is_global" "$project_dir" || return 1

    if [[ "$is_subagent" != true ]]; then
        validate_agents "${agents[@]}" || return 1
    fi

    if [[ -z "$source" ]]; then
        cmd_add_interactive \
            "$is_global" "$project_dir" "$use_copy" "$is_subagent" \
            "$agents_specified" "$scope_specified" "$method_specified" \
            "${agents[@]}"
        return $?
    fi

    # 解析 scope → base 目录（含 -p 存在性校验）
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
    if [[ "$source" =~ ^https?://github\.com/ ]]; then
        # GitHub URL
        if ! parse_github_url "$source"; then
            return 1
        fi
        if ! download_from_github; then
            return 1
        fi
        source_materialized=true
    elif [[ "$source" == /* || "$source" == ./* || "$source" == ../* ]]; then
        # 本地路径（必须以 /, ./, ../ 开头，显式指定）
        source=$(normalize_base_dir "$source")
        if ! copy_from_local "$source"; then
            return 1
        fi
        source_materialized=true
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
            print_error "  - GitHub URL: https://github.com/owner/repo 或 https://github.com/owner/repo/tree/branch[/path/to/skill]"
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
    local method="link"
    [[ "$use_copy" == true ]] && method="copy"
    if [[ ${#installed_agents[@]} -gt 0 ]]; then
        if [[ "$is_global" == true ]]; then
            update_skills_yaml "$SKILL_NAME" "$source_str" 1 "$method" "${installed_agents[@]}"
        else
            if [[ "$source_materialized" == true ]]; then
                update_skills_yaml "$SKILL_NAME" "$source_str" 1 "link"
            fi
            # 项目/本地 scope：记录到项目清单 skills 段（path 由 base_dir 现场派生）
            local manifest
            manifest="$(project_touch_manifest "$base_dir")"
            pm_update_entry "$manifest" "skills" "$SKILL_NAME" "$method" "${installed_agents[@]}"
            print_info "已记录到项目清单: $manifest"
        fi
    elif [[ "$source_materialized" == true ]]; then
        update_skills_yaml "$SKILL_NAME" "$source_str" 1 "link"
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

# ---------------------------------------------------------------------------- #
#                             List skills/subagents                            #
# ---------------------------------------------------------------------------- #

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

# ---------------------------------------------------------------------------- #
#                           Status: consistency check                          #
# ---------------------------------------------------------------------------- #
# 检查配置与实际全局链接/复制的一致性
list_central_skill_dirs() {
    [[ ! -d "$SKILLS_DIR" ]] && return 0

    local entry skill_name
    for entry in "$SKILLS_DIR"/* "$SKILLS_DIR"/.[!.]* "$SKILLS_DIR"/..?*; do
        [[ -d "$entry" ]] || continue
        skill_name="${entry##*/}"
        [[ "$skill_name" == "skills.yaml" ]] && continue
        printf '%s\n' "$skill_name"
    done
}

status_is_direct_child_name() {
    local name="$1"
    [[ -n "$name" && "$name" != "." && "$name" != ".." && "$name" != */* ]]
}

status_remove_stale_global_installs() {
    local skill_name="$1"
    local agent agent_dir field target_path
    local failed=0

    if ! status_is_direct_child_name "$skill_name"; then
        print_error "拒绝清理非直接子目录 registry key: $skill_name"
        return 1
    fi

    for field in agents_link agents_copy; do
        while IFS= read -r agent; do
            [[ -z "$agent" ]] && continue
            agent_dir=$(get_agent_dir "$agent" "$HOME" "global" 2>/dev/null) || continue
            target_path="$agent_dir/$skill_name"
            [[ -e "$target_path" || -L "$target_path" ]] || continue
            if /bin/rm -rf "$target_path"; then
                echo "  已删除 stale 安装: $target_path"
            else
                print_error "删除 stale 安装失败: $target_path"
                failed=1
            fi
        done <<< "$(get_skill_agents_field "$skill_name" "$field")"
    done

    return $failed
}

status_check_global_registry() {
    local fix_mode="${1:-0}"
    local found_issue=0
    local skill_name

    echo "检查中央 registry..."

    while IFS= read -r skill_name; do
        [[ -z "$skill_name" ]] && continue
        if ! skill_exists_in_yaml "$skill_name"; then
            print_status_tag MISSING "$skill_name (中央目录存在，skills.yaml 无记录)"
            found_issue=1
            if [[ $fix_mode -eq 1 ]]; then
                update_skills_yaml "$skill_name" "unknown" 1 "link"
                echo "  已添加 registry 记录"
            fi
        fi
    done <<< "$(list_central_skill_dirs)"

    if [[ -f "$SKILLS_YAML" ]]; then
        while IFS= read -r skill_name; do
            [[ -z "$skill_name" ]] && continue
            if ! status_is_direct_child_name "$skill_name" || [[ ! -d "$SKILLS_DIR/$skill_name" ]]; then
                print_status_tag STALE "$skill_name (skills.yaml 有记录，中央目录不存在)"
                found_issue=1
                if [[ $fix_mode -eq 1 ]]; then
                    if status_remove_stale_global_installs "$skill_name"; then
                        remove_skill_from_yaml "$skill_name"
                        echo "  已删除 registry 记录"
                    else
                        echo "  保留 registry 记录，等待 stale 安装清理完成"
                    fi
                fi
            fi
        done <<< "$(get_all_skills)"
    fi

    return $found_issue
}

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

    status_is_direct_child_name "$skill_name" || return 0

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

    status_check_global_registry "$fix_mode" || has_issues=1

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
            echo "发现不一致，运行 'asmgr status -g --fix' 自动修复"
        else
            info_done "修复"
        fi
    fi

    # 缺陷②修复：发现不一致即返回非零，与 project_status_one 的退出码语义对齐
    # （检测期已置位的 has_issues；--fix 后仍返回非零，与项目侧一致）。
    return $has_issues
}

# ---------------------------------------------------------------------------- #
#                            Sync: actual <-> config                           #
# ---------------------------------------------------------------------------- #

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
            cwd) project_scan_one "$(current_pwd_dir)" ;;
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

    # 初始化配置文件；重扫只让安装列表跟随实态，不抹掉已有 source/updated_at。
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

# ---------------------------------------------------------------------------- #
#                            Remove skills/subagents                           #
# ---------------------------------------------------------------------------- #

remove_child_dir_exists_exact() {
    local dir="$1" name="$2" path
    [[ -n "$name" && -d "$dir" ]] || return 1
    for path in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [[ -d "$path" ]] || continue
        [[ "${path##*/}" == "$name" ]] && return 0
    done
    return 1
}

remove_agent_install_exists_exact() {
    local name="$1" base_dir="$2" mode="$3"
    shift 3
    [[ -n "$name" ]] || return 1

    local agent agent_dir path
    for agent in "$@"; do
        agent_dir=$(get_agent_dir "$agent" "$base_dir" "$mode" 2>/dev/null) || continue
        [[ -d "$agent_dir" ]] || continue
        for path in "$agent_dir"/* "$agent_dir"/.[!.]* "$agent_dir"/..?*; do
            [[ -L "$path" || -d "$path" ]] || continue
            [[ "${path##*/}" == "$name" ]] && return 0
        done
    done
    return 1
}

resolve_complete_remove_skill_name() {
    local name="$1"
    remove_child_dir_exists_exact "$SKILLS_DIR" "$name" && return 0
    print_error "未找到 Skill '$name'"
    return 1
}

resolve_partial_remove_skill_name() {
    local name="$1" base_dir="$2" mode="$3"
    shift 3
    remove_agent_install_exists_exact "$name" "$base_dir" "$mode" "$@" && return 0
    print_error "未找到 Skill '$name'"
    return 1
}

# 完全移除 skill（中央目录 + 所有受管理的全局安装 + 配置记录）
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
    echo "  - 删除所有受管理的全局安装（link/copy）"
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
                touch_skill_updated_at "$skill_name"
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

    validate_scope_flags "$is_global" "$project_dir" || return 1

    if [[ "$is_subagent" != true ]]; then
        validate_agents "${agents[@]}" || return 1
    fi

    local base_dir=""
    if [[ "$is_subagent" == true || ${#agents[@]} -gt 0 ]]; then
        resolve_base_dir "$is_global" "$project_dir" || return 1
        base_dir="$RESOLVED_BASE_DIR"
    fi

    # subagent 分支：从 .claude/agents 解链 + 更新项目清单 subagents 段
    if [[ "$is_subagent" == true ]]; then
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
        resolve_complete_remove_skill_name "$skill_name" || return 1
        remove_skill_completely "$skill_name"
    else
        local mode
        if [[ "$is_global" == true ]]; then
            mode="global"
        else
            mode="project"
        fi

        resolve_partial_remove_skill_name "$skill_name" "$base_dir" "$mode" "${agents[@]}" || return 1

        if [[ "$is_global" == true ]]; then
            print_info "从全局安装移除 Skill: $skill_name"
        elif [[ -n "$project_dir" ]]; then
            print_info "从项目 $base_dir 移除 Skill: $skill_name"
        else
            print_info "从当前目录移除 Skill: $skill_name"
        fi

        remove_skill_from_agents "$skill_name" "$base_dir" "$mode" "${agents[@]}"
    fi
}


# ---------------------------------------------------------------------------- #
#                                main function                                 #
# ---------------------------------------------------------------------------- #
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi

    local command="$1"
    shift

    case "$command" in
        add)
            [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help_add; return 0; }
            cmd_add "$@"
            ;;
        list)
            [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help_list; return 0; }
            cmd_list "$@"
            ;;
        status)
            [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help_status; return 0; }
            cmd_status "$@"
            ;;
        sync)
            [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help_sync; return 0; }
            cmd_sync "$@"
            ;;
        remove)
            [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help_remove; return 0; }
            cmd_remove "$@"
            ;;
        help)
            if [[ $# -gt 0 ]]; then
                show_cmd_help "$1"
            else
                show_help
            fi
            ;;
        --help|-h)
            show_help
            ;;
        *)
            print_error "未知命令: $command"
            echo "可用命令: add list status sync remove（详情: asmgr help <command>）"
            return 1
            ;;
    esac
}

# 执行主函数
if ! check_dependencies; then
    exit 1
fi
main "$@"

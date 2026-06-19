#!/usr/bin/env bash

# lib/interactive.sh — asmgr add 的轻量交互选择器

asmgr_interactive_add_unique() {
    local item="$1" existing
    [[ -z "$item" ]] && return 0
    for existing in "${_interactive_selected[@]}"; do
        [[ "$existing" == "$item" ]] && return 0
    done
    _interactive_selected+=("$item")
}

asmgr_interactive_list_skills() {
    [[ -d "$SKILLS_DIR" ]] || return 0
    local item
    for item in "$SKILLS_DIR"/*; do
        [[ -d "$item" ]] || continue
        /usr/bin/basename "$item"
    done | /usr/bin/sort
}

asmgr_interactive_list_subagents() {
    [[ -d "$AGENTS_DIR" ]] || return 0
    local item
    for item in "$AGENTS_DIR"/*; do
        [[ -e "$item" ]] || continue
        /usr/bin/basename "$item"
    done | /usr/bin/sort
}

# 多选：优先 fzf；无 TTY / 无 fzf 时退化为编号输入。结果写入 _interactive_selected。
asmgr_interactive_select_many() {
    local title="$1"
    shift
    local choices=("$@")
    _interactive_selected=()

    if [[ ${#choices[@]} -eq 0 ]]; then
        print_error "没有可选择的条目"
        return 1
    fi

    if [[ -t 0 && -t 1 ]] && command -v fzf >/dev/null 2>&1; then
        local selected line
        selected=$(printf '%s\n' "${choices[@]}" | fzf \
            --multi \
            --header '↑↓ move, tab select, enter confirm' \
            --prompt="$title> " \
            --height=80% \
            --border) || return 1
        while IFS= read -r line; do
            asmgr_interactive_add_unique "$line"
        done <<< "$selected"
    else
        local i reply token item
        echo "$title" >&2
        i=1
        for item in "${choices[@]}"; do
            printf '  %2d) %s\n' "$i" "$item" >&2
            i=$((i + 1))
        done
        echo >&2
        printf '输入编号或名称（空格分隔，all 全选，空取消）: ' >&2
        read -r reply
        [[ -z "$reply" ]] && return 1

        for token in $reply; do
            if [[ "$token" == "all" ]]; then
                for item in "${choices[@]}"; do
                    asmgr_interactive_add_unique "$item"
                done
                continue
            fi
            if [[ "$token" =~ ^[0-9]+$ ]] && [[ $token -ge 1 && $token -le ${#choices[@]} ]]; then
                asmgr_interactive_add_unique "${choices[$((token - 1))]}"
                continue
            fi
            for item in "${choices[@]}"; do
                if [[ "$item" == "$token" ]]; then
                    asmgr_interactive_add_unique "$item"
                    break
                fi
            done
        done
    fi

    if [[ ${#_interactive_selected[@]} -eq 0 ]]; then
        print_error "未选择任何条目"
        return 1
    fi
    return 0
}

asmgr_interactive_select_skills() {
    local choices=() line
    while IFS= read -r line; do
        [[ -n "$line" ]] && choices+=("$line")
    done <<< "$(asmgr_interactive_list_skills)"
    asmgr_interactive_select_many "选择要安装的 skills" "${choices[@]}"
}

asmgr_interactive_select_subagents() {
    local choices=() line
    while IFS= read -r line; do
        [[ -n "$line" ]] && choices+=("$line")
    done <<< "$(asmgr_interactive_list_subagents)"
    asmgr_interactive_select_many "选择要安装的 subagents" "${choices[@]}"
}

asmgr_interactive_select_agents() {
    local choices=() agent
    for agent in $SUPPORTED_AGENTS; do
        choices+=("$agent")
    done
    asmgr_interactive_select_many "选择要安装到的 agents" "${choices[@]}"
}

asmgr_interactive_prompt_scope() {
    _interactive_is_global=false
    _interactive_project_dir=""

    local cwd choice dir
    cwd="$(/bin/pwd)"
    echo "选择 scope" >&2
    echo "  1) 当前项目: $cwd" >&2
    echo "  2) 全局: $HOME" >&2
    echo "  3) 指定项目目录" >&2
    printf '请选择 (1-3，默认 1): ' >&2
    read -r choice
    [[ -z "$choice" ]] && choice="1"

    case "$choice" in
        1)
            ;;
        2)
            _interactive_is_global=true
            ;;
        3)
            printf '项目目录: ' >&2
            read -r dir
            if [[ -z "$dir" ]]; then
                print_error "项目目录不能为空"
                return 1
            fi
            _interactive_project_dir="$dir"
            ;;
        *)
            print_error "无效 scope: $choice"
            return 1
            ;;
    esac
    return 0
}

asmgr_interactive_prompt_method() {
    _interactive_use_copy=false

    local choice
    echo "选择安装方式" >&2
    echo "  1) link（默认）" >&2
    echo "  2) copy" >&2
    printf '请选择 (1-2，默认 1): ' >&2
    read -r choice
    [[ -z "$choice" ]] && choice="1"

    case "$choice" in
        1)
            ;;
        2)
            _interactive_use_copy=true
            ;;
        *)
            print_error "无效安装方式: $choice"
            return 1
            ;;
    esac
    return 0
}

#!/bin/bash

# run-remote — 在集群项目镜像目录执行任意命令
# 复用 .remote_config / .sync_config，按“异树同枝”映射远端路径。

set -o pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -h "$SCRIPT_PATH" ]]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
source "$SCRIPT_DIR/remote_common.sh"

init_run_vars() {
    REMOTE_HOST=""
    REMOTE_DIR_OVERRIDE=""
    DRY_RUN=false
    LOGIN_SHELL=false
    REMOTE_PORT=""
    COMMAND_ARGS=()
}

show_help() {
    cat <<'EOF'
远程命令执行工具

用法: run-remote [选项] <command> [args...]

选项:
  -H, --host HOST        SSH host（默认读取 .remote_config / .sync_config）
  -d, --remote-dir DIR   覆盖远端目录（默认按 $HOME 异树同枝映射）
  -n, --dry-run          打印 ssh 命令但不执行
  -p, --port PORT        SSH 端口（默认读取配置）
      --login            使用 bash -lc 执行远端命令
  -h, --help             显示帮助

特殊命令:
  precheck               测试 SSH 连接并显示本地 Git 工作区状态

示例:
  run-remote squeue -u $USER
  run-remote julia run_sjtusy_omp.jl
  run-remote sbatch job.sub
  run-remote tail -20 dqmc.out
  run-remote make
  run-remote precheck
  run-remote -n squeue -u $USER
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -H|--host)
                [[ $# -ge 2 ]] || { echo "错误: $1 需要参数" >&2; exit 1; }
                REMOTE_HOST="$2"
                shift 2
                ;;
            -d|--remote-dir)
                [[ $# -ge 2 ]] || { echo "错误: $1 需要参数" >&2; exit 1; }
                REMOTE_DIR_OVERRIDE="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -p|--port)
                [[ $# -ge 2 ]] || { echo "错误: $1 需要参数" >&2; exit 1; }
                REMOTE_PORT="$2"
                shift 2
                ;;
            --login)
                LOGIN_SHELL=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --)
                shift
                COMMAND_ARGS=("$@")
                return
                ;;
            -*)
                echo "错误: 未知选项 $1" >&2
                show_help
                exit 1
                ;;
            *)
                COMMAND_ARGS=("$@")
                return
                ;;
        esac
    done
}

# 用单引号构造可由远端 shell 安全解析的参数。
shell_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

# 远端路径以 ~/ 开头时，让远端 shell 展开自己的 HOME，而不是把 ~ 当作普通字符。
quote_remote_dir() {
    case "$1" in
        "~")
            printf '"$HOME"'
            ;;
        "~/"*)
            printf '"$HOME"/'
            shell_quote "${1#\~/}"
            ;;
        *)
            shell_quote "$1"
            ;;
    esac
}

build_remote_command() {
    local arg
    local quoted
    REMOTE_COMMAND=""
    for arg in "${COMMAND_ARGS[@]}"; do
        quoted="$(shell_quote "$arg")"
        if [[ -z "$REMOTE_COMMAND" ]]; then
            REMOTE_COMMAND="$quoted"
        else
            REMOTE_COMMAND="$REMOTE_COMMAND $quoted"
        fi
    done
}

print_ssh_command() {
    local remote_script="$1"
    printf '%s ' "$SSH_CMD" >&2
    shell_quote "$REMOTE_HOST" >&2
    printf ' ' >&2
    shell_quote "$remote_script" >&2
    printf '\n' >&2
}

show_git_status() {
    local git_status
    local dirty_count
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "本地 Git: 非 Git 仓库"
        return
    fi

    git_status="$(git status --porcelain)"
    if [[ -z "$git_status" ]]; then
        echo "本地 Git: clean"
    else
        dirty_count="$(printf '%s\n' "$git_status" | wc -l | tr -d ' ')"
        echo "本地 Git: dirty ($dirty_count files)"
    fi
}

run_precheck() {
    local ssh_output
    local ssh_status
    local line
    local got_ok=false
    local precheck_script="echo ok"

    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s -o BatchMode=yes -o ConnectTimeout=10 ' "$SSH_CMD" >&2
        shell_quote "$REMOTE_HOST" >&2
        printf " 'echo ok'\n" >&2
        show_git_status
        return
    fi

    ssh_output=$($SSH_CMD -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" "$precheck_script" 2>&1)
    ssh_status=$?
    while IFS= read -r line; do
        [[ "$line" == "ok" ]] && got_ok=true
    done <<< "$ssh_output"
    if [[ $ssh_status -eq 0 && "$got_ok" == "true" ]]; then
        echo "SSH: ok ($REMOTE_HOST)"
    else
        echo "SSH: failed ($REMOTE_HOST)" >&2
        [[ -n "$ssh_output" ]] && printf '%s\n' "$ssh_output" >&2
        show_git_status
        return 1
    fi
    show_git_status
}

main() {
    init_run_vars
    parse_args "$@"

    if [[ ${#COMMAND_ARGS[@]} -eq 0 ]]; then
        echo "错误: 未指定远端命令" >&2
        show_help
        exit 1
    fi

    REMOTE_ROLE="run"
    load_remote_config
    REMOTE_PORT="${REMOTE_PORT:-$DEFAULT_REMOTE_PORT}"

    if [[ -z "$REMOTE_HOST" ]]; then
        echo "错误: 未配置远程服务器地址 (DEFAULT_RUN_HOST / DEFAULT_REMOTE_HOST)" >&2
        echo "请设置 ./.remote_config、./.sync_config、~/.config/remote/config" >&2
        echo "或兼容路径 ~/.config/sync_to_remote/config，也可使用 --host。" >&2
        exit 1
    fi

    build_ssh_cmd
    if [[ "${COMMAND_ARGS[0]}" == "precheck" && ${#COMMAND_ARGS[@]} -eq 1 ]]; then
        run_precheck
        return
    fi

    if [[ -n "$REMOTE_DIR_OVERRIDE" ]]; then
        REMOTE_DIR="$REMOTE_DIR_OVERRIDE"
    else
        detect_remote_paths
        REMOTE_DIR="$DEFAULT_REMOTE_BASE$RELATIVE_PATH"
    fi

    build_remote_command
    local remote_script="cd $(quote_remote_dir "$REMOTE_DIR") && $REMOTE_COMMAND"
    if [[ "$LOGIN_SHELL" == "true" ]]; then
        remote_script="bash -lc $(shell_quote "$remote_script")"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_ssh_command "$remote_script"
        return
    fi

    $SSH_CMD "$REMOTE_HOST" "$remote_script"
}

main "$@"

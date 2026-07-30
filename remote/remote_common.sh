#!/bin/bash

# remote 工具共享配置协议与“异树同枝”路径映射。

# 硬编码默认值（作为最后的 fallback）
FALLBACK_REMOTE_HOST=""
FALLBACK_REMOTE_BASE="~"
FALLBACK_REMOTE_PORT="22"
FALLBACK_MODE="push"

# 加载用户级与项目级配置。新文件名优先，旧文件名保持兼容。
load_remote_config() {
    if [[ "${REMOTE_CONFIG_LOADED:-false}" != "true" ]]; then
        local user_config=""
        local project_config=""

        # 用户配置：优先使用 remote 新路径，找不到时回退到 sync_to_remote 旧路径。
        if [[ -f "$HOME/.config/remote/config" ]]; then
            user_config="$HOME/.config/remote/config"
        elif [[ -f "$HOME/.config/sync_to_remote/config" ]]; then
            user_config="$HOME/.config/sync_to_remote/config"
        fi
        if [[ -n "$user_config" ]]; then
            echo "加载用户配置: $user_config" >&2
            source "$user_config"
        fi

        # 项目配置优先级更高；同样优先新文件名，再兼容旧文件名。
        if [[ -f "./.remote_config" ]]; then
            project_config="./.remote_config"
        elif [[ -f "./.sync_config" ]]; then
            project_config="./.sync_config"
        fi
        if [[ -n "$project_config" ]]; then
            echo "加载项目配置: $project_config" >&2
            source "$project_config"
        fi

        DEFAULT_MODE="${DEFAULT_MODE:-$FALLBACK_MODE}"
        DEFAULT_REMOTE_HOST="${DEFAULT_REMOTE_HOST:-$FALLBACK_REMOTE_HOST}"
        DEFAULT_REMOTE_BASE="${DEFAULT_REMOTE_BASE:-$FALLBACK_REMOTE_BASE}"
        DEFAULT_REMOTE_PORT="${DEFAULT_REMOTE_PORT:-$FALLBACK_REMOTE_PORT}"
        REMOTE_CONFIG_LOADED=true
    fi

    # 命令行 -H 已写入 REMOTE_HOST 时保持不变，否则按工具角色选择 host。
    if [[ -z "${REMOTE_HOST:-}" ]]; then
        case "${REMOTE_ROLE:-}" in
            run)
                REMOTE_HOST="${DEFAULT_RUN_HOST:-$DEFAULT_REMOTE_HOST}"
                ;;
            sync)
                REMOTE_HOST="${DEFAULT_SYNC_HOST:-$DEFAULT_REMOTE_HOST}"
                ;;
            *)
                REMOTE_HOST="$DEFAULT_REMOTE_HOST"
                ;;
        esac
    fi
}

# 异树同枝：在远程目录树上找到与本地相同的枝（相对路径）。
detect_remote_paths() {
    LOCAL_PATH="$(pwd)"
    HOME_PATH="$HOME"

    if [[ "$LOCAL_PATH" != "$HOME_PATH" && "$LOCAL_PATH" != "$HOME_PATH/"* ]]; then
        echo "错误: 当前目录不在用户家目录下"
        echo "当前目录: $LOCAL_PATH"
        echo "家目录: $HOME_PATH"
        exit 1
    fi

    RELATIVE_PATH="${LOCAL_PATH#$HOME_PATH}"
    if [[ -z "$RELATIVE_PATH" ]]; then
        RELATIVE_PATH="/"
    fi

    REMOTE_TARGET="$REMOTE_HOST:$DEFAULT_REMOTE_BASE$RELATIVE_PATH"
}

# 构建 SSH 命令字符串，供 rsync 和远程命令执行器共用。
build_ssh_cmd() {
    SSH_CMD="ssh"
    SSH_OPTS_CHANGED=false
    if [[ "$REMOTE_PORT" != "22" ]]; then
        SSH_CMD="$SSH_CMD -p $REMOTE_PORT"
        SSH_OPTS_CHANGED=true
    fi
}

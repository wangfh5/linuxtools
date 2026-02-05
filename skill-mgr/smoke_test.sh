#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM="$ROOT_DIR/skill_mgr.sh"

if [[ ! -x "$SM" ]]; then
    echo "找不到可执行的 skill_mgr.sh: $SM" >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t skill-mgr-smoke)"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

TMP_HOME="$TMP_ROOT/home"
TMP_WORK="$TMP_ROOT/work"
TMP_PROJECT="$TMP_ROOT/project"

mkdir -p "$TMP_HOME" "$TMP_WORK" "$TMP_PROJECT"
mkdir -p "$TMP_HOME/agent-settings/skills"
mkdir -p "$TMP_HOME/.cursor/skills" "$TMP_HOME/.codex/skills" "$TMP_HOME/.claude/skills"
mkdir -p "$TMP_PROJECT/.claude/skills"

SKILL_NAME="smoke-skill-$(date +%s)"
SKILL_DIR="$TMP_WORK/$SKILL_NAME"
mkdir -p "$SKILL_DIR"
printf "# %s\n" "$SKILL_NAME" > "$SKILL_DIR/SKILL.md"
echo "smoke test" > "$SKILL_DIR/test.txt"
YAML_PATH="$TMP_HOME/agent-settings/skills/skills.yaml"

run() {
    HOME="$TMP_HOME" "$SM" "$@"
}

run_confirm() {
    printf 'y\n' | HOME="$TMP_HOME" "$SM" "$@"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    if ! grep -Fq "$needle" <<< "$haystack"; then
        echo "断言失败：未找到内容: $needle" >&2
        exit 1
    fi
}

run help >/dev/null
run add "$SKILL_DIR" -a cursor -g
if [[ ! -L "$TMP_HOME/.cursor/skills/$SKILL_NAME" ]]; then
    echo "断言失败：全局 link 安装符号链接不存在" >&2
    exit 1
fi

# 将同一个 agent 从 link 切换为 copy（应从 agents_link 移到 agents_copy）
run_confirm add "$SKILL_NAME" -a cursor -g -c
if [[ ! -d "$TMP_HOME/.cursor/skills/$SKILL_NAME" || -L "$TMP_HOME/.cursor/skills/$SKILL_NAME" ]]; then
    echo "断言失败：全局 copy 安装目录不存在或仍为符号链接" >&2
    exit 1
fi

link_list="$(yq -r ".skills.\"$SKILL_NAME\".agents_link // [] | .[]" "$YAML_PATH" 2>/dev/null || true)"
copy_list="$(yq -r ".skills.\"$SKILL_NAME\".agents_copy // [] | .[]" "$YAML_PATH" 2>/dev/null || true)"
if grep -Fqx "cursor" <<< "$link_list"; then
    echo "断言失败：cursor 仍在 agents_link 中" >&2
    exit 1
fi
if ! grep -Fqx "cursor" <<< "$copy_list"; then
    echo "断言失败：cursor 不在 agents_copy 中" >&2
    exit 1
fi

ln_link="$(rg -n -- "agents_link:" "$YAML_PATH" | head -1 | cut -d: -f1)"
ln_copy="$(rg -n -- "agents_copy:" "$YAML_PATH" | head -1 | cut -d: -f1)"
ln_source="$(rg -n -- "source:" "$YAML_PATH" | head -1 | cut -d: -f1)"
ln_added="$(rg -n -- "added_at:" "$YAML_PATH" | head -1 | cut -d: -f1)"
if [[ -z "${ln_link:-}" || -z "${ln_copy:-}" || -z "${ln_source:-}" || -z "${ln_added:-}" ]]; then
    echo "断言失败：skills.yaml 字段缺失" >&2
    exit 1
fi
if (( ln_link > ln_copy || ln_copy > ln_source || ln_source > ln_added )); then
    echo "断言失败：skills.yaml 字段顺序不符合 agents_link/agents_copy/source/added_at" >&2
    exit 1
fi

run add "$SKILL_NAME" -a codex -g -c
run add "$SKILL_NAME" -a claude-code -p "$TMP_PROJECT"

list_out="$(run list)"
assert_contains "$list_out" "$SKILL_NAME"

status_out="$(run status)"
assert_contains "$status_out" "$SKILL_NAME -> cursor (copy)"
assert_contains "$status_out" "$SKILL_NAME -> codex (copy)"

if [[ ! -L "$TMP_PROJECT/.claude/skills/$SKILL_NAME" ]]; then
    echo "断言失败：本地安装符号链接不存在" >&2
    exit 1
fi

run_confirm remove "$SKILL_NAME" -a cursor -g
run_confirm remove "$SKILL_NAME" -a codex -g
run remove "$SKILL_NAME" -a claude-code -p "$TMP_PROJECT"

if [[ -e "$TMP_PROJECT/.claude/skills/$SKILL_NAME" ]]; then
    echo "断言失败：本地安装未被移除" >&2
    exit 1
fi

run_confirm remove "$SKILL_NAME"

list_after="$(run list || true)"
if grep -Fq "$SKILL_NAME" <<< "$list_after"; then
    echo "断言失败：skill 仍存在于 list 输出中" >&2
    exit 1
fi

echo "Smoke test 通过"

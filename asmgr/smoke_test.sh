#!/usr/bin/env bash
#
# smoke_test.sh — asmgr 的回归契约 (regression contract)
#
# 这套测试锁定 asmgr 当前**可观察行为**的每一项能力，作为重构的安全网：
# 重构后必须保持全绿。
#
# 设计要点：
#   - 完全沙箱化：每个用例用独立的临时 HOME。asmgr.sh 的所有中央路径
#     （$HOME/agent-settings/skills|agents|projects、各 agent 的 ~/.{cursor,claude,codex,gemini}
#      与 ~/.config/opencode、~/.pi/agent、~/.omp/agent）
#     都从 $HOME 现场派生，所以换 HOME 就把整套工具重定向到沙箱，绝不碰真实 ~/agent-settings。
#   - 自清理：单一 trap 删除根临时目录。
#   - 结构化：每个能力一个 tc_* 用例函数；统一的 pass/fail/skip 计数；
#     失败打印断言信息 + 相关命令输出；结尾汇总，有失败则 exit 1。
#
# 覆盖（能力清单逐项）：
#   add / list / status / sync / remove × scope(默认cwd / -g / -p / --all)
#   skill link + copy（含 link↔copy 迁移、skills.yaml 字段顺序）
#   subagent(-s)：目录型 / .md 型 / 与同名 skill 靠 -s 消歧 / 全局只建链不记录
#   项目清单：默认cwd 与 -p 写入、$HOME 内相对命名 vs $HOME 外绝对命名(/→__)、空清单 prune
#   sync --from-agents 迁移扫描；sync --from-config 幂等；--all 全局+所有项目
#   status 的 OK/MISSING/WRONG/ORPHAN + --fix（全局“补配置” vs 项目“删游离链”差异）
#   真实文件占位不覆盖、路径不存在、中央目录缺失、依赖缺失
#   skills.yaml 的 claude_code(plugin/marketplace) 段 round-trip（claude CLI 不可用则 SKIP）

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM="$ROOT_DIR/asmgr.sh"

if [[ ! -x "$SM" ]]; then
    echo "找不到可执行的 asmgr.sh: $SM" >&2
    exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
    echo "需要 yq 才能运行本测试: https://github.com/mikefarah/yq" >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t asmgr-smoke)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# ───────────────────────────── 测试框架 ─────────────────────────────
PASS=0
FAIL=0
SKIP=0
declare -a FAILED=()
CURRENT="(setup)"

note()  { CURRENT="$1"; printf '\n=== %s ===\n' "$1"; }
pass()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
skip()  { SKIP=$((SKIP+1)); printf '  [SKIP] %s\n' "$1"; }
fail()  {
    FAIL=$((FAIL+1))
    FAILED+=("$CURRENT :: $1")
    printf '  [FAIL] %s\n' "$1" >&2
}
dump()  { printf '  ---- 命令输出 ----\n%s\n  ------------------\n' "$1" >&2; }

assert_contains() {      # <desc> <haystack> <needle>
    if grep -Fq -- "$3" <<< "$2"; then pass "$1"; else fail "$1 (未找到: $3)"; dump "$2"; fi
}
assert_not_contains() {  # <desc> <haystack> <needle>
    if grep -Fq -- "$3" <<< "$2"; then fail "$1 (不应出现: $3)"; dump "$2"; else pass "$1"; fi
}
assert_eq() {            # <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected='$2' actual='$3')"; fi
}
assert_symlink() {       # <desc> <path>
    if [[ -L "$2" ]]; then pass "$1"; else fail "$1 (不是符号链接: $2)"; fi
}
assert_real_dir() {      # <desc> <path>  (目录且非符号链接 = copy)
    if [[ -d "$2" && ! -L "$2" ]]; then pass "$1"; else fail "$1 (不是实体目录: $2)"; fi
}
assert_absent() {        # <desc> <path>
    if [[ ! -e "$2" && ! -L "$2" ]]; then pass "$1"; else fail "$1 (仍存在: $2)"; fi
}
assert_present() {       # <desc> <path>
    if [[ -e "$2" || -L "$2" ]]; then pass "$1"; else fail "$1 (不存在: $2)"; fi
}
assert_rc() {            # <desc> <expected_rc>   (读取全局 RC/OUT)
    if [[ "$RC" == "$2" ]]; then pass "$1 (rc=$RC)"; else fail "$1 (rc 期望=$2 实际=$RC)"; dump "$OUT"; fi
}
assert_rc_nonzero() {    # <desc>
    if [[ "$RC" != "0" ]]; then pass "$1 (rc=$RC)"; else fail "$1 (期望非零 rc)"; dump "$OUT"; fi
}

# ───────────────────────────── 调用封装 ─────────────────────────────
# H = 当前用例的沙箱 HOME。OUT/RC = 最近一次调用的输出/退出码。
H=""

# 造一个全新沙箱 HOME（用 mktemp 保证唯一——注意 H=$(new_home) 在子 shell 里跑，
# 任何共享计数器都不会回写父进程，会导致各用例复用同一 HOME 而互相污染）。
new_home() {
    local h; h=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
    mkdir -p "$h/agent-settings/skills" "$h/agent-settings/agents" "$h/agent-settings/projects"
    echo "$h"
}
seed_agent_dirs() {      # 预建某 base 下各 agent skills 目录 + .claude/agents，避免 add 的建目录交互
    local b="$1"
    mkdir -p \
        "$b/.cursor/skills" \
        "$b/.claude/skills" \
        "$b/.codex/skills" \
        "$b/.gemini/skills" \
        "$b/.opencode/skills" \
        "$b/.config/opencode/skills" \
        "$b/.pi/skills" \
        "$b/.pi/agent/skills" \
        "$b/.omp/skills" \
        "$b/.omp/agent/skills" \
        "$b/.claude/agents"
}
mk_src_skill() {         # 在外部目录造一个可被 add <path> 的 skill 源，回显其路径
    local dir="$1" name="$2"
    mkdir -p "$dir/$name"
    printf '# %s\n' "$name" > "$dir/$name/SKILL.md"
    printf 'payload\n' > "$dir/$name/file.txt"
    echo "$dir/$name"
}
mk_central_skill() {     # 直接把 skill 放进中央目录（供 name 搜索 / sync 使用）
    local home="$1" name="$2"
    mkdir -p "$home/agent-settings/skills/$name"
    printf '# %s\n' "$name" > "$home/agent-settings/skills/$name/SKILL.md"
}
mk_central_sub_dir() {   # 目录型 subagent: agents/<name>/<name>.md
    local home="$1" name="$2"
    mkdir -p "$home/agent-settings/agents/$name"
    printf '# %s\n' "$name" > "$home/agent-settings/agents/$name/$name.md"
}
mk_central_sub_md() {    # 文件型 subagent: agents/<name>.md
    local home="$1" name="$2"
    printf -- '---\nname: %s\n---\n' "$name" > "$home/agent-settings/agents/$name.md"
}

run()    { OUT=$(HOME="$H" "$SM" "$@" 2>&1); RC=$?; }
runc()   { OUT=$(printf 'y\n' | HOME="$H" "$SM" "$@" 2>&1); RC=$?; }
run_in() { local d="$1"; shift; OUT=$(cd "$d" && HOME="$H" "$SM" "$@" 2>&1); RC=$?; }
runc_in(){ local d="$1"; shift; OUT=$(cd "$d" && printf 'y\n' | HOME="$H" "$SM" "$@" 2>&1); RC=$?; }
# 把一个 fake CLI 目录放到 PATH 最前再调用。注意 asmgr 启动会把标准目录再前置到 $PATH 之前，
# 所以 fake 命中的前提是“标准目录里没有真实 claude”——由 claude_winnable() 守卫，相关用例并额外
# 断言 stub 日志被写入，确保确实命中而非偶然。yq/jq/git 仍从原 PATH 解析。
run_fake() { local fb="$1"; shift; OUT=$(PATH="$fb:$PATH" HOME="$H" "$SM" "$@" 2>&1); RC=$?; }

# fake claude 能否保证命中：asmgr 会把这些标准目录前置；只有它们都没有真实 claude，
# 放在其后的 fake 才稳赢。否则诚实 SKIP（而非冒充 hermetic）。
claude_winnable() {
    local d
    for d in $STD_PREPEND_DIRS; do
        [[ -x "$d/claude" ]] && return 1
    done
    return 0
}

# 造一个 hermetic 的 fake `claude`：记录每次调用到日志，`plugin list` 回显受控内容。
# 让 plugin 集成测试既不依赖真实 claude、也不读取宿主机的 XDG/认证/缓存状态。
make_fake_claude() {     # <bindir> <logfile> <plugin-list-stdout>
    local bindir="$1" log="$2" listout="$3"
    mkdir -p "$bindir"
    {
        echo '#!/usr/bin/env bash'
        printf 'echo "$*" >> %q\n' "$log"
        echo 'if [[ "$1" == "plugin" && "$2" == "list" ]]; then'
        printf '    printf "%%s\\n" %q\n' "$listout"
        echo 'fi'
        echo 'exit 0'
    } > "$bindir/claude"
    chmod +x "$bindir/claude"
}

# asmgr.sh 启动时前置到 PATH 头部的标准目录（须与 asmgr.sh:8 的 `export PATH=...` 保持一致；
# 产品侧若改动该集合，这里也要同步）。下面两个守卫共用此唯一来源，避免在测试里重复硬编码。
STD_PREPEND_DIRS="/opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/bin /bin /usr/sbin /sbin"

# 判断能否用“空 PATH”模拟缺依赖：若 yq/jq 落在 asmgr 会前置的标准目录里，就无法隐藏。
deps_hideable() {
    local tool p
    for tool in yq jq; do
        p=$(command -v "$tool" 2>/dev/null) || continue
        [[ " $STD_PREPEND_DIRS " == *" $(dirname "$p") "* ]] && return 1
    done
    return 0
}

# 期望的项目清单文件路径（复刻产品的命名规则：$HOME 内存相对、$HOME 外存绝对，/→__）
expected_manifest() {    # <home> <project_abs_dir>
    local home="$1" abs="$2" stored name
    if [[ "$abs" == "$home/"* ]]; then stored="${abs#"$home"/}"; else stored="$abs"; fi
    name="${stored//\//__}"
    echo "$home/agent-settings/projects/$name.yaml"
}

# ════════════════════════════ 用例 ════════════════════════════

tc_help_and_deps() {
    note "help / 无参数 / 依赖检查"
    H=$(new_home)
    run help
    assert_rc "help 退出码 0" 0
    assert_contains "help 含标题" "$OUT" "agent-settings 中央配置仓库的命令行管家"
    assert_contains "help 列出 scope 约定" "$OUT" "当前目录"

    run                       # 无参数 → 显示帮助
    assert_rc "无参数退出码 0" 0
    assert_contains "无参数也显示帮助" "$OUT" "agent-settings 中央配置仓库的命令行管家"

    run foobar-cmd            # 未知命令
    assert_rc_nonzero "未知命令报错"
    assert_contains "未知命令信息" "$OUT" "未知命令"

    # 依赖缺失：用只含空目录的 PATH 触发。注意 asmgr 启动会前置 /usr/bin 等标准目录，
    # 只有当 yq/jq 不在那些目录里（本机在 ~/bin）才能真正模拟缺失——否则诚实 SKIP，避免跨机假结果。
    if deps_hideable; then
        mkdir -p "$TMP_ROOT/emptybin"
        OUT=$(PATH="$TMP_ROOT/emptybin" HOME="$H" "$SM" list 2>&1); RC=$?
        assert_rc_nonzero "缺依赖时退出非零"
        assert_contains "缺依赖时给出提示" "$OUT" "缺少必需的依赖工具"
    else
        skip "yq/jq 安装在脚本会前置的标准目录中，无法用空 PATH 模拟缺依赖"
    fi
}

tc_add_global_link_and_record() {
    note "add -g link：符号链接 + skills.yaml 记录 (source: local:)"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    local src; src=$(mk_src_skill "$TMP_ROOT/src1" "alpha")

    run add "$src" -a cursor -g
    assert_rc "add 退出码 0" 0
    assert_symlink "全局 cursor 符号链接已建" "$H/.cursor/skills/alpha"
    assert_present "中央目录已存在 skill" "$H/agent-settings/skills/alpha/SKILL.md"
    assert_eq "yaml 记录 agents_link 含 cursor" "cursor" \
        "$(yq -r '.skills.alpha.agents_link[]' "$yaml" 2>/dev/null)"
    assert_contains "yaml source 记为 local:" "$(yq -r '.skills.alpha.source' "$yaml")" "local:"

    # 名称搜索 + 第二个 agent（多 agent 路径）
    run add alpha -a gemini claude-code -g
    assert_rc "按名 add 退出码 0" 0
    assert_symlink "全局 gemini 链接" "$H/.gemini/skills/alpha"
    assert_symlink "全局 claude-code 链接" "$H/.claude/skills/alpha"
    assert_contains "add 完成消息" "$OUT" "添加完成"
}

tc_add_local_overwrite() {
    note "add <path>：中央已存在该 skill → 提示覆盖（拒绝=保留现有并返回 0；接受=rm+cp 真覆盖）"
    H=$(new_home); seed_agent_dirs "$H"
    local src; src=$(mk_src_skill "$TMP_ROOT/ow_src" "alpha")
    run add "$src" -a cursor -g
    assert_rc "首次 add 退出码 0" 0
    assert_present "中央目录已建 skill" "$H/agent-settings/skills/alpha/SKILL.md"

    # 在源里加一个标记文件，用来判别中央目录是否被真正覆盖
    printf 'mark\n' > "$src/MARKER.txt"

    # 拒绝覆盖（默认 N）：保留现有、返回 0、标记文件不应进入中央目录
    run add "$src" -a cursor -g
    assert_rc "拒绝覆盖仍返回 0" 0
    assert_contains "提示 Skill 已存在" "$OUT" "已存在"
    assert_contains "拒绝后提示取消操作" "$OUT" "取消操作"
    assert_absent "拒绝覆盖：中央目录未被替换（无 MARKER）" "$H/agent-settings/skills/alpha/MARKER.txt"

    # 接受覆盖（pipe y）：rm -rf + cp -r，中央目录被替换，标记文件出现
    runc add "$src" -a cursor -g
    assert_rc "接受覆盖返回 0" 0
    assert_contains "覆盖后提示已保存" "$OUT" "Skill 已保存到"
    assert_present "接受覆盖：中央目录已替换（含 MARKER）" "$H/agent-settings/skills/alpha/MARKER.txt"
}

tc_link_to_copy_migration_and_field_order() {
    note "link↔copy 迁移 + skills.yaml 字段顺序 (agents_link/agents_copy/source/added_at)"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    mk_central_skill "$H" "beta"

    run add beta -a cursor -g
    assert_symlink "beta 初始为 link" "$H/.cursor/skills/beta"

    # 同一 agent 从 link 切到 copy（已有占位 → 需确认）
    runc add beta -a cursor -g -c
    assert_real_dir "beta 切换为 copy 实体目录" "$H/.cursor/skills/beta"

    local link_list copy_list
    link_list=$(yq -r '.skills.beta.agents_link // [] | .[]' "$yaml" 2>/dev/null)
    copy_list=$(yq -r '.skills.beta.agents_copy // [] | .[]' "$yaml" 2>/dev/null)
    assert_not_contains "cursor 已移出 agents_link" "$link_list" "cursor"
    assert_contains "cursor 已进入 agents_copy" "$copy_list" "cursor"

    # 字段顺序断言
    local ln_link ln_copy ln_source ln_added
    ln_link=$(grep -n -- "agents_link:" "$yaml" | head -1 | cut -d: -f1)
    ln_copy=$(grep -n -- "agents_copy:" "$yaml" | head -1 | cut -d: -f1)
    ln_source=$(grep -n -- "source:" "$yaml" | head -1 | cut -d: -f1)
    ln_added=$(grep -n -- "added_at:" "$yaml" | head -1 | cut -d: -f1)
    if [[ -n "$ln_link" && -n "$ln_copy" && -n "$ln_source" && -n "$ln_added" ]] \
        && (( ln_link < ln_copy && ln_copy < ln_source && ln_source < ln_added )); then
        pass "字段顺序 agents_link < agents_copy < source < added_at"
    else
        fail "字段顺序错误 (link=$ln_link copy=$ln_copy source=$ln_source added=$ln_added)"
        dump "$(cat "$yaml")"
    fi
}

tc_add_copy_global() {
    note "add -g -c：复制模式安装"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "gamma"
    run add gamma -a codex -g -c
    assert_rc "copy add 退出码 0" 0
    assert_real_dir "codex 为复制实体目录" "$H/.codex/skills/gamma"
    assert_eq "yaml agents_copy 含 codex" "codex" \
        "$(yq -r '.skills.gamma.agents_copy[]' "$H/agent-settings/skills/skills.yaml")"
}

tc_opencode_paths_status_and_remove() {
    note "opencode：全局/项目路径 + status --fix + remove"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    local src; src=$(mk_src_skill "$TMP_ROOT/opencode_src1" "omega")

    run add "$src" -a opencode -g
    assert_rc "opencode 全局 add 退出码 0" 0
    assert_symlink "全局 opencode 链接建在 ~/.config/opencode/skills" "$H/.config/opencode/skills/omega"
    assert_eq "yaml 记录 agents_link 含 opencode" "opencode" \
        "$(yq -r '.skills.omega.agents_link[]' "$yaml" 2>/dev/null)"

    rm -f "$H/.config/opencode/skills/omega"
    run status -g
    assert_contains "全局 status 命中 opencode MISSING" "$OUT" "omega -> opencode (配置有，链接不存在)"
    run status --fix -g
    assert_symlink "全局 opencode --fix 重建链接" "$H/.config/opencode/skills/omega"

    local proj="$H/projop"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    local manifest; manifest=$(expected_manifest "$H" "$proj")
    run add omega -a opencode -p "$proj"
    assert_rc "opencode 项目 add 退出码 0" 0
    assert_symlink "项目 opencode 链接建在 .opencode/skills" "$proj/.opencode/skills/omega"
    assert_eq "项目清单登记 opencode link" "opencode" \
        "$(yq -r '.skills.omega.agents_link[]' "$manifest" 2>/dev/null)"

    rm -f "$proj/.opencode/skills/omega"
    run status -p "$proj"
    assert_contains "项目 status 命中 opencode MISSING" "$OUT" "omega -> opencode"
    run status --fix -p "$proj"
    assert_symlink "项目 opencode --fix 重建链接" "$proj/.opencode/skills/omega"

    run remove omega -a opencode -g
    assert_rc "opencode 全局 remove 退出码 0" 0
    assert_absent "全局 opencode 链接已删" "$H/.config/opencode/skills/omega"
    assert_eq "yaml 中 omega 全局记录已删" "null" \
        "$(yq -r '.skills.omega // "null"' "$yaml" 2>/dev/null)"

    run remove omega -a opencode -p "$proj"
    assert_rc "opencode 项目 remove 退出码 0" 0
    assert_absent "项目 opencode 链接已删" "$proj/.opencode/skills/omega"
    assert_absent "项目清单已 prune" "$manifest"
}

tc_pi_paths_status_and_remove() {
    note "pi：全局/项目路径 + status --fix + remove"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    local src; src=$(mk_src_skill "$TMP_ROOT/pi_src1" "theta")

    run add "$src" -a pi -g
    assert_rc "pi 全局 add 退出码 0" 0
    assert_symlink "全局 pi 链接建在 ~/.pi/agent/skills" "$H/.pi/agent/skills/theta"
    assert_eq "yaml 记录 agents_link 含 pi" "pi" \
        "$(yq -r '.skills.theta.agents_link[]' "$yaml" 2>/dev/null)"

    rm -f "$H/.pi/agent/skills/theta"
    run status -g
    assert_contains "全局 status 命中 pi MISSING" "$OUT" "theta -> pi (配置有，链接不存在)"
    run status --fix -g
    assert_symlink "全局 pi --fix 重建链接" "$H/.pi/agent/skills/theta"

    local proj="$H/projpi"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    local manifest; manifest=$(expected_manifest "$H" "$proj")
    run add theta -a pi -p "$proj"
    assert_rc "pi 项目 add 退出码 0" 0
    assert_symlink "项目 pi 链接建在 .pi/skills" "$proj/.pi/skills/theta"
    assert_eq "项目清单登记 pi link" "pi" \
        "$(yq -r '.skills.theta.agents_link[]' "$manifest" 2>/dev/null)"

    rm -f "$proj/.pi/skills/theta"
    run status -p "$proj"
    assert_contains "项目 status 命中 pi MISSING" "$OUT" "theta -> pi"
    run status --fix -p "$proj"
    assert_symlink "项目 pi --fix 重建链接" "$proj/.pi/skills/theta"

    run remove theta -a pi -g
    assert_rc "pi 全局 remove 退出码 0" 0
    assert_absent "全局 pi 链接已删" "$H/.pi/agent/skills/theta"
    assert_eq "yaml 中 theta 全局记录已删" "null" \
        "$(yq -r '.skills.theta // "null"' "$yaml" 2>/dev/null)"

    run remove theta -a pi -p "$proj"
    assert_rc "pi 项目 remove 退出码 0" 0
    assert_absent "项目 pi 链接已删" "$proj/.pi/skills/theta"
    assert_absent "项目清单已 prune" "$manifest"
}

tc_omp_paths_status_and_remove() {
    note "omp：全局/项目路径 + status --fix + remove"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    local src; src=$(mk_src_skill "$TMP_ROOT/omp_src1" "iota")

    run add "$src" -a omp -g
    assert_rc "omp 全局 add 退出码 0" 0
    assert_symlink "全局 omp 链接建在 ~/.omp/agent/skills" "$H/.omp/agent/skills/iota"
    assert_eq "yaml 记录 agents_link 含 omp" "omp" \
        "$(yq -r '.skills.iota.agents_link[]' "$yaml" 2>/dev/null)"

    rm -f "$H/.omp/agent/skills/iota"
    run status -g
    assert_contains "全局 status 命中 omp MISSING" "$OUT" "iota -> omp (配置有，链接不存在)"
    run status --fix -g
    assert_symlink "全局 omp --fix 重建链接" "$H/.omp/agent/skills/iota"

    local proj="$H/projomp"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    local manifest; manifest=$(expected_manifest "$H" "$proj")
    run add iota -a omp -p "$proj"
    assert_rc "omp 项目 add 退出码 0" 0
    assert_symlink "项目 omp 链接建在 .omp/skills" "$proj/.omp/skills/iota"
    assert_eq "项目清单登记 omp link" "omp" \
        "$(yq -r '.skills.iota.agents_link[]' "$manifest" 2>/dev/null)"

    rm -f "$proj/.omp/skills/iota"
    run status -p "$proj"
    assert_contains "项目 status 命中 omp MISSING" "$OUT" "iota -> omp"
    run status --fix -p "$proj"
    assert_symlink "项目 omp --fix 重建链接" "$proj/.omp/skills/iota"

    run remove iota -a omp -g
    assert_rc "omp 全局 remove 退出码 0" 0
    assert_absent "全局 omp 链接已删" "$H/.omp/agent/skills/iota"
    assert_eq "yaml 中 iota 全局记录已删" "null" \
        "$(yq -r '.skills.iota // "null"' "$yaml" 2>/dev/null)"

    run remove iota -a omp -p "$proj"
    assert_rc "omp 项目 remove 退出码 0" 0
    assert_absent "项目 omp 链接已删" "$proj/.omp/skills/iota"
    assert_absent "项目清单已 prune" "$manifest"
}

tc_list_global_and_all() {
    note "list：-g / --all"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g

    run list -g
    assert_rc "list -g 退出码 0" 0
    assert_contains "list -g 含 skill 名" "$OUT" "alpha"
    assert_contains "list -g 含安装状态标题" "$OUT" "已注册的 Skills"

    # 顺便登记一个项目，--all 应同时列全局 + 项目
    local proj="$H/proj_a"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    run add alpha -a claude-code -p "$proj"
    run list --all
    assert_rc "list --all 退出码 0" 0
    assert_contains "list --all 含全局 skill" "$OUT" "alpha"
    assert_contains "list --all 含项目段标题" "$OUT" "已注册的项目"
    assert_contains "list --all 含项目名" "$OUT" "proj_a"
}

tc_status_global_ok() {
    note "status -g：全部一致 (OK)"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor claude-code -g
    run status -g
    assert_rc "status -g 退出码 0" 0
    assert_contains "OK: cursor" "$OUT" "[OK]"
    assert_contains "通过提示" "$OUT" "所有检查通过"
    assert_not_contains "无 MISSING" "$OUT" "[MISSING]"
}

tc_status_global_missing_fix() {
    note "status -g：MISSING + --fix 重建"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g
    rm -f "$H/.cursor/skills/alpha"          # 配置有，链接没了

    run status -g
    assert_contains "报告 MISSING" "$OUT" "[MISSING]"
    # 钉住全局侧独有的精确文案（项目侧 MISSING 为裸文案，二者不可被抽象抹平为同一句）
    assert_contains "全局 MISSING 精确文案带 (配置有，链接不存在)" "$OUT" "alpha -> cursor (配置有，链接不存在)"
    # 缺陷②已修复：status -g 发现不一致时返回非零（与 status -p 的退出码语义一致）。
    assert_rc_nonzero "status -g 有问题返回非零（缺陷②已修复）"
    run status --fix -g
    assert_contains "--fix 提示创建链接" "$OUT" "已创建链接"
    assert_symlink "链接已重建" "$H/.cursor/skills/alpha"
}

tc_status_global_wrong_fix() {
    note "status -g：WRONG (实体占位) + --fix"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g
    rm -f "$H/.cursor/skills/alpha"
    mkdir -p "$H/.cursor/skills/alpha"        # 期望链接，实际是目录

    run status -g
    assert_contains "报告 WRONG" "$OUT" "[WRONG]"
    assert_contains "全局 WRONG 精确文案" "$OUT" "alpha -> cursor (期望链接，实际为目录/文件)"
    run status --fix -g
    assert_symlink "WRONG 已修复为符号链接" "$H/.cursor/skills/alpha"
}

tc_status_global_orphan_fix() {
    note "status -g：ORPHAN + --fix（全局策略=补进配置）"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "orphaned"
    # 手工建一个指向中央目录、但 yaml 未登记的链接
    ln -s "$H/agent-settings/skills/orphaned" "$H/.cursor/skills/orphaned"
    # 让 yaml 存在（含别的 skill），以便 orphan 扫描运行
    mk_central_skill "$H" "alpha"; run add alpha -a claude-code -g

    run status -g
    assert_contains "报告 ORPHAN" "$OUT" "[ORPHAN]"
    run status --fix -g
    assert_contains "--fix 提示已加入配置" "$OUT" "已添加到配置"
    assert_eq "orphan 已写入 yaml" "cursor" \
        "$(yq -r '.skills.orphaned.agents_link[]' "$H/agent-settings/skills/skills.yaml")"
}

tc_status_global_wrong_target_fix() {
    note "status -g：link WRONG_TARGET（链接指向别处）+ --fix 重指中央"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g
    local elsewhere="$H/elsewhere"; mkdir -p "$elsewhere"
    rm -f "$H/.cursor/skills/alpha"
    ln -s "$elsewhere" "$H/.cursor/skills/alpha"   # 是符号链接，但指向别处

    run status -g
    assert_contains "报告 WRONG" "$OUT" "[WRONG]"
    assert_contains "全局 wrong_target 精确文案带实际目标" "$OUT" "alpha -> cursor (链接目标错误: $elsewhere)"
    assert_rc_nonzero "status -g 有问题返回非零"
    run status --fix -g
    assert_contains "--fix 提示已修复" "$OUT" "已修复"
    assert_symlink "修复后仍为符号链接" "$H/.cursor/skills/alpha"
    assert_eq "链接已重指中央 alpha" "$H/agent-settings/skills/alpha" "$(readlink "$H/.cursor/skills/alpha")"
}

tc_status_global_copy_wrong_type_fix() {
    note "status -g：copy WRONG_TYPE（实际非目录）+ --fix"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "gamma"
    run add gamma -a codex -g -c                    # 复制模式
    assert_real_dir "初始为复制实体目录" "$H/.codex/skills/gamma"
    rm -rf "$H/.codex/skills/gamma"
    printf 'x\n' > "$H/.codex/skills/gamma"         # 期望 copy，实际是文件

    run status -g
    assert_contains "报告 WRONG" "$OUT" "[WRONG]"
    assert_contains "全局 copy wrong_type 精确文案" "$OUT" "gamma -> codex (期望 copy，实际非目录)"
    assert_rc_nonzero "status -g 有问题返回非零"
    run status --fix -g
    assert_contains "--fix 提示已修复" "$OUT" "已修复"
    assert_real_dir "已修复为复制实体目录" "$H/.codex/skills/gamma"
    assert_present "修复确实 cp -r 了内容（含 SKILL.md，而非空目录）" "$H/.codex/skills/gamma/SKILL.md"
}

tc_status_global_copy_missing_fix() {
    note "status -g：copy MISSING + --fix 重新复制"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "gamma"
    run add gamma -a codex -g -c
    rm -rf "$H/.codex/skills/gamma"                 # 配置有，copy 没了

    run status -g
    assert_contains "报告 MISSING" "$OUT" "[MISSING]"
    assert_contains "全局 copy MISSING 精确文案带 (配置有，copy 不存在)" "$OUT" "gamma -> codex (配置有，copy 不存在)"
    assert_rc_nonzero "status -g 有问题返回非零"
    run status --fix -g
    assert_contains "--fix 提示已复制" "$OUT" "已复制"
    assert_real_dir "copy 已重建" "$H/.codex/skills/gamma"
    assert_present "重建确实 cp -r 了内容（含 SKILL.md，而非空目录）" "$H/.codex/skills/gamma/SKILL.md"
}

tc_status_global_copy_issue_folds() {
    note "status -g：同 skill 的 link OK 但 copy 缺失 → 整体仍非零（钉住第二个 helper 调用的折叠语义）"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "delta"
    run add delta -a cursor -g                      # link 分支: cursor
    run add delta -a codex -g -c                    # copy 分支: codex
    assert_symlink "link 分支就绪 (cursor)" "$H/.cursor/skills/delta"
    assert_real_dir "copy 分支就绪 (codex)" "$H/.codex/skills/delta"
    rm -rf "$H/.codex/skills/delta"                 # 只破坏 copy 分支

    run status -g
    assert_contains "link 分支仍报告 OK" "$OUT" "[OK]"
    assert_contains "OK 行确指向 cursor 条目（本场景仅此一处 delta -> cursor）" "$OUT" "delta -> cursor"
    assert_contains "copy 分支报告 MISSING" "$OUT" "delta -> codex (配置有，copy 不存在)"
    assert_rc_nonzero "copy 分支问题折叠进总退出码（link OK 不会把它清回 0）"
}

tc_project_add_default_cwd_in_home() {
    note "add 默认 cwd（$HOME 内项目）：写项目清单 + 相对命名"
    H=$(new_home)
    local proj="$H/projwork"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    mk_central_skill "$H" "alpha"
    local manifest; manifest=$(expected_manifest "$H" "$proj")

    run_in "$proj" add alpha -a claude-code codex
    assert_rc "项目 add 退出码 0" 0
    assert_symlink "项目 claude-code 链接" "$proj/.claude/skills/alpha"
    assert_symlink "项目 codex 链接" "$proj/.codex/skills/alpha"
    assert_present "清单文件按相对名生成 (projwork.yaml)" "$manifest"
    assert_eq "清单 path 为相对" "projwork" "$(yq -r '.path' "$manifest")"
    assert_eq "清单 skills.alpha.agents_link 含 codex" "claude-code"$'\n'"codex" \
        "$(yq -r '.skills.alpha.agents_link[]' "$manifest")"

    # 默认 cwd 的 list / status 命中该清单
    run_in "$proj" list
    assert_contains "默认 list 命中当前项目" "$OUT" "alpha"
    run_in "$proj" status
    assert_contains "默认 status 报 OK" "$OUT" "[OK]"

    # 项目侧 MISSING 是裸文案（"<name> -> <agent>"），不带全局独有的 "(配置有，…)" 后缀——
    # 与全局侧的精确断言相对，把这个 per-scope 文案差异钉成契约，防止被抽象抹平为同一句。
    rm -f "$proj/.codex/skills/alpha"
    run_in "$proj" status
    assert_contains "项目 MISSING 命中 codex" "$OUT" "alpha -> codex"
    assert_not_contains "项目 MISSING 不带全局后缀(配置有)" "$OUT" "(配置有"
}

tc_no_manifest_isomorphism() {
    note "无清单时 list 与 status 输出同构（WARN + 提示）"
    local H; H=$(new_home)
    local proj="$H/empty-proj"; /bin/mkdir -p "$proj"
    run_in "$proj" list
    assert_contains "list 无清单 WARN" "$OUT" "无项目清单:"
    assert_contains "list 无清单含 scope 提示" "$OUT" "试试 -g（全局）或 --all（全局 + 所有项目）"
    run_in "$proj" status
    assert_contains "status 无清单 WARN" "$OUT" "无项目清单:"
    assert_contains "status 无清单含 scope 提示" "$OUT" "试试 -g（全局）或 --all（全局 + 所有项目）"
    run_in "$proj" sync --from-config
    assert_contains "sync 无清单 WARN" "$OUT" "无项目清单:"
    assert_contains "sync 无清单含 scope 提示" "$OUT" "试试 -g（全局）或 --all（全局 + 所有项目）"
}

tc_project_add_p_outside_home() {
    note "add -p（$HOME 外项目）：绝对命名 (前导 __)"
    H=$(new_home)
    local proj="$TMP_ROOT/projout_$(basename "$H")"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    mk_central_skill "$H" "alpha"
    local manifest; manifest=$(expected_manifest "$H" "$proj")

    run add alpha -a cursor -p "$proj"
    assert_rc "add -p 退出码 0" 0
    assert_symlink "项目 cursor 链接" "$proj/.cursor/skills/alpha"
    assert_present "清单按绝对名生成" "$manifest"
    case "$(basename "$manifest")" in
        __*) pass "清单文件名带前导 __（\$HOME 外绝对路径）" ;;
        *)   fail "清单文件名应带前导 __，实际: $(basename "$manifest")" ;;
    esac
    assert_eq "清单 path 为绝对路径" "$proj" "$(yq -r '.path' "$manifest")"

    # -p 的 list / status
    run list -p "$proj"
    assert_contains "list -p 命中" "$OUT" "alpha"
    run status -p "$proj"
    assert_contains "status -p 报 OK" "$OUT" "[OK]"
}

tc_subagent_dir_and_md() {
    note "subagent (-s)：目录型 / .md 型 add+remove，写/清项目清单"
    H=$(new_home)
    local proj="$H/projsub"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    mk_central_sub_dir "$H" "dir-agent"
    mk_central_sub_md  "$H" "mentor"
    local manifest; manifest=$(expected_manifest "$H" "$proj")

    run add dir-agent -s -p "$proj"
    assert_rc "add -s 目录型 退出码 0" 0
    assert_symlink "目录型 subagent 链到 .claude/agents" "$proj/.claude/agents/dir-agent"

    run add mentor -s -p "$proj"
    assert_rc "add -s .md 型 退出码 0" 0
    assert_symlink ".md 型 subagent 链接（含 .md 后缀）" "$proj/.claude/agents/mentor.md"

    assert_eq "清单 subagents 含 dir-agent" "claude-code" \
        "$(yq -r '.subagents."dir-agent".agents_link[]' "$manifest")"
    assert_eq "清单 subagents 含 mentor.md" "claude-code" \
        "$(yq -r '.subagents."mentor.md".agents_link[]' "$manifest")"

    run list -p "$proj"
    assert_contains "list 显示 subagents 段" "$OUT" "subagents"
    run status -p "$proj"
    assert_contains "subagent status 报 OK" "$OUT" "Subagent dir-agent"

    # 移除其一
    run remove dir-agent -s -p "$proj"
    assert_rc "remove -s 退出码 0" 0
    assert_absent "目录型 subagent 链接已删" "$proj/.claude/agents/dir-agent"
    assert_eq "清单已删除 dir-agent 条目" "null" \
        "$(yq -r '.subagents."dir-agent" // "null"' "$manifest")"
}

tc_subagent_global_no_record() {
    note "subagent -s -g：只建链、不写记录"
    H=$(new_home)
    mk_central_sub_md "$H" "mentor"
    run add mentor -s -g
    assert_rc "全局 -s 退出码 0" 0
    assert_symlink "全局 subagent 链接已建" "$H/.claude/agents/mentor.md"
    assert_contains "提示不写记录" "$OUT" "不写入配置记录"
}

tc_subagent_disambiguation() {
    note "同名 skill vs subagent：靠 -s 消歧"
    H=$(new_home)
    local proj="$H/projdis"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    mk_central_skill   "$H" "draft-journal-reply"   # 既是 skill
    mk_central_sub_dir "$H" "draft-journal-reply"   # 又是 subagent

    run add draft-journal-reply -a claude-code -p "$proj"     # 不带 -s → skill
    assert_symlink "无 -s 命中 skill (.claude/skills)" "$proj/.claude/skills/draft-journal-reply"

    run add draft-journal-reply -s -p "$proj"                 # 带 -s → subagent
    assert_symlink "带 -s 命中 subagent (.claude/agents)" "$proj/.claude/agents/draft-journal-reply"
}

tc_sync_from_agents_global() {
    note "sync --from-agents -g：从全局安装重建 skills.yaml"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    mk_central_skill "$H" "alpha"
    mk_central_skill "$H" "gamma"
    run add alpha -a cursor -g
    # 手工放一个实体副本（非符号链接）模拟 copy 安装，触发扫描的 copy 分支
    cp -r "$H/agent-settings/skills/gamma" "$H/.codex/skills/gamma"
    rm -f "$yaml"                              # 抹掉配置，仅留链接/副本

    run sync --from-agents -g
    assert_rc "sync --from-agents -g 退出码 0" 0
    assert_present "yaml 已重建" "$yaml"
    assert_eq "重建后 alpha 在 agents_link" "cursor" \
        "$(yq -r '.skills.alpha.agents_link[]' "$yaml")"
    assert_eq "扫描识别出 copy（gamma 在 agents_copy）" "codex" \
        "$(yq -r '.skills.gamma.agents_copy[]' "$yaml")"
}

tc_opencode_sync_from_agents_and_config() {
    note "opencode：sync --from-agents / --from-config（copy，含全局与项目）"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    local proj="$H/projopsync"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    local manifest; manifest=$(expected_manifest "$H" "$proj")
    mk_central_skill "$H" "sigma"

    cp -r "$H/agent-settings/skills/sigma" "$H/.config/opencode/skills/sigma"
    cp -r "$H/agent-settings/skills/sigma" "$proj/.opencode/skills/sigma"

    run sync --from-agents -g
    assert_rc "opencode 全局 from-agents 退出码 0" 0
    assert_eq "全局 from-agents 识别 opencode copy" "opencode" \
        "$(yq -r '.skills.sigma.agents_copy[]' "$yaml" 2>/dev/null)"

    run sync --from-agents -p "$proj"
    assert_rc "opencode 项目 from-agents 退出码 0" 0
    assert_eq "项目 from-agents 识别 opencode copy" "opencode" \
        "$(yq -r '.skills.sigma.agents_copy[]' "$manifest" 2>/dev/null)"

    rm -rf "$H/.config/opencode/skills/sigma" "$proj/.opencode/skills/sigma"

    run sync --from-config -g
    assert_rc "opencode 全局 from-config 退出码 0" 0
    assert_real_dir "全局 from-config 重建 opencode copy" "$H/.config/opencode/skills/sigma"

    run sync --from-config -p "$proj"
    assert_rc "opencode 项目 from-config 退出码 0" 0
    assert_real_dir "项目 from-config 重建 opencode copy" "$proj/.opencode/skills/sigma"
}

tc_pi_sync_from_agents_and_config() {
    note "pi：sync --from-agents / --from-config（copy，含全局与项目）"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    local proj="$H/projpisync"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    local manifest; manifest=$(expected_manifest "$H" "$proj")
    mk_central_skill "$H" "lambda"

    cp -r "$H/agent-settings/skills/lambda" "$H/.pi/agent/skills/lambda"
    cp -r "$H/agent-settings/skills/lambda" "$proj/.pi/skills/lambda"

    run sync --from-agents -g
    assert_rc "pi 全局 from-agents 退出码 0" 0
    assert_eq "全局 from-agents 识别 pi copy" "pi" \
        "$(yq -r '.skills.lambda.agents_copy[]' "$yaml" 2>/dev/null)"

    run sync --from-agents -p "$proj"
    assert_rc "pi 项目 from-agents 退出码 0" 0
    assert_eq "项目 from-agents 识别 pi copy" "pi" \
        "$(yq -r '.skills.lambda.agents_copy[]' "$manifest" 2>/dev/null)"

    rm -rf "$H/.pi/agent/skills/lambda" "$proj/.pi/skills/lambda"

    run sync --from-config -g
    assert_rc "pi 全局 from-config 退出码 0" 0
    assert_real_dir "全局 from-config 重建 pi copy" "$H/.pi/agent/skills/lambda"

    run sync --from-config -p "$proj"
    assert_rc "pi 项目 from-config 退出码 0" 0
    assert_real_dir "项目 from-config 重建 pi copy" "$proj/.pi/skills/lambda"
}

tc_omp_sync_from_agents_and_config() {
    note "omp：sync --from-agents / --from-config（copy，含全局与项目）"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    local proj="$H/projompsync"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    local manifest; manifest=$(expected_manifest "$H" "$proj")
    mk_central_skill "$H" "mu"

    cp -r "$H/agent-settings/skills/mu" "$H/.omp/agent/skills/mu"
    cp -r "$H/agent-settings/skills/mu" "$proj/.omp/skills/mu"

    run sync --from-agents -g
    assert_rc "omp 全局 from-agents 退出码 0" 0
    assert_eq "全局 from-agents 识别 omp copy" "omp" \
        "$(yq -r '.skills.mu.agents_copy[]' "$yaml" 2>/dev/null)"

    run sync --from-agents -p "$proj"
    assert_rc "omp 项目 from-agents 退出码 0" 0
    assert_eq "项目 from-agents 识别 omp copy" "omp" \
        "$(yq -r '.skills.mu.agents_copy[]' "$manifest" 2>/dev/null)"

    rm -rf "$H/.omp/agent/skills/mu" "$proj/.omp/skills/mu"

    run sync --from-config -g
    assert_rc "omp 全局 from-config 退出码 0" 0
    assert_real_dir "全局 from-config 重建 omp copy" "$H/.omp/agent/skills/mu"

    run sync --from-config -p "$proj"
    assert_rc "omp 项目 from-config 退出码 0" 0
    assert_real_dir "项目 from-config 重建 omp copy" "$proj/.omp/skills/mu"
}

tc_sync_from_agents_project_migration() {
    note "sync --from-agents (cwd / -p)：扫描项目现有链接 → 写清单（迁移）"
    H=$(new_home)
    mk_central_skill "$H" "alpha"

    # cwd 模式：手工建一个指向中央目录的链接，模拟历史绝对链接
    local pc="$H/projcwd"; mkdir -p "$pc/.claude/skills"
    ln -s "$H/agent-settings/skills/alpha" "$pc/.claude/skills/alpha"
    local mc; mc=$(expected_manifest "$H" "$pc")
    run_in "$pc" sync --from-agents
    assert_rc "sync --from-agents (cwd) 退出码 0" 0
    assert_present "cwd 扫描生成清单" "$mc"
    assert_eq "清单登记了 claude-code 链接" "claude-code" \
        "$(yq -r '.skills.alpha.agents_link[]' "$mc")"

    # -p 模式：再混入一个实体副本，覆盖项目侧扫描的 copy 分支
    mk_central_skill "$H" "gamma"
    local pp="$H/projp"; mkdir -p "$pp/.cursor/skills" "$pp/.codex/skills"
    ln -s "$H/agent-settings/skills/alpha" "$pp/.cursor/skills/alpha"
    cp -r "$H/agent-settings/skills/gamma" "$pp/.codex/skills/gamma"
    local mp; mp=$(expected_manifest "$H" "$pp")
    run sync --from-agents -p "$pp"
    assert_present "-p 扫描生成清单" "$mp"
    assert_eq "清单登记了 cursor 链接" "cursor" \
        "$(yq -r '.skills.alpha.agents_link[]' "$mp")"
    assert_eq "清单登记了 codex 副本 (copy 分支)" "codex" \
        "$(yq -r '.skills.gamma.agents_copy[]' "$mp")"
}

tc_sync_from_config_global_idempotent() {
    note "sync --from-config -g：重建链接 + 幂等重跑"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g
    rm -f "$H/.cursor/skills/alpha"           # 模拟新机器：有配置无链接

    run sync --from-config -g
    assert_rc "首次 sync --from-config -g 退出码 0" 0
    assert_symlink "链接已部署" "$H/.cursor/skills/alpha"
    assert_contains "首次提示已创建" "$OUT" "已创建"

    run sync --from-config -g                 # 幂等
    assert_rc "二次 sync 退出码 0" 0
    assert_contains "二次提示已存在（幂等）" "$OUT" "已存在"
}

tc_sync_from_config_prunes_orphans() {
    note "sync --from-config -g：删除 yaml 未声明的游离链接（config 即真相）"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    mk_central_skill "$H" "ghost"
    run add alpha -a cursor -g                                  # 仅 alpha 登记进 yaml
    ln -s "$H/agent-settings/skills/ghost" "$H/.cursor/skills/ghost"  # 游离链接，配置无

    run sync --from-config -g
    assert_rc "sync --from-config -g 退出码 0" 0
    assert_symlink "已声明的 alpha 保留" "$H/.cursor/skills/alpha"
    assert_absent "游离的 ghost 已删除" "$H/.cursor/skills/ghost"
    assert_contains "提示删除游离链接" "$OUT" "已删除游离链接"
}

tc_sync_from_config_prune_spares_copies() {
    note "sync --from-config -g：prune 只删链接，同名实体目录（疑似用户数据）不被 rm"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g
    # 与中央 skill 同名的实体目录：copy 游离仅靠同名碰撞判定，prune 必须放过它
    mkdir -p "$H/.cursor/skills/userdir"
    printf 'precious\n' > "$H/.cursor/skills/userdir/data.txt"
    mkdir -p "$H/agent-settings/skills/userdir"

    run sync --from-config -g
    assert_rc "sync --from-config -g 退出码 0" 0
    assert_present "同名实体目录未被删除" "$H/.cursor/skills/userdir/data.txt"
}

tc_sync_from_config_project_and_all() {
    note "sync --from-config：-p 单项目 / --all 全局+所有项目"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g                       # 全局配置

    local proj="$H/projall"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    run add alpha -a claude-code -p "$proj"          # 项目清单
    rm -f "$H/.cursor/skills/alpha" "$proj/.claude/skills/alpha"

    # -p 只重建项目
    run sync --from-config -p "$proj"
    assert_rc "sync --from-config -p 退出码 0" 0
    assert_symlink "项目链接已重建" "$proj/.claude/skills/alpha"

    # --all 重建全局 + 所有项目。退出码缺陷①已修复：project_deploy_all 显式 return 0，
    # 故“有已登记项目”时 sync --from-config --all 正常返回 0（部署成功）。
    rm -f "$H/.cursor/skills/alpha" "$proj/.claude/skills/alpha"
    run sync --from-config --all
    assert_symlink "全局链接已重建 (--all)" "$H/.cursor/skills/alpha"
    assert_symlink "项目链接已重建 (--all)" "$proj/.claude/skills/alpha"
    assert_rc "sync --from-config --all 退出码 0（缺陷①已修复）" 0
}

tc_sync_real_file_guard() {
    note "sync --from-config：真实文件占位不被覆盖"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g
    rm -f "$H/.cursor/skills/alpha"
    printf 'precious user data\n' > "$H/.cursor/skills/alpha"   # 占位的真实文件

    run sync --from-config -g
    assert_contains "提示跳过非符号链接" "$OUT" "已存在非符号链接"
    if [[ -f "$H/.cursor/skills/alpha" && ! -L "$H/.cursor/skills/alpha" ]] \
        && grep -Fq "precious user data" "$H/.cursor/skills/alpha"; then
        pass "真实文件未被覆盖"
    else
        fail "真实文件被破坏"
    fi
}

tc_sync_missing_central() {
    note "边界：中央目录缺失 / 配置缺失"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g
    rm -rf "$H/agent-settings/skills/alpha"       # 删中央目录，保留 yaml 记录
    rm -f "$H/.cursor/skills/alpha"

    run sync --from-config -g
    assert_contains "中央目录缺失 → 跳过并告警" "$OUT" "不存在"
    assert_absent "未误建链接" "$H/.cursor/skills/alpha"

    # 配置文件整体缺失
    H=$(new_home)
    run sync --from-config -g
    assert_rc_nonzero "无 skills.yaml 时 from-config 报错"
    assert_contains "提示配置不存在" "$OUT" "配置文件不存在"
}

tc_all_rejected_commands() {
    note "--all 仅 list/status/sync--from-config 支持；其余拒绝"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"

    run add alpha -a cursor --all
    assert_rc_nonzero "add 拒绝 --all"
    run remove alpha -a cursor --all
    assert_rc_nonzero "remove 拒绝 --all"
    run sync --from-agents --all
    assert_rc_nonzero "sync --from-agents 拒绝 --all"
    assert_contains "--from-agents --all 给出原因" "$OUT" "不适用"
}

tc_remove_partial_and_prune() {
    note "remove -a（项目）：删链 + 更新清单 + 空清单 prune"
    H=$(new_home)
    local proj="$H/projrm"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    mk_central_skill "$H" "alpha"
    run add alpha -a claude-code -p "$proj"
    local manifest; manifest=$(expected_manifest "$H" "$proj")
    assert_present "清单已建" "$manifest"

    run remove alpha -a claude-code -p "$proj"   # link → 无需确认
    assert_rc "remove -a -p 退出码 0" 0
    assert_absent "项目链接已删" "$proj/.claude/skills/alpha"
    assert_absent "空清单被 prune（文件删除）" "$manifest"
}

tc_remove_global_partial() {
    note "remove -a -g：从全局移除并更新 yaml（link 与 copy 各一）"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor -g          # link
    run add alpha -a codex -g -c        # copy

    run remove alpha -a cursor -g       # 删 link，无需确认
    assert_absent "全局 cursor 链接已删" "$H/.cursor/skills/alpha"
    runc remove alpha -a codex -g       # 删 copy 目录，需确认
    assert_absent "全局 codex copy 已删" "$H/.codex/skills/alpha"
    assert_eq "yaml 记录已随之清空" "null" \
        "$(yq -r '.skills.alpha // "null"' "$yaml")"
}

tc_remove_complete() {
    note "remove（完全移除）：中央目录 + 全局安装 + yaml 记录"
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    mk_central_skill "$H" "alpha"
    run add alpha -a cursor claude-code -g

    runc remove alpha                    # 交互确认 y
    assert_rc "完全移除退出码 0" 0
    assert_absent "中央目录已删" "$H/agent-settings/skills/alpha"
    assert_absent "全局 cursor 链接已删" "$H/.cursor/skills/alpha"
    assert_absent "全局 claude-code 链接已删" "$H/.claude/skills/alpha"
    assert_eq "yaml 记录已删" "null" "$(yq -r '.skills.alpha // "null"' "$yaml")"
    assert_contains "remove 完成消息" "$OUT" "移除完成"
}

tc_invalid_inputs() {
    note "边界：路径不存在 / 本地源不存在"
    H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "alpha"

    run add alpha -a cursor -p "$TMP_ROOT/nope-not-here"
    assert_rc_nonzero "项目目录不存在 → 报错"
    assert_contains "提示项目目录不存在" "$OUT" "项目目录不存在"

    run add "$TMP_ROOT/no-such-skill-dir" -a cursor -g
    assert_rc_nonzero "本地源不存在 → 报错"
    assert_contains "提示源路径不存在" "$OUT" "源路径不存在"

    # -g 与 -p 互斥（add 与 remove 都经 resolve_base_dir 校验）
    run add alpha -a cursor -g -p "$H/whatever"
    assert_rc_nonzero "add: -g 与 -p 同用 → 报错"
    assert_contains "add 提示 -g/-p 互斥" "$OUT" "不能同时使用"
    run remove alpha -a cursor -g -p "$H/whatever"
    assert_rc_nonzero "remove: -g 与 -p 同用 → 报错"
    assert_contains "remove 提示 -g/-p 互斥" "$OUT" "不能同时使用"
}

tc_plugin_yaml_roundtrip() {
    note "plugin/marketplace：skills.yaml claude_code 段 round-trip（库级，无网络）"
    H=$(new_home)
    local yaml="$H/agent-settings/skills/skills.yaml"

    # 直接驱动 lib 中的纯 yaml 读写函数（不触碰 claude CLI / 网络）
    (
        export HOME="$H"
        SKILLS_DIR="$H/agent-settings/skills"
        SKILLS_YAML="$yaml"
        now_timestamp_local() { echo "2026-01-01T00:00:00+08:00"; }
        print_info() { :; }; print_warn() { :; }; print_error() { :; }
        # shellcheck disable=SC1090
        source "$ROOT_DIR/lib/yaml.sh"
        source "$ROOT_DIR/lib/plugin.sh"
        update_marketplace_in_yaml "mkt-x" "owner/repo-x" 1
        update_plugin_in_yaml "plug-y" "mkt-x" "user"
    )
    assert_present "claude_code round-trip 写出 yaml" "$yaml"
    assert_eq "marketplace source round-trip" "owner/repo-x" \
        "$(yq -r '.claude_code.marketplaces."mkt-x".source' "$yaml")"
    assert_eq "plugin name round-trip" "plug-y" \
        "$(yq -r '.claude_code.plugins[0].name' "$yaml")"
    assert_eq "plugin marketplace round-trip" "mkt-x" \
        "$(yq -r '.claude_code.plugins[0].marketplace' "$yaml")"
    assert_eq "plugin scope round-trip" "user" \
        "$(yq -r '.claude_code.plugins[0].scope' "$yaml")"

    # getters 读回
    local got
    got=$(
        export HOME="$H"
        SKILLS_DIR="$H/agent-settings/skills"; SKILLS_YAML="$yaml"
        # shellcheck disable=SC1090
        source "$ROOT_DIR/lib/yaml.sh"; source "$ROOT_DIR/lib/plugin.sh"
        get_all_marketplaces_from_yaml
        printf '%s\n' "---"
        get_all_plugins_from_yaml
    )
    assert_contains "getter 列出 marketplace" "$got" "mkt-x"
    assert_contains "getter 列出 plugin (tsv)" "$got" $'plug-y\tmkt-x\tuser'
}

tc_plugin_from_agents_import() {
    note "plugin：sync --from-agents -g 从 (fake) claude 导入 marketplace+plugin → yaml（hermetic）"
    if ! claude_winnable; then skip "标准目录存在真实 claude，无法保证 fake 命中"; return; fi
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    local fb="$H/fakebin" log="$H/claude.log"
    make_fake_claude "$fb" "$log" "cool-plugin@cool-mkt"
    mkdir -p "$H/.claude/plugins"
    cat > "$H/.claude/plugins/known_marketplaces.json" <<'JSON'
{ "cool-mkt": { "source": { "source": "github", "repo": "owner/cool" } } }
JSON
    mk_central_skill "$H" "alpha"
    run add alpha -a claude-code -g                    # 先有 yaml + 链接

    run_fake "$fb" sync --from-agents -g               # plugin_sync_from_claude 走 fake CLI
    assert_rc "sync --from-agents -g 退出码 0" 0
    # 证明确实命中了 stub（只有 stub 会写日志）——否则 import 可能靠沙箱内 json 假性通过
    assert_contains "fake claude 确被调用 (plugin list)" "$(cat "$log" 2>/dev/null)" "plugin list"
    assert_eq "导入 marketplace source" "owner/cool" \
        "$(yq -r '.claude_code.marketplaces."cool-mkt".source' "$yaml")"
    assert_eq "导入 plugin name" "cool-plugin" \
        "$(yq -r '.claude_code.plugins[0].name' "$yaml")"
    assert_eq "导入 plugin marketplace" "cool-mkt" \
        "$(yq -r '.claude_code.plugins[0].marketplace' "$yaml")"
    assert_eq "skill 记录被重新发现" "claude-code" \
        "$(yq -r '.skills.alpha.agents_link[]' "$yaml")"
}

tc_plugin_from_config_deploy() {
    note "plugin：sync --from-config -g 把 yaml 的 claude_code 段部署到 (fake) claude（hermetic）"
    if ! claude_winnable; then skip "标准目录存在真实 claude，无法保证 fake 命中"; return; fi
    H=$(new_home); seed_agent_dirs "$H"
    local yaml="$H/agent-settings/skills/skills.yaml"
    local fb="$H/fakebin" log="$H/claude.log"
    make_fake_claude "$fb" "$log" ""                   # claude 当前无已装 marketplace/plugin
    mk_central_skill "$H" "alpha"
    # 手写一个含 claude_code 段的 yaml（注意：skills 不能为空，否则 sync 在部署 plugin 前提前返回）
    cat > "$yaml" <<'YAML'
skills:
  alpha:
    agents_link: [cursor]
    agents_copy: []
    source: unknown
    added_at: "2026-01-01T00:00:00+08:00"
claude_code:
  marketplaces:
    deploy-mkt:
      source: owner/deploy
      added_at: "2026-01-01T00:00:00+08:00"
  plugins:
    - name: dep-plugin
      marketplace: deploy-mkt
      scope: user
      added_at: "2026-01-01T00:00:00+08:00"
YAML
    run_fake "$fb" sync --from-config -g
    assert_rc "sync --from-config -g 退出码 0" 0
    assert_symlink "skill 链接已部署" "$H/.cursor/skills/alpha"
    local logtxt; logtxt=$(cat "$log" 2>/dev/null)
    assert_contains "调用了 claude plugin marketplace add" "$logtxt" "plugin marketplace add owner/deploy"
    assert_contains "调用了 claude plugin install" "$logtxt" "plugin install dep-plugin@deploy-mkt -s user"
}

tc_project_orphan_fix() {
    note "status -p：项目 ORPHAN + --fix（项目策略=删游离链，覆盖扫描重构后的删除路径）"
    H=$(new_home)
    local proj="$H/projorph"; mkdir -p "$proj"; seed_agent_dirs "$proj"
    mk_central_skill "$H" "alpha"
    mk_central_skill "$H" "orphan-skill"
    mk_central_skill "$H" "orphan-copy"
    mk_central_sub_md "$H" "mentor"
    mk_central_sub_md "$H" "stray"
    run add alpha -a claude-code -p "$proj"          # 登记 skill
    run add mentor -s -p "$proj"                     # 登记 subagent
    # 制造游离条目（指向中央目录、但清单未登记）：游离 link skill / 游离 copy skill / 游离 subagent
    ln -s "$H/agent-settings/skills/orphan-skill" "$proj/.claude/skills/orphan-skill"
    cp -r "$H/agent-settings/skills/orphan-copy" "$proj/.codex/skills/orphan-copy"
    ln -s "$H/agent-settings/agents/stray.md" "$proj/.claude/agents/stray.md"

    run status -p "$proj"
    assert_contains "报告游离 skill (ORPHAN)" "$OUT" "orphan-skill @ claude-code"
    assert_contains "报告游离 copy skill (ORPHAN, copy 分支)" "$OUT" "orphan-copy @ codex (copy 存在"
    assert_contains "报告游离 subagent (ORPHAN)" "$OUT" "Subagent stray.md"

    run status --fix -p "$proj"
    assert_contains "提示删除游离链接" "$OUT" "已删除游离链接"
    assert_absent "游离 skill 链接已删" "$proj/.claude/skills/orphan-skill"
    assert_absent "游离 copy skill 已删" "$proj/.codex/skills/orphan-copy"
    assert_absent "游离 subagent 链接已删" "$proj/.claude/agents/stray.md"
    assert_symlink "已登记 alpha 链接保留" "$proj/.claude/skills/alpha"
    assert_symlink "已登记 mentor 链接保留" "$proj/.claude/agents/mentor.md"
}

tc_status_all_exit_folds_global() {
    note "status --all 退出码折叠：仅全局不一致也返回非零"
    # --- 制造全局不一致：add -g 后删除链接，使其 MISSING ---
    local H; H=$(new_home); seed_agent_dirs "$H"
    mk_central_skill "$H" "zz"
    run add zz -a cursor -g          # registers in skills.yaml + creates ~/.cursor/skills/zz
    rm -f "$H/.cursor/skills/zz"     # 配置有，链接没了 → MISSING

    run status --all
    assert_rc_nonzero "status --all 全局不一致 → 非零"

    # --- 干净环境下 status --all 应返回 0 ---
    local H2; H2=$(new_home); seed_agent_dirs "$H2"
    OUT=$(HOME="$H2" "$SM" status --all 2>/dev/null); RC=$?
    assert_rc "干净环境 status --all → 0" 0
}

tc_sync_all_exit_folds_global() {
    note "sync --from-config --all 退出码折叠：全局配置缺失也返回非零"
    # new_home 建 agent-settings/skills/ 目录但不创建 skills.yaml，
    # 因此 sync_from_config 返回 1（"配置文件不存在"），整个 --all 应传播非零。
    local H; H=$(new_home)
    runc sync --from-config --all
    assert_rc_nonzero "sync --from-config --all 全局配置缺失 → 非零"
    assert_contains "仍打印配置缺失" "$OUT" "配置文件不存在"
}

# ════════════════════════════ 运行 ════════════════════════════
tc_help_and_deps
tc_add_global_link_and_record
tc_add_local_overwrite
tc_link_to_copy_migration_and_field_order
tc_add_copy_global
tc_opencode_paths_status_and_remove
tc_pi_paths_status_and_remove
tc_omp_paths_status_and_remove
tc_list_global_and_all
tc_status_global_ok
tc_status_global_missing_fix
tc_status_global_wrong_fix
tc_status_global_wrong_target_fix
tc_status_global_copy_wrong_type_fix
tc_status_global_copy_missing_fix
tc_status_global_copy_issue_folds
tc_status_global_orphan_fix
tc_status_all_exit_folds_global
tc_sync_all_exit_folds_global
tc_project_add_default_cwd_in_home
tc_no_manifest_isomorphism
tc_project_add_p_outside_home
tc_project_orphan_fix
tc_subagent_dir_and_md
tc_subagent_global_no_record
tc_subagent_disambiguation
tc_sync_from_agents_global
tc_opencode_sync_from_agents_and_config
tc_pi_sync_from_agents_and_config
tc_omp_sync_from_agents_and_config
tc_sync_from_agents_project_migration
tc_sync_from_config_global_idempotent
tc_sync_from_config_prunes_orphans
tc_sync_from_config_prune_spares_copies
tc_sync_from_config_project_and_all
tc_sync_real_file_guard
tc_sync_missing_central
tc_all_rejected_commands
tc_remove_partial_and_prune
tc_remove_global_partial
tc_remove_complete
tc_invalid_inputs
tc_plugin_yaml_roundtrip
tc_plugin_from_agents_import
tc_plugin_from_config_deploy

# ════════════════════════════ 汇总 ════════════════════════════
printf '\n══════════════════════════════════════\n'
printf '通过 %d  失败 %d  跳过 %d\n' "$PASS" "$FAIL" "$SKIP"
if [[ $FAIL -gt 0 ]]; then
    printf '\n失败用例:\n'
    for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
    echo "Smoke test 失败"
    exit 1
fi
echo "Smoke test 全部通过 ✅"
exit 0

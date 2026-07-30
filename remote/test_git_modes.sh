#!/usr/bin/env bash
#
# test_git_modes.sh — sync-remote git-push / git-pull / git-sync 沙箱回归
#
# 完全本地：用 PATH 上的假 ssh 把「远端」映射到临时目录，不依赖真 SSH / 集群 / GitHub。
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$ROOT_DIR/sync_remote.sh"

if [[ ! -x "$SYNC" && ! -f "$SYNC" ]]; then
    echo "找不到 sync_remote.sh: $SYNC" >&2
    exit 1
fi
chmod +x "$SYNC" 2>/dev/null || true

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t sync-remote-git)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

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
dump()  { printf '  ---- 输出 ----\n%s\n  --------------\n' "$1" >&2; }

assert_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected='$2' actual='$3')"; fi
}
assert_ok() {
    if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1 (exit=$2)"; dump "${3:-}"; fi
}
assert_fail() {
    if [[ "$2" -ne 0 ]]; then pass "$1"; else fail "$1 (expected non-zero exit)"; dump "${3:-}"; fi
}
assert_contains() {
    if grep -Fq -- "$3" <<< "$2"; then pass "$1"; else fail "$1 (未找到: $3)"; dump "$2"; fi
}

# ── 假 ssh：忽略选项，在本机执行远程命令 ─────────────────────────
FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
# 最小 ssh 替身：丢掉 -p/-o/...，host 之后的参数当远程命令执行
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|-F|-i|-l|-b|-c|-D|-E|-e|-L|-R|-W|-w)
            shift 2 || true
            ;;
        -o)
            shift 2 || true
            ;;
        -*)
            shift || true
            ;;
        *)
            break
            ;;
    esac
done
# $1 = host
if [[ $# -lt 1 ]]; then
    echo "fake-ssh: missing host" >&2
    exit 255
fi
shift
if [[ $# -eq 0 ]]; then
    echo "fake-ssh: missing remote command" >&2
    exit 255
fi
# 与 OpenSSH 一致：host 之后的参数用空格拼接，交给远端 shell -c。
# 不保留 bash -s 的 argv 边界（否则会掩盖未引用路径的问题）。
# git 典型: git-receive-pack '/abs/path'
# 探测: 单一参数 'bash -s -- quotedpath'（stdin 为脚本）
cmd="$*"
exec bash -c "$cmd"
FAKE_SSH
chmod +x "$FAKE_BIN/ssh"

# 也需要 scp? git 用 ssh 协议不需要 scp
export PATH="$FAKE_BIN:$PATH"

# ── 沙箱 HOME / 路径 ─────────────────────────────────────────────
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME/.config/remote"
REMOTE_BASE="$TMP_ROOT/remote_base"
mkdir -p "$REMOTE_BASE"

cat > "$HOME/.config/remote/config" <<EOF
DEFAULT_REMOTE_HOST="testhost"
DEFAULT_SYNC_HOST="testhost"
DEFAULT_REMOTE_BASE="$REMOTE_BASE"
DEFAULT_REMOTE_PORT="22"
DEFAULT_MODE="git-push"
EOF

LOCAL_PROJ="$HOME/proj"
REMOTE_PROJ="$REMOTE_BASE/proj"

git_init_at() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -b main >/dev/null 2>&1
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test User"
    # 允许 push 到非 bare 当前分支并更新工作树
    git -C "$dir" config receive.denyCurrentBranch updateInstead
}

# 两端同一初始 commit
init_pair_same_commit() {
    rm -rf "$LOCAL_PROJ" "$REMOTE_PROJ"
    git_init_at "$LOCAL_PROJ"
    echo "hello" > "$LOCAL_PROJ/a.txt"
    git -C "$LOCAL_PROJ" add a.txt
    git -C "$LOCAL_PROJ" commit -m "init" >/dev/null

    mkdir -p "$REMOTE_BASE"
    git clone --local "$LOCAL_PROJ" "$REMOTE_PROJ" >/dev/null 2>&1
    git -C "$REMOTE_PROJ" config user.email "test@example.com"
    git -C "$REMOTE_PROJ" config user.name "Test User"
    git -C "$REMOTE_PROJ" config receive.denyCurrentBranch updateInstead
    git -C "$REMOTE_PROJ" checkout main >/dev/null 2>&1 || true
}

advance_local() {
    local msg="${1:-local advance}"
    echo "$msg" >> "$LOCAL_PROJ/a.txt"
    git -C "$LOCAL_PROJ" add a.txt
    git -C "$LOCAL_PROJ" commit -m "$msg" >/dev/null
}

advance_remote() {
    local msg="${1:-remote advance}"
    echo "$msg" >> "$REMOTE_PROJ/a.txt"
    git -C "$REMOTE_PROJ" add a.txt
    git -C "$REMOTE_PROJ" commit -m "$msg" >/dev/null
}

local_head()  { git -C "$LOCAL_PROJ" rev-parse HEAD; }
remote_head() { git -C "$REMOTE_PROJ" rev-parse HEAD; }

run_sync() {
    # 输出到全局 LAST_OUT，退出码 LAST_EC
    local mode="$1"
    shift
    LAST_OUT=""
    LAST_EC=0
    set +e
    LAST_OUT=$(cd "$LOCAL_PROJ" && bash "$SYNC" -m "$mode" "$@" 2>&1)
    LAST_EC=$?
    set -e
}

# 有些环境 set -e 与函数组合敏感
set +e

# ════════════════════════════════════════════════════════════════
note "GP01 already up to date"
init_pair_same_commit
lh=$(local_head); rh=$(remote_head)
run_sync git-push
assert_ok "git-push exit 0" "$LAST_EC" "$LAST_OUT"
assert_contains "提示已同步" "$LAST_OUT" "已同步"
assert_eq "HEAD 不变 local" "$lh" "$(local_head)"
assert_eq "HEAD 不变 remote" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "GP02 local ahead clean"
init_pair_same_commit
advance_local "L1"
lh=$(local_head)
run_sync git-push
assert_ok "git-push exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "远端 HEAD=本地" "$lh" "$(remote_head)"
assert_eq "工作树 a.txt 对齐" "$(cat "$LOCAL_PROJ/a.txt")" "$(cat "$REMOTE_PROJ/a.txt")"

# ════════════════════════════════════════════════════════════════
note "GP03 remote ahead → push 拒"
init_pair_same_commit
advance_remote "R1"
lh=$(local_head); rh=$(remote_head)
run_sync git-push
assert_fail "git-push 应失败" "$LAST_EC" "$LAST_OUT"
assert_eq "本地 HEAD 不变" "$lh" "$(local_head)"
assert_eq "远端 HEAD 不变" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "GP04 diverged → push 拒"
init_pair_same_commit
advance_local "Ldiv"
advance_remote "Rdiv"
lh=$(local_head); rh=$(remote_head)
run_sync git-push
assert_fail "diverged push 失败" "$LAST_EC" "$LAST_OUT"
assert_eq "本地不变" "$lh" "$(local_head)"
assert_eq "远端不变" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "GP05 remote tracked dirty"
init_pair_same_commit
advance_local "L2"
echo dirty > "$REMOTE_PROJ/a.txt"   # tracked dirty，不 commit
lh=$(local_head); rh=$(remote_head)
run_sync git-push
assert_fail "远端 dirty 拒绝 push" "$LAST_EC" "$LAST_OUT"
assert_eq "远端 HEAD 未变" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "GP06 remote untracked only"
init_pair_same_commit
advance_local "L3"
echo "out" > "$REMOTE_PROJ/dqmc.out"
lh=$(local_head)
run_sync git-push
assert_ok "untracked 不拦 push" "$LAST_EC" "$LAST_OUT"
assert_eq "HEAD 对齐" "$lh" "$(remote_head)"
if [[ -f "$REMOTE_PROJ/dqmc.out" ]]; then pass "untracked 仍在"; else fail "untracked 丢失"; fi

# ════════════════════════════════════════════════════════════════
note "GP07 local tracked dirty → push 仍成功"
init_pair_same_commit
advance_local "L4"
echo dirty-local >> "$LOCAL_PROJ/a.txt"
lh=$(local_head)
run_sync git-push
assert_ok "本地 dirty 不拦 push" "$LAST_EC" "$LAST_OUT"
assert_eq "远端对齐" "$lh" "$(remote_head)"
if grep -q 'dirty-local' "$LOCAL_PROJ/a.txt"; then pass "本地 dirty 仍在"; else fail "本地 dirty 丢失"; fi

# ════════════════════════════════════════════════════════════════
note "GL01 remote ahead clean"
init_pair_same_commit
advance_remote "Rpull"
rh=$(remote_head)
run_sync git-pull
assert_ok "git-pull exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "本地 HEAD=远端" "$rh" "$(local_head)"
assert_eq "文件对齐" "$(cat "$REMOTE_PROJ/a.txt")" "$(cat "$LOCAL_PROJ/a.txt")"

# ════════════════════════════════════════════════════════════════
note "GL02 local ahead → pull 拒"
init_pair_same_commit
advance_local "Lpull-block"
lh=$(local_head); rh=$(remote_head)
run_sync git-pull
assert_fail "local ahead pull 失败" "$LAST_EC" "$LAST_OUT"
assert_eq "本地不变" "$lh" "$(local_head)"
assert_eq "远端不变" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "GL03 diverged → pull 拒"
init_pair_same_commit
advance_local "Ld2"
advance_remote "Rd2"
lh=$(local_head); rh=$(remote_head)
run_sync git-pull
assert_fail "diverged pull 失败" "$LAST_EC" "$LAST_OUT"
assert_eq "本地不变" "$lh" "$(local_head)"
assert_eq "远端不变" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "GL04 local dirty 无重叠 → pull 成功"
init_pair_same_commit
# 两端先共有 b.txt，再远端只推进 b、本地只脏 a
printf 'base-b\n' > "$LOCAL_PROJ/b.txt"
git -C "$LOCAL_PROJ" add b.txt
git -C "$LOCAL_PROJ" commit -m "add b" >/dev/null
run_sync git-push
assert_ok "准备基线 push" "$LAST_EC" "$LAST_OUT"
echo remote-b >> "$REMOTE_PROJ/b.txt"
git -C "$REMOTE_PROJ" add b.txt
git -C "$REMOTE_PROJ" commit -m "Rdirty-b" >/dev/null
echo local-a >> "$LOCAL_PROJ/a.txt"
rh=$(remote_head)
run_sync git-pull
assert_ok "无重叠 dirty pull 成功" "$LAST_EC" "$LAST_OUT"
assert_eq "HEAD 对齐" "$rh" "$(local_head)"
if grep -q 'local-a' "$LOCAL_PROJ/a.txt"; then pass "本地 a dirty 保留"; else fail "本地 a dirty 丢失"; fi
if grep -q 'remote-b' "$LOCAL_PROJ/b.txt"; then pass "远端 b 已并入"; else fail "远端 b 未并入"; fi

# ════════════════════════════════════════════════════════════════
note "GL04b local dirty 重叠 → pull 拒"
init_pair_same_commit
advance_remote "Roverlap"
echo local-overlap >> "$LOCAL_PROJ/a.txt"
rh=$(remote_head); lh=$(local_head)
run_sync git-pull
assert_fail "重叠 dirty pull 失败" "$LAST_EC" "$LAST_OUT"
assert_eq "本地 HEAD 不变" "$lh" "$(local_head)"
assert_eq "远端 HEAD 不变" "$rh" "$(remote_head)"
if grep -q 'local-overlap' "$LOCAL_PROJ/a.txt"; then pass "重叠 dirty 仍在"; else fail "重叠 dirty 丢失"; fi

# ════════════════════════════════════════════════════════════════
note "GL05 local untracked only"
init_pair_same_commit
advance_remote "Runtrk"
echo "local-out" > "$LOCAL_PROJ/noise.dat"
rh=$(remote_head)
run_sync git-pull
assert_ok "本地 untracked 不拦 pull" "$LAST_EC" "$LAST_OUT"
assert_eq "HEAD 对齐" "$rh" "$(local_head)"
if [[ -f "$LOCAL_PROJ/noise.dat" ]]; then pass "本地 untracked 仍在"; else fail "untracked 丢失"; fi

# ════════════════════════════════════════════════════════════════
note "GS01 equal"
init_pair_same_commit
lh=$(local_head)
run_sync git-sync
assert_ok "sync equal exit 0" "$LAST_EC" "$LAST_OUT"
assert_contains "无需操作" "$LAST_OUT" "已同步"
assert_eq "HEAD 不变" "$lh" "$(local_head)"

# ════════════════════════════════════════════════════════════════
note "GS02 local ahead"
init_pair_same_commit
advance_local "Lsync"
lh=$(local_head)
run_sync git-sync
assert_ok "sync push 成功" "$LAST_EC" "$LAST_OUT"
assert_eq "远端对齐" "$lh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "GS03 remote ahead"
init_pair_same_commit
advance_remote "Rsync"
rh=$(remote_head)
run_sync git-sync
assert_ok "sync pull 成功" "$LAST_EC" "$LAST_OUT"
assert_eq "本地对齐" "$rh" "$(local_head)"

# ════════════════════════════════════════════════════════════════
note "GS04 diverged"
init_pair_same_commit
advance_local "Lsdiv"
advance_remote "Rsdiv"
lh=$(local_head); rh=$(remote_head)
run_sync git-sync
assert_fail "sync diverged 拒绝" "$LAST_EC" "$LAST_OUT"
assert_eq "本地不变" "$lh" "$(local_head)"
assert_eq "远端不变" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "DR01 dry-run push"
init_pair_same_commit
advance_local "Ldry"
lh=$(local_head); rh=$(remote_head)
run_sync git-push -n
assert_ok "dry-run exit 0" "$LAST_EC" "$LAST_OUT"
assert_contains "预览" "$LAST_OUT" "预览"
assert_eq "dry-run 本地 HEAD 不变" "$lh" "$(local_head)"
assert_eq "dry-run 远端 HEAD 不变" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "ER01 本地非 git"
rm -rf "$LOCAL_PROJ"
mkdir -p "$LOCAL_PROJ"
# 远端随意
rm -rf "$REMOTE_PROJ"
mkdir -p "$REMOTE_PROJ"
set +e
LAST_OUT=$(cd "$LOCAL_PROJ" && bash "$SYNC" -m git-push 2>&1)
LAST_EC=$?
set -e
assert_fail "非 git 失败" "$LAST_EC" "$LAST_OUT"
assert_contains "错误信息" "$LAST_OUT" "不是 git 仓库"

# ════════════════════════════════════════════════════════════════
note "ER02 远端无 .git"
rm -rf "$LOCAL_PROJ" "$REMOTE_PROJ"
git_init_at "$LOCAL_PROJ"
echo x > "$LOCAL_PROJ/a.txt"
git -C "$LOCAL_PROJ" add a.txt
git -C "$LOCAL_PROJ" commit -m "only-local" >/dev/null
mkdir -p "$REMOTE_PROJ"
echo "not a repo" > "$REMOTE_PROJ/readme"
run_sync git-push
assert_fail "远端无 git 失败" "$LAST_EC" "$LAST_OUT"
assert_contains "提示" "$LAST_OUT" "不是 git 仓库"

# ════════════════════════════════════════════════════════════════
note "ER03 不在 HOME 下"
outside="$TMP_ROOT/outside_proj"
rm -rf "$outside"
git_init_at "$outside"
echo y > "$outside/a.txt"
git -C "$outside" add a.txt
git -C "$outside" commit -m "out" >/dev/null
set +e
LAST_OUT=$(cd "$outside" && bash "$SYNC" -m git-push 2>&1)
LAST_EC=$?
set -e
assert_fail "HOME 外失败" "$LAST_EC" "$LAST_OUT"
assert_contains "家目录提示" "$LAST_OUT" "家目录"

# ════════════════════════════════════════════════════════════════
note "GP08 幂等第二次 push"
init_pair_same_commit
advance_local "Lidem"
run_sync git-push
assert_ok "第一次 push" "$LAST_EC" "$LAST_OUT"
run_sync git-push
assert_ok "第二次 push" "$LAST_EC" "$LAST_OUT"
assert_contains "已同步" "$LAST_OUT" "已同步"

# ════════════════════════════════════════════════════════════════
note "BR01 分支名不一致"
init_pair_same_commit
git -C "$REMOTE_PROJ" branch -m main develop >/dev/null
git -C "$REMOTE_PROJ" checkout develop >/dev/null 2>&1
advance_local "Lbr"
run_sync git-push
assert_fail "分支名不一致拒绝" "$LAST_EC" "$LAST_OUT"
assert_contains "分支名" "$LAST_OUT" "分支名不一致"

# ════════════════════════════════════════════════════════════════
note "FP01 diverged + force"
init_pair_same_commit
advance_local "Lf1"
advance_remote "Rf1"
lh=$(local_head)
run_sync git-push -f
assert_ok "force push diverged" "$LAST_EC" "$LAST_OUT"
assert_eq "远端被本地覆盖" "$lh" "$(remote_head)"
assert_eq "工作树对齐" "$(cat "$LOCAL_PROJ/a.txt")" "$(cat "$REMOTE_PROJ/a.txt")"

# ════════════════════════════════════════════════════════════════
note "FP02 remote ahead + force"
init_pair_same_commit
advance_remote "Ronly"
lh=$(local_head)
run_sync git-push -f
assert_ok "force 覆盖远端超前" "$LAST_EC" "$LAST_OUT"
assert_eq "远端变成本地旧 tip" "$lh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "FP03 diverged 无 -f 仍拒"
init_pair_same_commit
advance_local "Lnof"
advance_remote "Rnof"
lh=$(local_head); rh=$(remote_head)
run_sync git-push
assert_fail "无 -f 拒绝" "$LAST_EC" "$LAST_OUT"
assert_eq "本地不变" "$lh" "$(local_head)"
assert_eq "远端不变" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "FP04 git-sync -f diverged"
init_pair_same_commit
advance_local "Lsf"
advance_remote "Rsf"
lh=$(local_head)
run_sync git-sync -f
assert_ok "sync -f 强推" "$LAST_EC" "$LAST_OUT"
assert_eq "远端=本地" "$lh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "EQ01 equal + local dirty → 已同步"
init_pair_same_commit
echo dirt >> "$LOCAL_PROJ/a.txt"
lh=$(local_head)
run_sync git-push
assert_ok "equal 本地 dirty 不拒" "$LAST_EC" "$LAST_OUT"
assert_contains "无需 push" "$LAST_OUT" "已同步"
assert_eq "HEAD 不变" "$lh" "$(local_head)"

# ════════════════════════════════════════════════════════════════
note "EQ02 equal + remote dirty → 已同步"
init_pair_same_commit
echo dirt >> "$REMOTE_PROJ/a.txt"
rh=$(remote_head)
run_sync git-pull
assert_ok "equal 远端 dirty 不拒" "$LAST_EC" "$LAST_OUT"
assert_contains "无需 pull" "$LAST_OUT" "已同步"
assert_eq "远端 HEAD 不变" "$rh" "$(remote_head)"

# ════════════════════════════════════════════════════════════════
note "PL01 remote ahead + remote dirty → pull 仍成功"
init_pair_same_commit
advance_remote "Rpl"
echo dirt >> "$REMOTE_PROJ/a.txt"
rh=$(remote_head)
run_sync git-pull
assert_ok "pull 忽略远端 dirty" "$LAST_EC" "$LAST_OUT"
assert_eq "本地 HEAD=远端 tip" "$rh" "$(local_head)"
# 远端工作树 dirty 仍在（pull 不碰远端）
if grep -q 'dirt' "$REMOTE_PROJ/a.txt"; then pass "远端 dirty 仍在"; else fail "远端 dirty 被改"; fi

# ════════════════════════════════════════════════════════════════
note "RT01 子目录调用失败"
init_pair_same_commit
mkdir -p "$LOCAL_PROJ/sub"
set +e
LAST_OUT=$(cd "$LOCAL_PROJ/sub" && bash "$SYNC" -m git-push 2>&1)
LAST_EC=$?
set -e
assert_fail "子目录拒绝" "$LAST_EC" "$LAST_OUT"
assert_contains "root 提示" "$LAST_OUT" "仓库根目录"

# ════════════════════════════════════════════════════════════════
note "QT01 路径含空格"
# 使用带空格的项目名与 remote base
SP_HOME="$TMP_ROOT/sp home"
SP_REMOTE_BASE="$TMP_ROOT/sp remote"
SP_LOCAL="$SP_HOME/my proj"
SP_REMOTE="$SP_REMOTE_BASE/my proj"
rm -rf "$SP_HOME" "$SP_REMOTE_BASE"
mkdir -p "$SP_HOME/.config/remote"
cat > "$SP_HOME/.config/remote/config" <<EOF
DEFAULT_REMOTE_HOST="testhost"
DEFAULT_SYNC_HOST="testhost"
DEFAULT_REMOTE_BASE="$SP_REMOTE_BASE"
DEFAULT_REMOTE_PORT="22"
DEFAULT_MODE="git-push"
EOF
git_init_at "$SP_LOCAL"
echo "sp" > "$SP_LOCAL/a.txt"
git -C "$SP_LOCAL" add a.txt
git -C "$SP_LOCAL" commit -m "sp-init" >/dev/null
mkdir -p "$SP_REMOTE_BASE"
git clone --local "$SP_LOCAL" "$SP_REMOTE" >/dev/null 2>&1
git -C "$SP_REMOTE" config user.email "test@example.com"
git -C "$SP_REMOTE" config user.name "Test User"
git -C "$SP_REMOTE" config receive.denyCurrentBranch updateInstead
echo "sp2" >> "$SP_LOCAL/a.txt"
git -C "$SP_LOCAL" add a.txt
git -C "$SP_LOCAL" commit -m "sp-adv" >/dev/null
lh=$(git -C "$SP_LOCAL" rev-parse HEAD)
OLD_HOME="$HOME"
export HOME="$SP_HOME"
set +e
LAST_OUT=$(cd "$SP_LOCAL" && bash "$SYNC" -m git-push 2>&1)
LAST_EC=$?
set -e
export HOME="$OLD_HOME"
assert_ok "空格路径 push" "$LAST_EC" "$LAST_OUT"
assert_eq "空格路径远端 HEAD" "$lh" "$(git -C "$SP_REMOTE" rev-parse HEAD)"
assert_eq "空格路径文件" "$(cat "$SP_LOCAL/a.txt")" "$(cat "$SP_REMOTE/a.txt")"

# ════════════════════════════════════════════════════════════════
printf '\n======== 汇总 ========\n'
printf 'PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
if [[ "$FAIL" -gt 0 ]]; then
    printf '\n失败用例:\n'
    for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "全部通过"
exit 0

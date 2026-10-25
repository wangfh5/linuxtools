#!/usr/bin/env bash
#
# test_copy_modes.sh — sync-remote copy-push / copy-pull 防覆盖与备份、dry-run 诊断、
# 以及 push/pull 对 .sync-backup 的排除回归
#
# 完全本地：用 PATH 上的假 ssh 把「远端」映射到临时目录，不依赖真 SSH / 集群。
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$ROOT_DIR/sync_remote.sh"

if [[ ! -f "$SYNC" ]]; then
    echo "找不到 sync_remote.sh: $SYNC" >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t sync-remote-copy)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

PASS=0
FAIL=0
declare -a FAILED=()
CURRENT="(setup)"

note()  { CURRENT="$1"; printf '\n=== %s ===\n' "$1"; }
pass()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
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
assert_contains() {
    if grep -Fq -- "$3" <<< "$2"; then pass "$1"; else fail "$1 (未找到: $3)"; dump "$2"; fi
}
assert_exists() {
    if [[ -e "$2" ]]; then pass "$1"; else fail "$1 (不存在: $2)"; fi
}
assert_absent() {
    if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 (不应存在: $2)"; fi
}

# ── 假 ssh：忽略选项，在本机执行远程命令（rsync 与 dry-run 的 stat 都经过它）──
FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|-o|-F|-i|-l) shift 2 || true ;;
        -*) shift ;;
        *) break ;;
    esac
done
shift  # host
exec bash -c "$*"
FAKE_SSH
chmod +x "$FAKE_BIN/ssh"
export PATH="$FAKE_BIN:$PATH"

# ── 沙箱 HOME / 路径 ─────────────────────────────────────────────
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME/.config/remote"
REMOTE_BASE="$TMP_ROOT/remote_base"
cat > "$HOME/.config/remote/config" <<EOF
DEFAULT_REMOTE_HOST="testhost"
DEFAULT_REMOTE_BASE="$REMOTE_BASE"
DEFAULT_REMOTE_PORT="22"
DEFAULT_MODE="copy-push"
EOF

L="$HOME/proj"
R="$REMOTE_BASE/proj"
SUB="sub dir"   # 含空格，覆盖路径引用
OLD=1700000000
NEW=1700003600

# put FILE CONTENT MTIME
put() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; touch -d "@$3" "$1"; }

reset_dirs() {
    rm -rf "$L" "$R"
    mkdir -p "$L/$SUB" "$R/$SUB"
}

run_sync() {
    LAST_OUT=$(cd "$L" && bash "$SYNC" -m "$1" "${@:2}" 2>&1)
    LAST_EC=$?
}

backup_count() { find "$1/.sync-backup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }

# 典型场景：
#   dqmc.out          接收端更新更长（作业仍在追加）—— 不应被覆盖
#   sub dir/energy.bin 源端更新 —— 覆盖，旧版本进备份
#   new.txt           仅源端有 —— 新增
#   .sync-backup/x    源端的旧备份 —— 不应被传输
# setup_case SRC DST
setup_case() {
    reset_dirs
    put "$1/dqmc.out" "short" $OLD
    put "$2/dqmc.out" "short+appended" $NEW
    put "$1/$SUB/energy.bin" "new-energy" $NEW
    put "$2/$SUB/energy.bin" "old-energy" $OLD
    put "$1/new.txt" "new" $OLD
    put "$1/.sync-backup/20000101-000000/stale" "stale" $OLD
}

# ════════════════════════════════════════════════════════════════
note "CP01 copy-push: 跳过远端较新、备份被覆盖文件、排除 .sync-backup"
setup_case "$L" "$R"
run_sync copy-push
assert_ok "copy-push exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "远端较新的 dqmc.out 保留" "short+appended" "$(cat "$R/dqmc.out")"
assert_eq "energy.bin 被更新" "new-energy" "$(cat "$R/$SUB/energy.bin")"
assert_eq "新文件已复制" "new" "$(cat "$R/new.txt")"
assert_eq "恰好一个备份目录" "1" "$(backup_count "$R")"
bk=$(find "$R/.sync-backup" -mindepth 1 -maxdepth 1 -type d | head -1)
assert_eq "备份保留旧 energy.bin（相对路径）" "old-energy" "$(cat "$bk/$SUB/energy.bin" 2>/dev/null)"
assert_absent "备份中没有未覆盖的 dqmc.out" "$bk/dqmc.out"
assert_absent "本地 .sync-backup 未传到远端" "$R/.sync-backup/20000101-000000"

note "CP02 copy-push 无覆盖时不产生新备份目录"
sleep 1   # 确保若产生备份会是新的时间戳目录
run_sync copy-push
assert_ok "copy-push exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "备份目录数不变" "1" "$(backup_count "$R")"

note "CP03 首次 copy-push（无覆盖）不创建 .sync-backup"
reset_dirs
put "$L/a.txt" "a" $OLD
run_sync copy-push
assert_ok "copy-push exit 0" "$LAST_EC" "$LAST_OUT"
assert_absent "远端无 .sync-backup" "$R/.sync-backup"

# ════════════════════════════════════════════════════════════════
note "CL01 copy-pull: 跳过本地较新、备份被覆盖文件、排除 .sync-backup"
setup_case "$R" "$L"
run_sync copy-pull
assert_ok "copy-pull exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "本地较新的 dqmc.out 保留" "short+appended" "$(cat "$L/dqmc.out")"
assert_eq "energy.bin 被更新" "new-energy" "$(cat "$L/$SUB/energy.bin")"
assert_eq "新文件已复制" "new" "$(cat "$L/new.txt")"
assert_eq "恰好一个备份目录" "1" "$(backup_count "$L")"
bk=$(find "$L/.sync-backup" -mindepth 1 -maxdepth 1 -type d | head -1)
assert_eq "备份保留旧 energy.bin" "old-energy" "$(cat "$bk/$SUB/energy.bin" 2>/dev/null)"
assert_absent "远端 .sync-backup 未传到本地" "$L/.sync-backup/20000101-000000"

# ════════════════════════════════════════════════════════════════
note "DR01 copy-push -n: 区分新增/覆盖并标出接收端更大或更新，不传输"
setup_case "$L" "$R"
put "$L/restart.out" "abc" $NEW          # 源更新但更短（重新开始的输出）
put "$R/restart.out" "abcdefgh" $OLD
before=$(cd "$R" && find . -type f -exec stat -c '%n %s %Y' {} + | sort)
run_sync copy-push -n
assert_ok "dry-run exit 0" "$LAST_EC" "$LAST_OUT"
assert_contains "新增" "$LAST_OUT" "[新增]          new.txt"
assert_contains "普通覆盖" "$LAST_OUT" "[覆盖]          $SUB/energy.bin"
assert_contains "接收端更大" "$LAST_OUT" "[覆盖!接收端更大] restart.out"
assert_contains "接收端较新" "$LAST_OUT" "[跳过:接收端较新] dqmc.out"
assert_contains "汇总" "$LAST_OUT" "汇总: 新增 1，覆盖 2（其中接收端更大 1），跳过（接收端较新）1"
assert_contains "警告" "$LAST_OUT" "警告: 有 1 个文件接收端更大"
after=$(cd "$R" && find . -type f -exec stat -c '%n %s %Y' {} + | sort)
assert_eq "远端未改动" "$before" "$after"

note "DR02 copy-pull -n: 接收端为本地"
setup_case "$R" "$L"
before=$(cd "$L" && find . -type f -exec stat -c '%n %s %Y' {} + | sort)
run_sync copy-pull -n
assert_ok "dry-run exit 0" "$LAST_EC" "$LAST_OUT"
assert_contains "接收端为本地" "$LAST_OUT" "接收端 = 本地"
assert_contains "接收端较新" "$LAST_OUT" "[跳过:接收端较新] dqmc.out"
assert_contains "普通覆盖" "$LAST_OUT" "[覆盖]          $SUB/energy.bin"
assert_contains "新增" "$LAST_OUT" "[新增]          new.txt"
after=$(cd "$L" && find . -type f -exec stat -c '%n %s %Y' {} + | sort)
assert_eq "本地未改动" "$before" "$after"

# ════════════════════════════════════════════════════════════════
note "PU01 push: 行为不变（覆盖、--delete），但不传也不删 .sync-backup"
setup_case "$L" "$R"
put "$R/extra.txt" "extra" $OLD
put "$R/.sync-backup/20200101-000000/keep" "keep" $OLD
run_sync push
assert_ok "push exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "push 仍覆盖远端较新文件" "short" "$(cat "$R/dqmc.out")"
assert_absent "push 仍删除远端多余文件" "$R/extra.txt"
assert_exists "远端已有备份未被 --delete 删除" "$R/.sync-backup/20200101-000000/keep"
assert_absent "本地 .sync-backup 未传到远端" "$R/.sync-backup/20000101-000000"

note "PL01 pull: 同上，方向相反"
setup_case "$R" "$L"
put "$L/extra.txt" "extra" $OLD
run_sync pull
assert_ok "pull exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "pull 仍覆盖本地较新文件" "short" "$(cat "$L/dqmc.out")"
assert_absent "pull 仍删除本地多余文件" "$L/extra.txt"
assert_absent "远端 .sync-backup 未传到本地" "$L/.sync-backup/20000101-000000"

# ════════════════════════════════════════════════════════════════
printf '\n======== 汇总 ========\n'
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    printf '\n失败用例:\n'
    for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "全部通过"
exit 0

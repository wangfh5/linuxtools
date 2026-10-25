#!/usr/bin/env bash
#
# test_copy_modes.sh — sync-remote copy-push / copy-pull 的 --update、缩小检查（-f 放行）、
# dry-run 诊断，以及 push/pull 行为不变的回归
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
assert_fail() {
    if [[ "$2" -ne 0 ]]; then pass "$1"; else fail "$1 (expected non-zero exit)"; dump "${3:-}"; fi
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
# FAKE_SSH_FAIL_STAT=1 时模拟读取远端文件状态失败（rsync 本身仍正常）
if [[ "${FAKE_SSH_FAIL_STAT:-}" == 1 && "$*" == *stat* ]]; then
    echo "fake-ssh: stat 失败" >&2
    exit 255
fi
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

snapshot() { (cd "$1" && find . -type f -exec stat -c '%n %s %Y' {} + | sort); }

# 典型场景（SRC → DST）：
#   dqmc.out           接收端更新更长（作业仍在追加）—— --update 跳过
#   sub dir/energy.bin 源更新更大 —— 正常覆盖
#   conf_u.out         源更新、大小相同（定长重写）—— 正常覆盖
#   new.txt            仅源端有 —— 新增
# setup_case SRC DST
setup_case() {
    reset_dirs
    put "$1/dqmc.out" "short" $OLD
    put "$2/dqmc.out" "short+appended" $NEW
    put "$1/$SUB/energy.bin" "new-energy-longer" $NEW
    put "$2/$SUB/energy.bin" "old-energy" $OLD
    put "$1/conf_u.out" "BBBB" $NEW
    put "$2/conf_u.out" "AAAA" $OLD
    put "$1/new.txt" "new" $OLD
}
# 再加一个"源更新但更小"的文件（输出被重新开始）
add_shrink() {
    put "$1/restart.out" "abc" $NEW
    put "$2/restart.out" "abcdefgh" $OLD
}

# copy_ok_checks DST：正常场景同步后的接收端断言
copy_ok_checks() {
    assert_eq "接收端较新的 dqmc.out 保留" "short+appended" "$(cat "$1/dqmc.out")"
    assert_eq "源更新更大的 energy.bin 覆盖" "new-energy-longer" "$(cat "$1/$SUB/energy.bin")"
    assert_eq "源更新同大小的 conf_u.out 覆盖" "BBBB" "$(cat "$1/conf_u.out")"
    assert_eq "新文件已复制" "new" "$(cat "$1/new.txt")"
}

# ════════════════════════════════════════════════════════════════
note "CP01 copy-push: 跳过远端较新，覆盖更大/同大小的较新源文件"
setup_case "$L" "$R"
run_sync copy-push
assert_ok "copy-push exit 0" "$LAST_EC" "$LAST_OUT"
copy_ok_checks "$R"

note "CP02 copy-push: 源更新但更小 → 中止且不传输任何文件"
setup_case "$L" "$R"
add_shrink "$L" "$R"
before=$(snapshot "$R")
run_sync copy-push
assert_fail "copy-push 应失败" "$LAST_EC" "$LAST_OUT"
assert_contains "列出源更小的文件" "$LAST_OUT" "[拦截:源更小]    restart.out"
assert_contains "显示接收端大小" "$LAST_OUT" "接收端: 8 B"
assert_eq "远端未改动" "$before" "$(snapshot "$R")"

note "CP03 copy-push -f: 跳过缩小检查并覆盖"
run_sync copy-push -f
assert_ok "copy-push -f exit 0" "$LAST_EC" "$LAST_OUT"
assert_contains "提示已跳过检查" "$LAST_OUT" "跳过缩小检查"
assert_eq "restart.out 被覆盖" "abc" "$(cat "$R/restart.out")"
copy_ok_checks "$R"

note "CP04 copy-push: mtime 相同、大小不同时按大小判断"
reset_dirs
put "$L/same_t_big.out" "longer" $OLD;  put "$R/same_t_big.out" "short" $OLD
run_sync copy-push
assert_ok "源更大 → 通过" "$LAST_EC" "$LAST_OUT"
assert_eq "源更大被覆盖" "longer" "$(cat "$R/same_t_big.out")"
put "$L/same_t_small.out" "ab" $OLD;    put "$R/same_t_small.out" "abcd" $OLD
run_sync copy-push
assert_fail "源更小 → 中止" "$LAST_EC" "$LAST_OUT"
assert_eq "源更小未被覆盖" "abcd" "$(cat "$R/same_t_small.out")"

note "CP05 copy-push: 远端状态读取失败 → 中止（-f 放行）"
setup_case "$L" "$R"
before=$(snapshot "$R")
LAST_OUT=$(cd "$L" && FAKE_SSH_FAIL_STAT=1 bash "$SYNC" -m copy-push 2>&1); LAST_EC=$?
assert_fail "copy-push 应失败" "$LAST_EC" "$LAST_OUT"
assert_contains "说明原因" "$LAST_OUT" "无法读取远端文件状态"
assert_eq "远端未改动" "$before" "$(snapshot "$R")"
LAST_OUT=$(cd "$L" && FAKE_SSH_FAIL_STAT=1 bash "$SYNC" -m copy-push -f 2>&1); LAST_EC=$?
assert_ok "-f 放行" "$LAST_EC" "$LAST_OUT"
copy_ok_checks "$R"

# ════════════════════════════════════════════════════════════════
note "CL01 copy-pull: 跳过本地较新，覆盖更大/同大小的较新源文件"
setup_case "$R" "$L"
run_sync copy-pull
assert_ok "copy-pull exit 0" "$LAST_EC" "$LAST_OUT"
copy_ok_checks "$L"

note "CL02 copy-pull: 源更新但更小 → 中止；-f 覆盖"
setup_case "$R" "$L"
add_shrink "$R" "$L"
before=$(snapshot "$L")
run_sync copy-pull
assert_fail "copy-pull 应失败" "$LAST_EC" "$LAST_OUT"
assert_contains "列出源更小的文件" "$LAST_OUT" "[拦截:源更小]    restart.out"
assert_eq "本地未改动" "$before" "$(snapshot "$L")"
run_sync copy-pull -f
assert_ok "copy-pull -f exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "restart.out 被覆盖" "abc" "$(cat "$L/restart.out")"
copy_ok_checks "$L"

# ════════════════════════════════════════════════════════════════
note "DR01 copy-push -n: 分类报告，不传输"
setup_case "$L" "$R"
add_shrink "$L" "$R"
ln -s new.txt "$L/link"                  # 新符号链接
put "$L/mode.sh" "same" $OLD; put "$R/mode.sh" "same" $OLD; chmod +x "$L/mode.sh"   # 仅权限变化
before=$(snapshot "$R")
run_sync copy-push -n
assert_ok "dry-run exit 0" "$LAST_EC" "$LAST_OUT"
assert_contains "新增" "$LAST_OUT" "[新增]          new.txt"
assert_contains "覆盖（更大）" "$LAST_OUT" "[覆盖]          $SUB/energy.bin"
assert_contains "覆盖（同大小）" "$LAST_OUT" "[覆盖]          conf_u.out"
assert_contains "跳过" "$LAST_OUT" "[跳过:接收端较新] dqmc.out"
assert_contains "拦截" "$LAST_OUT" "[拦截:源更小]    restart.out"
assert_contains "符号链接列为其他" "$LAST_OUT" "+++++++++ link"
assert_contains "权限变化列为其他" "$LAST_OUT" "p..... mode.sh"
assert_contains "汇总" "$LAST_OUT" "汇总: 新增 1，覆盖 2，跳过（接收端较新）1，拦截（源更小 1，状态未知 0），其他 2"
assert_contains "提示将中止" "$LAST_OUT" "实际同步将中止"
assert_eq "远端未改动" "$before" "$(snapshot "$R")"

note "DR02 copy-pull -n: 接收端为本地，无拦截"
setup_case "$R" "$L"
before=$(snapshot "$L")
run_sync copy-pull -n
assert_ok "dry-run exit 0" "$LAST_EC" "$LAST_OUT"
assert_contains "接收端为本地" "$LAST_OUT" "接收端 = 本地"
assert_contains "跳过" "$LAST_OUT" "[跳过:接收端较新] dqmc.out"
assert_contains "汇总" "$LAST_OUT" "汇总: 新增 1，覆盖 2，跳过（接收端较新）1，拦截（源更小 0，状态未知 0），其他 0"
if grep -Fq "实际同步将中止" <<< "$LAST_OUT"; then fail "不应提示中止"; else pass "无中止提示"; fi
assert_eq "本地未改动" "$before" "$(snapshot "$L")"

# ════════════════════════════════════════════════════════════════
note "PU01 push: 行为不变（无缩小检查，覆盖较新文件，--delete）"
setup_case "$L" "$R"
add_shrink "$L" "$R"
put "$R/extra.txt" "extra" $OLD
run_sync push
assert_ok "push exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "push 仍覆盖远端较新文件" "short" "$(cat "$R/dqmc.out")"
assert_eq "push 不做缩小检查" "abc" "$(cat "$R/restart.out")"
assert_absent "push 仍删除远端多余文件" "$R/extra.txt"

note "PL01 pull: 同上，方向相反"
setup_case "$R" "$L"
put "$L/extra.txt" "extra" $OLD
run_sync pull
assert_ok "pull exit 0" "$LAST_EC" "$LAST_OUT"
assert_eq "pull 仍覆盖本地较新文件" "short" "$(cat "$L/dqmc.out")"
assert_absent "pull 仍删除本地多余文件" "$L/extra.txt"

note "NB01 任何地方都没有 .sync-backup"
assert_eq "无 .sync-backup" "" "$(find "$TMP_ROOT" -name .sync-backup)"

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

# lib/materialize.sh — 物化原语（建链/建副本的单一实现）
#
# 把“从已记录配置部署一个 skill/subagent 到某 agent 目录”这一步的链接/副本动作收敛到一处，
# 供全局 sync_from_config 与项目 _project_deploy_skill 共用（§3 去重的低层原语）。
# 调用方负责 agent 目录的存在性与（各自不同的）建目录提示；这里只管目标项本身的幂等物化。
#
# 约定：
#   - 链接统一用 `ln -sfn`。三处调用点在 ln 前都已删除/跳过既有目标，目标在 ln 时不存在，
#     故 -sf 与 -sfn 行为等价；统一为 -sfn 仅是去除历史不一致，不改变可观察行为。
#   - 消息维持原样（"✓ <name> -> <label> (已存在|已创建|已存在 copy|copy 已创建)"、
#     "目标位置已存在非符号链接|非目录: <tgt>，跳过"），smoke 据此断言。

# 幂等部署一个符号链接。已是正确链接→跳过；旧链接→替换；非符号链接占位→跳过保护。
# 用法: mat_deploy_link <src> <agent_dir> <name> <label>
mat_deploy_link() {
    local src="$1" agent_dir="$2" name="$3" label="$4"
    local tgt="$agent_dir/$name"
    if [[ -L "$tgt" ]]; then
        local cur; cur=$(readlink "$tgt")
        if [[ "$cur" == "$src" ]]; then print_info "  ✓ $name -> $label (已存在)"; return 0; fi
        if ! /bin/rm "$tgt"; then print_error "删除旧链接失败: $tgt"; return 1; fi
    elif [[ -e "$tgt" ]]; then
        print_warn "目标位置已存在非符号链接: $tgt，跳过"; return 0
    fi
    if /bin/ln -sfn "$src" "$tgt"; then print_info "  ✓ $name -> $label (已创建)"; return 0; fi
    print_error "创建符号链接失败: $tgt"; return 1
}

# 幂等部署一个复制副本。已是副本→跳过；非目录占位→跳过保护。
# 用法: mat_deploy_copy <src> <agent_dir> <name> <label>
mat_deploy_copy() {
    local src="$1" agent_dir="$2" name="$3" label="$4"
    local tgt="$agent_dir/$name"
    if [[ -d "$tgt" && ! -L "$tgt" ]]; then print_info "  ✓ $name -> $label (已存在 copy)"; return 0; fi
    if [[ -e "$tgt" ]]; then print_warn "目标位置已存在非目录: $tgt，跳过"; return 0; fi
    if /bin/cp -r "$src" "$tgt"; then print_info "  ✓ $name -> $label (copy 已创建)"; return 0; fi
    print_error "复制失败: $src -> $tgt"; return 1
}

# 枚举 <agent_dir> 下指向中央目录 <central> 的条目，每个命中输出一行 "<method>\t<name>"：
#   - 符号链接且 readlink 落在 <central>/ 下          → method=link
#   - （allow_copy=1 时）实体目录且 <central>/<name> 存在 → method=copy
# 调用方据此套用各自策略（登记 / 报 ORPHAN / 删除…），从而消除 4 处镜像扫描循环。
# allow_copy=0 只认符号链接（用于 subagent 目录）。目录不存在或无命中则无输出。
# 名字经 <tab> 分隔、按行传出，故假定 skill/subagent 名不含 tab/换行——这与它们同时作为
# yq 键与 CLI 标识符的既有约束一致；含 tab/换行的病态目录名不在支持范围内。
# 用法: mat_scan_central_links <agent_dir> <central> [allow_copy:0|1，默认 1]
mat_scan_central_links() {
    local agent_dir="$1" central="$2" allow_copy="${3:-1}"
    [[ ! -d "$agent_dir" ]] && return 0
    local link name target method
    for link in "$agent_dir"/*; do
        [[ ! -e "$link" ]] && continue
        name=$(/usr/bin/basename "$link")
        method=""
        if [[ -L "$link" ]]; then
            target=$(readlink "$link")
            [[ "$target" == "$central"/* ]] || continue
            method="link"
        elif [[ "$allow_copy" == "1" && -d "$link" && -d "$central/$name" ]]; then
            method="copy"
        else
            continue
        fi
        printf '%s\t%s\n' "$method" "$name"
    done
}

# 判定目标项相对“应是 <method> 指向 <src>”的一致性状态（纯判定：不打印、不修复）。
# 输出四态之一：
#   ok           已正确（link 指向 src / copy 为实体目录）
#   wrong_target 是符号链接但指向别处——同时回带实际目标（"wrong_target\t<actual>"）
#   wrong_type   存在但类型不符（期望 link 却是目录/文件，或期望 copy 却非目录）
#   missing      不存在
# 调用方据此各自渲染（缩进/文案）与修复（策略不同），从而统一“OK/WRONG/MISSING”这套语义判定。
# 用法: cls=$(mat_classify <target_path> <src> <method>); IFS=$'\t' read -r state actual <<< "$cls"
mat_classify() {
    local tgt="$1" src="$2" method="$3"
    if [[ "$method" == "copy" ]]; then
        if [[ -d "$tgt" && ! -L "$tgt" ]]; then echo "ok"
        elif [[ -e "$tgt" ]]; then echo "wrong_type"
        else echo "missing"; fi
        return 0
    fi
    if [[ -L "$tgt" ]]; then
        local cur; cur=$(readlink "$tgt")
        if [[ "$cur" == "$src" ]]; then echo "ok"; else printf 'wrong_target\t%s\n' "$cur"; fi
    elif [[ -e "$tgt" ]]; then echo "wrong_type"
    else echo "missing"; fi
}

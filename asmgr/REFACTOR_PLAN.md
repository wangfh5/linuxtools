# skill-mgr 重构方案

> **状态：方案，不执行。** 本文只规划重构，不改动 `skill_mgr.sh` / `lib/*.sh` 的行为，
> 也不给目录改名。落地前提是 `smoke_test.sh` 已对当前代码全绿（158 通过 / 0 失败），
> 它就是重构的回归契约——任何一步重构后都必须保持全绿。

---

## 0. 当前架构速写（重构的出发点）

```
skill-mgr/
├── skill_mgr.sh        # 入口：依赖检查 / 常量 / 通用 helper / 命令分发 / 全局 skill 的 status&sync / help
├── lib/yaml.sh         # 全局注册表 skills.yaml 读写
├── lib/sources.sh      # 来源获取(github/local/中央名) + install_to_agents(link/copy 物化)
├── lib/plugin.sh       # Claude Code plugin/marketplace（skills.yaml 的 claude_code 段）
└── lib/project.sh      # 项目局域清单 projects/<name>.yaml 读写 + 链接重建/扫描/状态
```

数据在另一个仓库 `~/agent-settings/`（`skills/`、`agents/`、`projects/`、`skills.yaml`）。
工具里唯一硬编码是 `SKILLS_DIR="$HOME/agent-settings/skills"`，其余（`AGENT_SETTINGS_ROOT`、
`AGENTS_DIR`、`PROJECTS_DIR`、各 agent 家目录）都由它现场派生——**这也是 smoke_test 能整体
重定向到沙箱 HOME 的根因**。

它的真实职责早已超出“skill 安装器”：管理 **skills + subagents + 项目局域清单 +
Claude Code plugin/marketplace**，横跨 **cursor / claude-code / codex / gemini** 四个工具，
并有统一的 scope 模型（默认 cwd / `-g` / `-p` / `--all`）。下面五节对应验收的五个问题。

---

## 1. 命名与身份

### 问题

`skill-mgr` 名不副实：它已是 `~/agent-settings` 这个中央配置仓库的**大管家**，而不仅是 skill 安装器。
名字把它窄化成了一个能力子集，新读者会低估它的职责面。

### 现状约束（改名要顾及的耦合点）

- 二进制经 `~/bin/skill-mgr` 符号链接暴露，**已写进肌肉记忆**，也写进 `~/agent-settings/CLAUDE.md`
  的多处工作流（“skills 的管理：用 skill-mgr”“项目局域 skill/subagent 的管理”）。
- `README.md`、help 文本、`agent-settings/CLAUDE.md` 全都用 `skill-mgr` 这个词。
- 命令名 `skill-mgr add/list/status/sync/remove` 出现在大量文档示例里。

### 方案

把**项目目录名/产品定位**与**面向用户的命令名**分开决策：

1. **项目目录改名**（cwd 在父目录正是为评估这一点）。候选：
   - `agent-settings-cli` —— 与数据仓库 `agent-settings` 显式配对，语义最准（“它是 agent-settings 的 CLI”）。
   - `asmgr` / `agentctl` —— 更短，适合做命令名。
   - 维持 `skill-mgr` —— 零迁移成本，但继续名不副实。

   **✅ 已执行（Phase 5）**：用户选定更短的 **`asmgr`**（agent-settings manager）。目录 `skill-mgr`→`asmgr`、
   入口 `skill_mgr.sh`→`asmgr.sh`、`~/bin` 同时提供 `asmgr` 与（兼容）`skill-mgr` 两个软链、README/help/
   `agent-settings/CLAUDE.md` 称呼同步刷新。下面关于 `agent-settings-cli` 的原始建议保留作设计记录：

   **建议（原始设计）**：目录改为 **`agent-settings-cli`**（定位最清晰），并在 `README` 顶部写明一句话身份：

   > **agent-settings-cli** — `~/agent-settings` 中央配置仓库的命令行管家：统一管理 skills、
   > subagents、项目局域清单与 Claude Code plugin/marketplace，跨 cursor / claude-code / codex / gemini，
   > 一套 scope 模型（默认当前目录 / `-g` 全局 / `-p` 项目 / `--all`）。

2. **命令名**：保留向后兼容，**不强迫用户改肌肉记忆**。
   - 入口脚本可改名为 `agent-settings-cli.sh`，但**保留 `~/bin/skill-mgr` 软链**继续可用；
     可另加一个更短的别名（如 `~/bin/asmgr`）。
   - 子命令 `add/list/status/sync/remove` 全部保持不变（smoke_test 锁的就是这套）。

3. **文档迁移**：改名后同步更新 `README.md`、help 文本、`agent-settings/CLAUDE.md` 三处的称呼，
   并在 README 留一行“原名 skill-mgr，命令兼容”，避免外部链接/记忆断裂。

> 改名是“包装层”动作（目录名 + 软链 + 文档），**不触碰任何命令行为**，因此 smoke_test 不受影响。
> 建议作为重构的**最后一步**，等模块重构落定、测试持续全绿后再做。

---

## 2. 模块边界

把当前“按文件偶然切分”重组为“按职责分层”。建议的目标结构（命令名/行为不变）：

```
lib/
├── core.sh          # 常量、路径派生、print_*、prompt_yes_no、now_timestamp_local、
│                    #   build_yaml_array、merge_unique_agents、filter_out_agents、check_dependencies
├── scope.sh         # 统一 scope 解析（见 §4）：把 -g/-p/--all/默认cwd 解析成 (scope, base_dir, store 后端)
├── store.sh         # “记录后端”抽象：skills.yaml(全局注册表) 与 projects/*.yaml(项目清单) 的统一读写接口
│                    #   （现 lib/yaml.sh 的 update/get/remove 与 lib/project.sh 的 pm_* 是平行镜像，见 §3）
├── materialize.sh   # 物化与校验的**单一**实现：建链/建副本、状态分类(OK/WRONG/MISSING)、孤立扫描（见 §3）
├── sources.sh       # 来源获取：github sparse-checkout / 本地复制 / 中央名搜索 / subagent 名解析
├── plugin.sh        # Claude Code plugin/marketplace（skills.yaml 的 claude_code 段）—— 基本可原样保留
└── commands/        # 命令层：add / list / status / sync / remove，各自只做“解析→调度→汇报”
    ├── add.sh  list.sh  status.sh  sync.sh  remove.sh
```

入口 `agent-settings-cli.sh` 只保留：PATH 兜底、`source` 各 lib、`main` 分发、`show_help`。

**职责切分要点**

| 关注点 | 归属 | 说明 |
|---|---|---|
| skills | `sources.sh`(获取) + `store.sh`(记录) + `materialize.sh`(物化) | 三层各司其职 |
| subagents | `sources.sh::resolve_subagent_name` + `store.sh`(subagents 段) + `materialize.sh` | 与 skill 共用物化层，目标目录不同(`.claude/agents`) |
| 项目清单 | `store.sh`(项目实现) + `scope.sh` | 文件名命名规则(`/`→`__`)、`path` 权威定位收在 store 层 |
| plugins | `plugin.sh` | 独立子系统，仅 sync 命令调用 |
| scope 解析 | `scope.sh` | 所有命令共用一处（见 §4） |
| 物化层 | `materialize.sh` | 建链/检测/孤立扫描的唯一真相（见 §3） |

> subagent 当前“固定 claude-code → `.claude/agents`”。物化层应把“目标目录如何由 (kind, agent, base_dir)
> 决定”做成一个映射函数（skill→`<base>/.<agent>/skills/`，subagent→`<base>/.claude/agents/`），
> 让 link/copy/check/orphan 全部走同一套低层原语。

---

## 3. 跨文件重复逻辑（本次重构的核心权衡）

### 现状：三份镜像副本

“建链/检测链接、状态分类(OK/WRONG/MISSING)、孤立扫描”目前在三处各有一份**刻意镜像、而非互相调用**的实现：

| 关注点 | 全局实现 | 项目实现 | 安装实现 |
|---|---|---|---|
| 建符号链接/副本 | `skill_mgr.sh::sync_from_config`（内联循环） | `lib/project.sh::_project_deploy_skill` | `lib/sources.sh::install_to_agents` |
| 状态 OK/WRONG/MISSING | `skill_mgr.sh::status_check_configured_skill` | `lib/project.sh::_status_check_entry` / `_status_check_subagent` | — |
| 孤立(ORPHAN)扫描 | `skill_mgr.sh::status_scan_orphans` | `lib/project.sh::_project_scan_orphans` | — |

镜像带来了**真实的语义漂移**（已被 smoke_test 钉住为当前契约，重构时务必逐项对齐或显式保留）：

1. **`ln -sf` vs `ln -sfn`**：全局路径（`skill_mgr.sh` + `sources.sh`）用 `ln -sf`，项目/subagent
   路径（`project.sh`）用 `ln -sfn`。对“目标已是指向目录的符号链接”这种情形，`-n` 影响是否解引用。
2. **ORPHAN 的 `--fix` 策略相反**：全局 `status --fix` 把孤立链接**补进配置**（`update_skills_yaml`）；
   项目 `status --fix` 把孤立链接**直接删除**（`rm`）。这是**有意的策略差异**，不是 bug。
3. **状态命令退出码不一致**：`status -p` 返回“有无问题”（0/1），`status -g` **恒返回 0**（见 §6 缺陷②）。

### 权衡：抽公共层 vs 维持解耦

| | 抽公共层 | 维持镜像解耦 |
|---|---|---|
| 优点 | 消除 ~3 份重复；漂移(`-sf`/`-sfn`、退出码)一次性收敛；新增第 5 个 agent/scope 只改一处 | 改一处不会意外波及另一处；各 scope 行为读起来直白；零回归风险 |
| 缺点 | 全局/项目的 ORPHAN 策略**确实不同**，公共层必须留 policy 钩子，抽象不当反而更绕 | 漂移会持续积累；同一种 bug 要修三遍；认知负担 |

### 建议：抽“低层原语”，保留“高层策略”

把**确定无歧义的低层动作**抽进 `materialize.sh` 单一实现，把**因 scope 而异的策略**留在薄包装里：

- **抽出（统一）**：
  - `mat_link <src> <dst>` / `mat_copy <src> <dst>`：统一用 `ln -sfn`（收敛 `-sf`/`-sfn` 漂移——
    但这是**行为变更**，须确认 smoke_test 仍绿且语义等价后再合入）。
  - `mat_classify <dst> <src> <method>`：返回 `OK|WRONG|MISSING` 之一（纯判定，不打印、不修复）。
  - `mat_scan_central_links <agent_dir>`：列出 `<agent_dir>` 下指向中央目录的链接/副本及其 method。
- **保留（策略钩子，按 scope 注入）**：
  - 渲染（打印 `[OK]/[WRONG]/...` 的格式：全局无缩进、项目有两格缩进——属表现层差异，可参数化）。
  - `--fix` 行为（global=补配置；project=删链）做成回调，由各命令层传入。
  - 退出码语义统一为“有问题→非零”（见 §6，需同时修 `status -g`）。

> 这样既砍掉绝大部分重复，又不强行抹平 global/project 本就不同的策略。**注意**：任何“收敛漂移”
> （`-sf`→`-sfn`、`status -g` 退出码归一）都是**行为变更**，不属于“纯结构重构”——
> 应在方案里单列、单独提交、并确认 smoke_test 的对应断言随之更新（而不是偷偷夹带）。

---

## 4. 命令分发与 scope 解析的统一化

### 现状

- `main` 用 `case` 分发到 `cmd_add/list/status/sync/remove`——这部分结构清晰，**可基本保留**。
- 但每个 `cmd_*` 各自重写一遍 `-g/-p/--all/--fix` 的 `while`/`case` 解析，校验细节略有出入：
  - 互斥校验（`-g` 与 `-p`）只在 `add`/`remove` 里手写。
  - `--all` 的接受范围靠“谁解析了 `--all`”隐式决定：`list/status/sync` 认；`add/remove` 把它当
    “未知参数”报错；`sync --from-agents --all` 单独显式报“不适用”。**这三种拒绝路径不一致**
    （smoke_test 已分别钉住）。
  - 默认 scope=cwd 的 `base_dir="$(/bin/pwd)"` 在多处重复。

### 方案：单一 `resolve_scope`

提供一个集中解析器，所有命令复用：

```
resolve_scope <command-name> "$@"
  → 设置：SCOPE(cwd|global|project|all)
          BASE_DIR（cwd/project 时）
          STORE_KIND（global=registry / 其余=manifest）
  → 校验：① -g 与 -p 互斥；② --all 仅 list/status/sync--from-config 允许，
          其余命令遇 --all 统一给同一句错误并非零退出；
          ③ -p 目录不存在 → 统一错误
  → 回显：去掉 scope flag 后剩余的位置参数，交还命令层
```

收益：scope 语义只有一处定义，新增 scope 或调整 `--all` 支持面只改一个函数；
四种 scope 的互斥与默认 cwd 不再散落。**风险**：要保证三条 `--all` 拒绝路径的**对外可观察输出**
与现状一致（或有意统一时同步改 smoke_test）。建议先“同输出地集中”，再考虑是否统一文案。

---

## 5. 错误与边界处理

### 当前已是正确契约（重构必须保住，smoke_test 已覆盖）

- **真实文件占位不覆盖**：`sync --from-config` 遇到目标位置是真实文件/目录（非符号链接）时跳过并告警，
  不破坏用户数据。
- **中央目录缺失**：`sync --from-config` 对“配置有记录但中央 `skills/<name>` 不存在”的条目跳过并告警。
- **配置缺失**：`sync --from-config -g` 在 `skills.yaml` 不存在时报错并非零退出。
- **项目目录不存在**：`add -p <不存在>` 报错非零。
- **本地源不存在 / 无 SKILL.md**：`copy_from_local` 报错非零。
- **依赖缺失**：启动时 `check_dependencies` 检查 `yq/git/jq`，缺失给出安装指引并非零退出。
- **add 遇 agent 目录不存在**：交互式 `prompt_yes_no` 询问是否创建。

### 建议改进（重构时一并梳理，注意区分“纯结构”与“行为变更”）

1. **`check_dependencies` 分层**：`jq` 只有 plugin 子命令用到，却在启动时强制要求。建议改为
   “`yq/git` 必需、`jq` 惰性检查（仅 plugin 路径需要时报缺失）”。——这是**行为变更**，会影响
   “无 jq 也能跑 add/list”的可观察性；若采纳需新增/调整 smoke_test 断言。
2. **退出码语义统一**：让所有 `status` 与 `sync` 在“发现问题/部署失败”时返回非零（修 §6 缺陷①②）。
3. **错误信息集中**：把“项目目录不存在”“-g/-p 互斥”“--all 不支持”等文案集中到 `scope.sh`，消除多副本。

---

## 6. 已知缺陷（重构时**显式**处理，禁止顺手偷改）

> 本会话发现、但按约束**未修复**的真实缺陷。smoke_test 已据实锁定它们的**当前行为**
> （而不是“应该的行为”），所以重构者改它们时测试会变红——这正是预期的信号：
> 改 bug 是行为变更，必须单独提交并同步更新对应断言。

1. **`sync --from-config --all` 在有已登记项目时退出码为非零（功能其实成功）。**
   根因：`lib/project.sh::project_deploy_all` 的末句是 `[[ $any -eq 0 ]] && print_info ...`，
   当 `any=1`（确有项目）时该复合命令求值为假 → 函数返回 1 → 一路冒泡成命令退出码 1。
   链接部署本身完全成功。
   - **✅ 已修复（Phase 4）**：`project_deploy_all` 末尾显式 `return 0`；smoke 对应断言改为
     `sync --from-config --all` 退出码 0。

2. **`status -g` 恒返回 0，即使存在 WRONG/MISSING/ORPHAN。**
   `skill_mgr.sh::status_global` 不像 `project_status_one` 那样 `return $found_issue`，其最后一句是
   打印汇总的 `if/else`（返回 echo 的 0）。导致 `status -g` 与 `status -p` 退出码语义不一致
   （已用 `/tmp` 实测确认：同样的 MISSING 情形 `status -p` 返回 1、`status -g` 返回 0）。
   - **✅ 已修复（Phase 4）**：`status_global` 末尾 `return $has_issues`，与项目侧对齐；smoke
     对应断言改为“`status -g` 有问题返回非零”。（`status --all` 的退出码仍只反映项目侧
     —— 末句是 `project_status_all`；这是另一个独立小 quirk，未在本次缺陷清单内，留待后续。）

3. **`ln -sf` 与 `ln -sfn` 在全局/项目路径之间不一致**（见 §3）。全局物化用 `ln -sf`，
   项目/subagent 物化用 `ln -sfn`。
   - **✅ 已统一（Phase 2a）**：物化原语 `mat_deploy_link` 统一用 `ln -sfn`；因所有调用点在
     `ln` 前都已删除/跳过既有目标，目标在 `ln` 时不存在，`-sf`/`-sfn` 等价，故为行为中立收敛。

4. **`jq` 启动强制依赖**（见 §5 改进 1）。本次未处理（不在用户选定的三项缺陷内），留作后续。

---

## 7. 重构落地顺序（建议）

每一步结束都必须 `bash smoke_test.sh` 全绿（行为变更步骤则同步更新断言并说明）：

1. **纯搬运，零行为变更**：按 §2 拆分文件（`core.sh`/`store.sh`/`materialize.sh`/`scope.sh`/`commands/`），
   只移动函数、不改逻辑。每搬一块跑一次 smoke_test。
2. **抽低层物化原语**（§3）：把三处建链/检测改为调用 `materialize.sh` 的统一原语，**逐处替换、逐处验绿**；
   保留 global/project 的策略钩子。
3. **统一 scope 解析**（§4）：引入 `resolve_scope`，命令层改用它；保住三条 `--all` 拒绝路径的可观察输出。
4. **集中边界/错误处理**（§5）。
5. **行为变更（单独提交、单独说明、同步改断言）**：修 §6 的退出码缺陷、`-sf`→`-sfn` 收敛、`jq` 惰性化。
6. **改名与文档**（§1）：目录改 `agent-settings-cli`、保留 `skill-mgr` 软链兼容、刷新 `README` 与
   `agent-settings/CLAUDE.md` 的称呼与身份段。

---

## 8. 回归契约：`smoke_test.sh`

重写后的 `smoke_test.sh` 是本次重构的安全网，对当前代码 **158 通过 / 0 失败 / 0 跳过**。要点：

- **完全沙箱**：每个用例一个 `mktemp -d` 的独立 HOME，工具的所有中央路径从 `$HOME` 派生，
  绝不触碰真实 `~/agent-settings`（已实测：跑测试前后真实仓库 `skills.yaml`、`projects/` 不变）。
- **覆盖能力清单每一项**：add/list/status/sync/remove × scope(默认cwd/`-g`/`-p`/`--all`)；
  skill 的 link+copy（含 link↔copy 迁移、`skills.yaml` 字段顺序）；subagent(`-s`，目录型/`.md`型/
  与同名 skill 消歧/全局只建链不记录)；项目清单（写入、`$HOME` 内相对 vs `$HOME` 外绝对命名、空清单 prune）；
  `sync --from-agents` 迁移扫描与 `--from-config` 幂等；`status` 的 OK/MISSING/WRONG/ORPHAN+`--fix`
  （全局“补配置” vs 项目“删链”差异）；真实文件占位不覆盖、路径不存在、中央目录缺失、依赖缺失
  （依赖缺失用例做了可移植性 guard：若 `yq/jq` 落在脚本会前置的标准目录里则诚实 SKIP）；
  plugin/marketplace 三路覆盖——`skills.yaml` 库级 round-trip（纯 yq、无网络），加上**hermetic** 的
  双向集成（用临时 PATH 里的 fake `claude` 桩，既不依赖真实 claude、也不读宿主机 XDG/认证/缓存）：
  `sync --from-agents` 从 fake claude 导入 marketplace+plugin、`sync --from-config` 把 yaml 的
  `claude_code` 段部署到 fake claude（断言桩收到 `marketplace add` / `plugin install` 调用）。
- **据实断言**：对 §6 的已知缺陷，测试锁的是**当前行为**而非理想行为；重构修缺陷时测试会变红，
  这是有意的提醒——届时同步更新对应断言，使“修 bug”成为显式、可见的一步。

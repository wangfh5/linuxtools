# asmgr

**asmgr (agent-setting manager)** — `~/agent-settings` 中央配置仓库的命令行管家：统一管理 skills、subagents、
项目局域清单与 Claude Code plugin/marketplace，横跨 cursor / claude-code / codex / gemini / opencode / pi / omp，一套 scope 模型
（默认当前目录 / `-g` 全局 / `-p` 项目 / `--all`）。

核心思路：所有 skill 实体只存一份在中央目录 `~/agent-settings/skills/`，各 agent 目录通过**符号链接**
（或在不支持链接时**复制**）指过去；安装状态声明式记录在 yaml 里，换机器一键恢复。

## 安装

```bash
cd ~/path/to/linuxtools

# 符号链接到 ~/bin
mkdir -p ~/bin
ln -sf $(pwd)/asmgr/asmgr.sh ~/bin/asmgr

# 确保 ~/bin 在 PATH 中
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# 必须安装 yq 和 jq（asmgr 启动时强制检查，缺任一则拒绝运行）
brew install yq jq
```

## 核心概念

### 中央存储目录

所有受管实体集中存放在 `~/agent-settings/`，随该仓库一起 git 同步：

```
~/agent-settings/
├── skills/                 # 所有 skill 实体（单一真相来源）
│   ├── skills.yaml         #   全局安装注册表
│   ├── skill-creator/
│   └── ...
├── agents/                 # 所有 subagent 实体（目录或 .md）
└── projects/               # 项目局域清单，每项目一个 <name>.yaml
```

各 agent 目录里只放指向中央目录的链接/副本（符号链接模式下“更新一处，处处生效”；复制模式需重新安装才同步）。

### scope 模型（所有命令通用）

scope 决定操作落在哪里、状态记到哪个文件：

| scope | flag | 操作目标 | 记录到 |
|-------|------|----------|--------|
| 当前目录项目 | 默认（无 flag） | agent 对应项目 skills 目录（见下表） | `~/agent-settings/projects/<name>.yaml` |
| 全局 | `-g` | agent 对应全局 skills 目录（见下表） | `~/agent-settings/skills/skills.yaml` |
| 指定项目 | `-p <dir>` | agent 对应项目 skills 目录（见下表） | `~/agent-settings/projects/<name>.yaml` |
| 全部 | `--all` | 全局 + 所有已登记项目 | 二者 |

`--all` 仅 `list` / `status` / `sync --from-config` 支持。

**全局与项目记录互不相干**：`skills.yaml` 只记全局安装（`-g`），项目安装写各自的清单文件。

### agent 目录映射

无论全局还是项目，都用相同的目录结构，agent 才能识别加载：

| Agent | 全局（`-g`） | 项目（默认 / `-p`） |
|-------|------|------|
| cursor | `~/.cursor/skills/` | `<project>/.cursor/skills/` |
| claude-code | `~/.claude/skills/` | `<project>/.claude/skills/` |
| codex | `~/.codex/skills/` | `<project>/.codex/skills/` |
| gemini | `~/.gemini/skills/` | `<project>/.gemini/skills/` |
| opencode | `~/.config/opencode/skills/` | `<project>/.opencode/skills/` |
| pi | `~/.pi/agent/skills/` | `<project>/.pi/skills/` |
| omp | `~/.omp/agent/skills/` | `<project>/.omp/skills/` |

subagent（`-s`）固定走 claude-code，链接到 `.claude/agents/`（全局为 `~/.claude/agents/`）。

### 链接 vs 复制

默认创建符号链接；`-c` 改为复制整个目录，用于不支持符号链接的 agent。

```bash
asmgr add ./my-skill -a cursor -g        # 符号链接：~/.cursor/skills/my-skill -> 中央目录
asmgr add ./my-skill -a codex  -g -c     # 复制：~/.codex/skills/my-skill（实体目录）
```

复制模式占更多磁盘，且更新中央目录后需重新安装才能同步；符号链接模式则自动同步。删除复制目录时会要求确认。

## 命令概览

| 命令 | 功能 |
|------|------|
| `asmgr add <source> [-a <agents>] [-s] [-g\|-p <dir>] [-c]` | 添加 skill 到中央目录并链接；`-s` 把已有 subagent 链接到 `.claude/agents` |
| `asmgr list [-g\|-p <dir>\|--all]` | 列出 skills / 项目清单及安装状态 |
| `asmgr status [--fix] [-g\|-p <dir>\|--all]` | 检查配置与实际链接的一致性（`--fix` 自动修复） |
| `asmgr sync --from-agents [-g\|-p <dir>]` | 从现有安装（link/copy）反向重建配置 |
| `asmgr sync --from-config [-g\|-p <dir>\|--all]` | 从配置正向重建链接（新机器部署）；全局 scope 下 config 即真相，删除未声明的游离链接 |
| `asmgr remove <skill> [-a <agents>] [-s] [-g\|-p <dir>]` | 移除 skill/subagent（完全移除或从指定 scope 移除） |

完整参数与示例见 `asmgr --help`。

## 使用方法

### add — 添加 skill

```bash
asmgr add <source> [-a <agents...>] [-g|-p <dir>] [-c]
```

**source 支持三种格式：**

| 格式 | 示例 | 说明 |
|------|------|------|
| GitHub URL | `https://github.com/anthropics/skills/tree/main/skills/skill-creator` | 从 GitHub 下载 |
| 本地路径 | `/path/to/skill`、`./skill`、`../skill` | 从本地复制（必须以 `/`、`./`、`../` 开头） |
| Skill 名称 | `skill-creator`、`creator` | 搜索中央目录（支持模糊匹配） |

**scope 由 flag 决定**（见上文 scope 模型）：

```bash
# 当前目录项目（默认）
asmgr add ./my-skill -a cursor
# 全局
asmgr add ./my-skill -a cursor -g
# 指定项目
asmgr add ./my-skill -a cursor -p ~/projects/foo
# 多 agents / 从 GitHub 添加（全局）
asmgr add https://github.com/anthropics/skills/tree/main/skills/skill-creator -a cursor claude-code -g
```

说明：
- 不传 `-a` 时只下载/复制到中央目录，不写任何配置。
- `-g` 与 `-p` 不能同时使用。

### 项目局域 skill / subagent 工作流

把某些 skill/subagent 绑定到具体项目，而不是装到全局。登记信息写进
`~/agent-settings/projects/<name>.yaml`（文件名由项目路径派生，随 agent-settings git 同步），
换机器后一键恢复。

```bash
cd ~/Projects/foo

# 在当前项目登记 skill（默认 scope=当前目录，写入项目清单）
asmgr add paper-writing-mentor -a claude-code codex

# 登记 subagent：把中央 agents/ 下的条目链到 .claude/agents
#   -s 固定走 claude-code、忽略 -a；写入清单的 subagents 段
asmgr add paper-writing-mentor -s

# 已有链接但还没清单？反向扫描当前目录生成清单
asmgr sync --from-agents

# 查看 / 检查当前项目
asmgr list
asmgr status --fix

# 移除项目里的某 skill / subagent
asmgr remove paper-writing-mentor -a claude-code codex
asmgr remove paper-writing-mentor -s
```

subagent 说明：
- `-s` 只链接**已存在**于中央 `agents/` 的条目（目录或 `.md`），不会像 skill 那样下载/复制到中央目录。
- 项目 scope 会写入清单 `subagents` 段，可被 `sync --from-config` 恢复；但**全局 `-g -s` 不写配置记录**，
  故不在跨机恢复范围内（属每台机器装一次的本地动作）。

**跨机器恢复（局域）**：在新机器 `git pull` agent-settings 后，`cd` 到登记时所在的项目目录，只恢复这个项目、不碰其它：

```bash
cd ~/Projects/foo
asmgr sync --from-config        # 默认 scope=当前目录，按清单重建本项目的链接（含项目 subagent）
asmgr status                    # 顺手检查链接是否齐了
```

`--from-config` 不带 scope 时只认当前目录的项目清单。

### list — 列出

```bash
asmgr list          # 当前目录项目
asmgr list -g       # 全局
asmgr list --all    # 全局 + 所有项目
```

全局列表示例：

```
已注册的 Skills:
================

  skill-creator
    来源: https://github.com/anthropics/skills/tree/main/skills/skill-creator
    全局安装:
      链接 (link):
        ✓ cursor (symlink)
        ✓ claude-code (symlink)

  code-simplifier
    来源: local:/Users/me/my-skills/code-simplifier
    全局安装:
      复制 (copy):
        ✓ codex (copy)
```

### status — 检查一致性

```bash
asmgr status          # 仅检查（当前项目）
asmgr status --fix    # 检查并自动修复
asmgr status -g       # 检查全局
```

检测四种状态：
- **OK**: 配置有、链接/副本存在且正确
- **MISSING**: 配置有、链接/副本不存在
- **ORPHAN**: 配置无、却存在指向中央目录的链接/副本
- **WRONG**: 安装方式不符或链接目标错误

### sync — 双向同步

```bash
# 反向：从现有安装状态重建配置（首次使用或迁移）
asmgr sync --from-agents [-g]

# 正向：从配置创建链接/副本（新机器部署）
asmgr sync --from-config [-g | --all]
```

**使用场景：**
1. **首次使用**：已有安装但没有配置，`sync --from-agents` 扫描并生成配置。
2. **新机器部署**：clone agent-settings 后，`sync --from-config --all` 自动重建全局 + 所有项目的链接/副本。

全局 `sync --from-agents -g` 只让 `agents_link` / `agents_copy` 跟随当前全局安装状态，不覆盖已有 `source` / `added_at` 元数据。

### remove — 移除

**完全移除**（删除中央目录 + 所有全局安装 + `skills.yaml` 整块记录，执行前确认）：

```bash
asmgr remove skill-creator
```

**部分移除**（仅从指定 scope 解链/删目录，保留中央目录）：

```bash
asmgr remove skill-creator -a cursor -g                 # 从全局 cursor 移除
asmgr remove skill-creator -a cursor -p ~/projects/foo  # 从指定项目移除
asmgr remove skill-creator -a cursor                    # 从当前目录项目移除
asmgr remove paper-writing-mentor -s                    # 移除 subagent 链接 + 更新清单
```

Skill remove 按中央目录或目标 agent 安装目录中的已存在名称精确匹配，不接收路径；补全带出的尾斜杠需要删掉。

全局部分移除清空最后一个 agent 后，会在 `skills.yaml` 保留该 skill 记录及其 `source` / `added_at`；只有 `asmgr remove <skill>` 完全移除会删除记录。

### Claude Code plugin / marketplace

Claude Code 的 marketplace 仓库体量大（每个是一个 git repo），不适合直接嵌进 agent-settings。asmgr 的做法是：
**plugin/marketplace 本身用官方 `claude plugin` CLI 安装/卸载，asmgr 只把“装过哪些”声明式记录到 `skills.yaml`**，
通过**全局 scope 的 sync**（`-g` / `--all`）双向搬运。当前目录 / `-p` 项目级 sync 不涉及 plugin。

**前置要求**：本机已安装 Claude Code（`claude` CLI 可用）。

```bash
# 1) 用官方 CLI 安装
claude plugin marketplace add openai/codex-plugin-cc
claude plugin install codex@openai-codex

# 2) 把当前状态写进 yaml（全局 scope 才会带上 plugin）
asmgr sync --from-agents -g

# 3) 新机器 clone agent-settings 后恢复
asmgr sync --from-config -g       # 或 --all
```

`sync --from-agents -g` 会读 `~/.claude/plugins/known_marketplaces.json` 与 `claude plugin list`，把信息合并写入
`skills.yaml` 的 `claude_code` 段；`sync --from-config -g/--all` 则调用 `claude plugin marketplace add` +
`claude plugin install` 重建声明过的条目（已存在的标 `[skip]`，幂等）。未装 `claude` CLI 时打印 warning 并跳过，
不影响 skills 部署。

> 注意：
> - `claude plugin list` 文本输出不带 scope，导入时 plugin 默认记为 `scope: user`，如需 `project`/`local` 请手工编辑 yaml。
> - marketplace 名以 `known_marketplaces.json` 的实际 key 为准，可能与传入的 repo 名不同（`openai/codex-plugin-cc` → `openai-codex`）。
> - 合并模式：`sync --from-agents` 不删除 yaml 里 claude 未启用的条目，清理请直接编辑 `skills.yaml`。

## 配置与目录布局

### skills.yaml（全局注册表）

位于 `~/agent-settings/skills/skills.yaml`，记录全局安装：

```yaml
skills:
  skill-creator:
    agents_link: [claude-code, cursor]   # 以符号链接安装的 agents
    agents_copy: [codex]                  # 以复制安装的 agents
    source: https://github.com/anthropics/skills/tree/main/skills/skill-creator
    added_at: "2026-02-03T23:22:36+08:00" # 本地时区，最近一次 add 的时间

  paper-writing-mentor:
    agents_link: []
    agents_copy: []
    source: https://github.com/example/skills/tree/main/paper-writing-mentor
    added_at: "2026-02-03T23:22:36+08:00"
```

`agents_link: []` / `agents_copy: []` 是合法状态，表示该 skill 已注册但当前没有全局安装，`source` 仍可用于后续恢复或重新安装。

当全局 `sync --from-agents -g` 在 `claude` CLI 可用时导入 plugin/marketplace，会新增 `claude_code` 段
（是否带 plugin 数据看该段是否存在）：

```yaml
claude_code:
  marketplaces:
    codex-plugin-cc:
      source: openai/codex-plugin-cc      # 原样传给 `claude plugin marketplace add`
      added_at: "2026-04-16T17:00:00+08:00"
  plugins:
    - name: openai-codex
      marketplace: codex-plugin-cc
      scope: user                         # user | project | local
      added_at: "2026-04-16T17:01:00+08:00"
```

### 项目清单（project manifest）

每个登记过的项目在 `~/agent-settings/projects/<name>.yaml` 有一份清单，结构对齐 `skills.yaml`，
去掉 `source`/`added_at`，加 `subagents` 段与权威定位字段 `path`：

```yaml
path: Projects/foo          # $HOME 内存相对路径；$HOME 外存绝对路径（以 / 开头）
skills:
  paper-writing-mentor:
    agents_link: [claude-code, codex]
    agents_copy: []
subagents:
  paper-writing-mentor:     # 中央 agents/ 下的目录或 .md
    agents_link: [claude-code]
    agents_copy: []
```

文件名由 `path` 派生（`/` → `__`），定位只看 `path` 字段。

### 路径识别规则

```
用户输入 source
    ├─ 是 GitHub URL? ──是──→ 从 GitHub 下载
    └─ 否
        ├─ 以 /、./、../ 开头? ──是──→ 从本地路径复制
        └─ 否 ──→ 搜索中央目录
```

**注意**：输入 `my-skill`（无前缀）会搜索中央目录，即使当前目录有同名文件夹；要用当前目录的文件夹须写 `./my-skill`。

## 源代码架构

入口脚本 `asmgr.sh` 解析 symlink 定位自身目录，按序 `source` 六个 `lib/*.sh` 后分发命令。整体分三层：

```
                      ┌──────────────────────────────────────┐
   编排层              │ asmgr.sh — 依赖检查 / 命令分发 / help   │
                      │            全局 skill 的 status & sync│
                      └──────────────────────────────────────┘
                                        │ 调用
   能力层   materialize │ yaml │ project │ sources │ plugin
                                        │ 依赖
   地基层               └──────────  core.sh  ──────────┘
```

| 文件 | 职责 |
|------|------|
| `asmgr.sh` | 入口：依赖检查、按序 source 各 lib、`show_help`、命令分发，以及**全局** skill 的 status/sync 实现 |
| `lib/core.sh` | 地基：共享常量、`get_agent_dir` / `normalize_base_dir` / `resolve_base_dir` 路径解析、打印与确认工具、`check_dependencies` |
| `lib/materialize.sh` | 底层原语：建链 `mat_deploy_link`、建副本 `mat_deploy_copy`、扫描 `mat_scan_central_links`、状态判定 `mat_classify`（全局与项目两条路径共用） |
| `lib/yaml.sh` | 读写全局 `skills.yaml`（skill 注册表的增删改查） |
| `lib/project.sh` | 项目局域清单（`projects/*.yaml`）的 CRUD、项目级部署/扫描/状态、subagent 链接 |
| `lib/sources.sh` | skill 来源获取（GitHub 下载 / 本地复制 / 中央搜索）并安装到 agent 目录 |
| `lib/plugin.sh` | Claude Code plugin/marketplace 与 `skills.yaml` 的 `claude_code` 段互转（仅全局 scope 触发） |

**core.sh 的共享常量**：`SKILLS_DIR`（`~/agent-settings/skills`）、`SKILLS_YAML`、`AGENTS_DIR`（中央 subagents）、
`PROJECTS_DIR`（项目清单目录）、`SUPPORTED_AGENTS`（`cursor claude-code codex gemini opencode pi omp`）。
（`CLAUDE_PLUGINS_DIR` 属 plugin 相关，定义在 `lib/plugin.sh`。）

**scope 决定数据落点**——这是理解架构的关键：

- **全局 `-g`** → 操作 `$HOME`、读写 `skills.yaml`（`yaml.sh`），并**带上 plugin/marketplace**（`plugin.sh`）。
- **项目 `-p` / cwd** → 操作项目目录、读写 `projects/<name>.yaml`（`project.sh`），**不碰 plugin**。
- **`--all`** → 全局 + 所有已登记项目。

无论哪条路径，最终的“建链 / 建副本 / 扫描 / 判定状态”都收敛到 `materialize.sh` 的 `mat_*` 原语，
因此全局与项目的落盘行为一致。

### Smoke Test

内置一键回归脚本，使用临时 `HOME` 与临时 skill 名，不污染真实配置，并自动应答确认提示：

```bash
asmgr/smoke_test.sh
```

## 依赖要求

- `git`（GitHub 下载）
- `bash` 4.0+
- `yq`（必需，YAML 处理）— https://github.com/mikefarah/yq ；macOS `brew install yq`
- `jq`（必需；实际只被 plugin/marketplace 子命令用到，但启动时与 yq/git 一同强制检查）— macOS `brew install jq`，Linux `apt-get install jq`
- `claude` CLI（仅 plugin/marketplace 子命令需要）— https://docs.claude.com/en/docs/claude-code
- 标准 Unix 工具：`cp`、`ln`、`mkdir`、`basename`

asmgr 启动时强制检查 git/yq/jq，缺任一则打印安装指引并拒绝运行。

## 常见问题

**Skill 已存在？** 提示确认是否覆盖（`y/N`）。

**Agent 目录不存在？** `add` 跳过该 agent 并警告；`sync --from-config` 会自动创建目录。

**怎么验证安装状态？** `asmgr list` 看清单，`asmgr status` 查一致性（加 `-g`/`--all` 切换 scope）。

## 相关链接

- [Anthropic Skills 仓库](https://github.com/anthropics/skills)
- [Skill Creator 文档](https://github.com/anthropics/skills/tree/main/skills/skill-creator)

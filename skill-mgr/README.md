# skill-mgr

AI Agent Skills 管理工具，支持从 GitHub 或本地路径添加 skills 到中央仓库，并管理到各 AI agent 的符号链接或复制。

## 功能特性

- **GitHub 集成**: 使用 git sparse-checkout 高效下载远程 skills
- **本地导入**: 支持从本地路径复制 skills
- **符号链接管理**: 自动创建符号链接到指定 agents
- **复制模式**: 支持复制整个目录（适用于不支持符号链接的 agents）
- **本地/全局安装**: 支持项目级（本地）和系统级（全局）安装模式
- **配置文件**: 使用 `skills.yaml` 记录全局安装到各 agents 的状态（link/copy）
- **一致性检查**: 检测配置与实际符号链接的差异并自动修复
- **双向同步**: 支持从全局符号链接/复制目录重建配置，或从配置部署全局链接

## 安装

```bash
# 克隆或更新 linuxtools 仓库
cd ~/Projects/linuxtools

# 创建符号链接到 ~/bin
mkdir -p ~/bin
ln -sf $(pwd)/skill-mgr/skill_mgr.sh ~/bin/skill-mgr

# 确保 ~/bin 在 PATH 中
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# 必须安装 yq（YAML 处理工具）
brew install yq
```

## 命令概览

| 命令 | 功能 |
|------|------|
| `skill-mgr add <source> [-a <agents>] [-g\|-p <dir>] [-c]` | 添加 skill 到中央目录并可选链接到 agents |
| `skill-mgr list` | 列出所有已注册的 skills 及其安装状态 |
| `skill-mgr status [--fix]` | 检查配置与符号链接的一致性 |
| `skill-mgr sync --from-agents` | 从现有 agents 安装状态（link/copy）重建配置文件 |
| `skill-mgr sync --from-config` | 从配置文件创建符号链接（用于新电脑部署） |
| `skill-mgr remove <skill> [-a <agents>] [-g\|-p <dir>]` | 移除 skill（完全移除或从指定位置移除） |

## 使用方法

### 安装模式

skill-mgr 支持两种安装模式：

#### 本地安装（默认）

- 安装到项目目录的 agent 目录：`./.cursor/skills/`, `./.claude/skills/`, `./.codex/skills/`
- 项目特定，与项目代码一起管理
- 适合项目专用的 skills
- 可以通过 `-p` 参数指定项目根目录

```bash
# 安装到当前目录（默认）
skill-mgr add ./my-skill -a cursor
# 创建 ./.cursor/skills/my-skill

# 安装到指定项目目录
skill-mgr add ./my-skill -a cursor -p ~/projects/foo
# 创建 ~/projects/foo/.cursor/skills/my-skill
```

#### 全局安装（`-g` 参数）

- 安装到家目录的 agent 目录：`~/.cursor/skills/`, `~/.claude/skills/`, `~/.codex/skills/`
- 系统范围可用，所有项目共享
- 适合通用的、常用的 skills

```bash
# 全局安装
skill-mgr add ./my-skill -a cursor -g
# 创建 ~/.cursor/skills/my-skill
```

**目录结构一致性**：无论全局还是本地，都使用相同的目录结构（`.cursor/skills/`），这样 agents 可以识别并加载 skills。

**注意**：`skills.yaml` 仅记录全局安装（`-g`）到各 agents 的状态，本地安装不会写入配置。

### 复制模式 (`-c`)

某些 AI Agent 不支持符号链接，可以使用 `-c` 参数启用复制模式：

```bash
# 符号链接模式（默认）
skill-mgr add ./my-skill -a cursor -g
# 创建符号链接: ~/.cursor/skills/my-skill -> ~/agent-settings/skills/my-skill

# 复制模式
skill-mgr add ./my-skill -a codex -g -c
# 复制目录到: ~/.codex/skills/my-skill
```

**注意事项：**
- 复制模式会占用更多磁盘空间（每个安装位置都有完整副本）
- 更新 skill 后需要重新安装才能同步到复制的位置
- 符号链接模式下，更新中央目录会自动同步到所有链接位置
- 删除复制的目录时会要求确认

### add - 添加 Skill

```bash
skill-mgr add <source> [-a <agents...>] [-g|-p <dir>] [-c]
```

**source 支持三种格式：**

| 格式 | 示例 | 说明 |
|------|------|------|
| GitHub URL | `https://github.com/anthropics/skills/tree/main/skills/skill-creator` | 从 GitHub 下载 |
| 本地路径 | `/path/to/skill`, `./skill`, `../skill` | 从本地复制（必须以 `/`, `./`, `../` 开头） |
| Skill 名称 | `skill-creator`, `creator` | 搜索中央目录（支持模糊匹配） |

**agents 支持：** `cursor`, `claude-code`, `codex`

**安装模式参数：**

| 参数 | 说明 |
|------|------|
| `-a <agents...>` | 指定要安装的 agents |
| `-g, --global` | 全局安装（安装到家目录） |
| `-p, --project <dir>` | 指定项目根目录（本地安装），默认为当前目录 |
| `-c, --copy` | 复制模式（复制目录而非符号链接） |
| 无参数 | 默认为本地安装（当前目录） |

**示例：**

```bash
# 本地安装（默认）- 安装到当前目录
skill-mgr add ./my-skill -a cursor
# 创建 ./.cursor/skills/my-skill (符号链接)

# 全局安装 - 安装到家目录
skill-mgr add ./my-skill -a cursor -g
# 创建 ~/.cursor/skills/my-skill (符号链接)

# 复制模式安装（适用于不支持符号链接的 agent）
skill-mgr add ./my-skill -a codex -g -c
# 复制到 ~/.codex/skills/my-skill (实际目录)

# 混合使用：cursor 用符号链接，codex 用复制
skill-mgr add ./my-skill -a cursor -g        # symlink
skill-mgr add ./my-skill -a codex -g -c      # copy

# 本地安装到指定项目
skill-mgr add ./my-skill -a cursor -p ~/projects/foo
# 创建 ~/projects/foo/.cursor/skills/my-skill

# 多个 agents（全局安装）
skill-mgr add skill-creator -a cursor claude-code -g

# 从 GitHub 添加（本地安装）
skill-mgr add https://github.com/anthropics/skills/tree/main/skills/skill-creator -a cursor

# 从 GitHub 添加（全局安装）
skill-mgr add https://github.com/anthropics/skills/tree/main/skills/pdf-editor -a cursor claude-code codex -g

# 从本地路径添加（全局）
skill-mgr add /path/to/my-skill -a cursor -g

# 使用 skill 名称（搜索中央目录）
skill-mgr add skill-creator -a claude-code
skill-mgr add creator -a cursor    # 模糊搜索
```

说明：
- 不传 `-a` 时只会下载到中央目录，不会写入 `skills.yaml`。
- `skills.yaml` 只记录全局安装到各 agents 的信息（link/copy）。
- `-g` 和 `-p` 参数不能同时使用。

### list - 列出 Skills

```bash
skill-mgr list
```

显示所有已注册的 skills 及其全局安装状态（link/copy）：

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
      链接 (link):
        ✓ cursor (symlink)
      复制 (copy):
        ✓ codex (copy)
```

### status - 检查一致性

```bash
skill-mgr status         # 仅检查
skill-mgr status --fix   # 检查并自动修复
```

检测四种状态（仅全局安装记录）：
- **OK**: 配置有、符号链接/复制目录存在
- **MISSING**: 配置有、符号链接/复制目录不存在
- **ORPHAN**: 配置无、符号链接/复制目录存在
- **WRONG**: 安装方式不符或链接目标错误

### Smoke Test - 快速回归

项目内置了一键 smoke test 脚本，使用临时 `HOME` 和临时 skill 名称，不会污染真实配置，并自动处理确认提示：

```bash
skill-mgr/smoke_test.sh
```

### sync - 同步配置

```bash
# 从全局符号链接/复制目录重建配置（首次使用或迁移）
skill-mgr sync --from-agents

# 从配置创建全局符号链接/复制目录（新电脑部署）
skill-mgr sync --from-config
```

**使用场景：**

1. **首次使用**: 已有全局安装但没有配置文件，运行 `sync --from-agents` 生成配置
2. **新电脑部署**: clone agent-settings 仓库后，运行 `sync --from-config` 自动创建全局链接/复制目录

### remove - 移除 Skill

#### 完全移除（删除中央目录 + 全局安装 + 配置记录）

```bash
skill-mgr remove <skill>
```

完全移除 skill，包括：
- 删除中央目录 `~/agent-settings/skills/<skill>`
- 删除所有全局安装（link/copy）
- 从 `skills.yaml` 移除记录

说明：
- 本地安装不记录在 `skills.yaml`，如需删除请使用 `-p` 指定项目目录。

示例：
```bash
skill-mgr remove skill-creator
```

执行前会显示确认提示，输入 `y` 确认移除。

#### 部分移除（仅从指定位置移除）

```bash
skill-mgr remove <skill> -a <agents...> [-g|-p <dir>]
```

仅从指定位置移除 skill（删除符号链接/目录，必要时更新配置），保留中央目录：

**参数说明：**

| 参数 | 说明 |
|------|------|
| `-a <agents...>` | 指定要移除的 agents |
| `-g, --global` | 从全局安装移除 |
| `-p, --project <dir>` | 从指定项目移除 |
| 无 `-g/-p` | 从当前目录移除（默认） |

**示例：**

```bash
# 从全局安装移除
skill-mgr remove skill-creator -a cursor -g

# 从指定项目移除
skill-mgr remove skill-creator -a cursor -p ~/projects/foo

# 从当前目录移除
skill-mgr remove skill-creator -a cursor

# 从多个 agents 移除（全局）
skill-mgr remove skill-creator -a cursor claude-code -g
```

## 配置文件

配置文件位于 `~/agent-settings/skills/skills.yaml`：

```yaml
# Skill installation registry
# Auto-managed by skill-mgr, can be manually edited

version: 1

skills:
  skill-creator:
    agents_link:
      - claude-code
      - cursor
    agents_copy:
      - codex
    source: https://github.com/anthropics/skills/tree/main/skills/skill-creator
    added_at: "2026-02-03T23:22:36+08:00"  # 本地时区，最近一次 add 的时间

  code-simplifier:
    agents_link:
      - claude-code
    agents_copy:
      - codex
    source: local:/Users/me/my-skills/code-simplifier
    added_at: "2026-02-03T23:22:36+08:00"  # 本地时区，最近一次 add 的时间
```

**字段说明：**
- `agents_link`: 全局 link 安装的 agents 列表
- `agents_copy`: 全局 copy 安装的 agents 列表
- `source`: skill 来源
- `added_at`: 记录时间（本地时区）

## 目录结构

### 中央存储

所有 skills 统一存储在:

```
~/agent-settings/skills/
├── skills.yaml              # 配置文件
├── skill-creator/
│   ├── SKILL.md
│   └── ...
├── code-simplifier/
│   └── ...
└── ...
```

### Agent 目录映射

#### 全局安装（`-g`）

| Agent | Skills 目录 |
|-------|-------------|
| cursor | `~/.cursor/skills/` |
| claude-code | `~/.claude/skills/` |
| codex | `~/.codex/skills/` |

符号链接示例:

```
~/.cursor/skills/skill-creator → ~/agent-settings/skills/skill-creator
~/.claude/skills/skill-creator → ~/agent-settings/skills/skill-creator
```

#### 本地安装（默认或 `-p`）

| Agent | Skills 目录 |
|-------|-------------|
| cursor | `<project>/.cursor/skills/` |
| claude-code | `<project>/.claude/skills/` |
| codex | `<project>/.codex/skills/` |

符号链接示例（假设项目在 `/Users/me/projects/foo`）:

```
/Users/me/projects/foo/.cursor/skills/skill-creator → ~/agent-settings/skills/skill-creator
/Users/me/projects/foo/.claude/skills/skill-creator → ~/agent-settings/skills/skill-creator
```

**目录结构一致性**：无论全局还是本地，都使用相同的目录结构（`.cursor/skills/`, `.claude/skills/`, `.codex/skills/`），这样 agents 可以识别并加载 skills。

## 路径识别规则

```
用户输入 source
    │
    ├─ 是 GitHub URL? ──是──→ 从 GitHub 下载
    │
    └─ 否
        │
        ├─ 以 /, ./, ../ 开头? ──是──→ 从本地路径复制
        │
        └─ 否 ──→ 搜索中央目录
```

**注意**: 如果当前目录有 `my-skill` 文件夹，输入 `my-skill` 会搜索中央目录。要使用当前目录的文件夹，必须输入 `./my-skill`。

## 依赖要求

- `git` (用于 GitHub 下载)
- `bash` 4.0+
- `yq` (必需，用于 YAML 处理)
  - 官方仓库: https://github.com/mikefarah/yq
  - macOS 安装: `brew install yq`
  - Linux 安装: 参见 https://github.com/mikefarah/yq#install
- 标准 Unix 工具: `cp`, `ln`, `mkdir`, `basename`

**注意**: skill-mgr 启动时会自动检查 yq 是否已安装，如未安装会显示安装指引。

## 常见问题

### Skill 已存在如何处理？

工具会提示确认是否覆盖:

```
[WARN] Skill 已存在: ~/agent-settings/skills/skill-creator
是否覆盖? (y/N)
```

### Agent 目录不存在怎么办？

- `add` 命令会跳过该 agent 并显示警告
- `sync --from-config` 会自动创建 agent 目录

### 如何验证安装状态？

```bash
# 查看所有 skills 状态
skill-mgr list

# 检查一致性
skill-mgr status
```

## 相关链接

- [Anthropic Skills 仓库](https://github.com/anthropics/skills)
- [Skill Creator 文档](https://github.com/anthropics/skills/tree/main/skills/skill-creator)

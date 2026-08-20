# Task 0 真探针触发步骤（Step 7）— Claude Code 2.1.226

- **日期**：2026-08-09（UTC+8）
- **运行时版本（动态捕获）**：`claude --version` → `2.1.226 (Claude Code)`（未硬编码，manifest.json 同步记录原始输出）
- **探针 sink**：`../probe_hook.py`（field-name-only：只输出 key path/结构/字段名哈希；stdout/stderr 保持空；值零落盘）
- **探针会话标识**：环境变量 `VOICECODING_TEST=1`（evidence 行内 `probe_env` 字段分离）

## 探针前基线与备份

| 项 | 值 |
|---|---|
| `~/.claude/settings.json` 基线 SHA-256 | `ff7836cf1dd0b41890c5113d6adbd58c7f78f841a1951c90ae0315b03b5712e2`（探针前复核一致） |
| settings 备份 | `/tmp/attention-task0-settings-backup-20260809-100835.json`（含生产 token，不入仓，探针后保留至收尾删除） |
| shadow-log 备份 | `~/.voice-coding/shadow-log.jsonl.bak-20260809-100835`（624KB） |
| shadow-log 水位 | 探针前 3711 行 |
| app 状态 | 未运行（端口 47821 空闲，`~/.voice-coding/events.db` 不存在）→ 按裁决只需清 shadow-log 残留 |

## settings.json 探针组追加

- 方式：python json load → 每事件数组 APPEND 独立 matcher 组 → 写回；**生产组零改动**（校验：Stop 组=2，组0=生产 deliver，组1=探针；PreCompact printf 未动）。
- 追加事件（22 个）：见 `settings-appended.json`（占位模板见 `../probe-settings-fragment.json`）。
- 命令形态：`/usr/bin/python3 <abs probe_hook.py> <abs 本目录>`——stdin 直通，无 shell 变量持有 payload、无命令替换。

## 受控探针会话

一次性目录：`/tmp/attention-task0-probe-session-20260809-101341`（含人工 fixture 文件 `probe-fixture.txt`，内容一行人工文本；探针后已删除）。

| 会话 | session_id | 受控 prompt（人工值，全文） | 参数 | 结果 |
|---|---|---|---|---|
| A | `302e2d32-ea25-43ec-97b6-051c94e6ab16` | "Use the Bash tool to run this command exactly once: echo probe-ok-a. Then reply with exactly one word: done" | `--allowedTools Bash --output-format json` | 成功，2 turns，Bash 执行 |
| B | `067102bb-af0b-4eca-9a91-aba150ac6332` | 同上（probe-ok-b） | 无 allowlist（探权限路径）+ `--output-format json` | 成功，2 turns |

## 观察结果（三档）

- **受控 observed（7）**：SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / PostToolBatch / Stop / SessionEnd（A/B 各一次，字段清单见 `field-lists.json`，source=controlled）
- **附带观察 observed（5，未受控触发）**：Notification / PermissionRequest / ConfigChange / CwdChanged / TaskCompleted——探针窗口内并发非探针会话（含执行本任务的会话）触发；sink 保证 field-name-only，evidence 无值；受控复现留后续
- **unverified（16）**：StopFailure / PostToolUseFailure / TaskCreated / SubagentStart / SubagentStop / TeammateIdle / WorktreeCreate / WorktreeRemove / DirectoryAdded / FileChanged / Notification 四子类（值域）/ httpHookHandler / asyncCommandHook（机制面未做机制探针）
- **附加观察**：1 条 `body_too_large` fail-closed 错误行（并发会话 >1MiB hook payload，探针上限实战生效；错误行只含 error_code，无内容）

## 关键实测纠正

**Notification 子类 wire 字段名为 `notification_type`**（非 spec §8.10 调研推测的 `subtype`）——field-lists.json#/events/Notification 字段清单实证。四值值域本轮未实测（field-name-only 纪律不采值），Notification 四子类 kind 保持 unverified。

## 探针后恢复与清理核验

| 项 | 结果 |
|---|---|
| settings.json 恢复 | 自备份整体恢复；SHA-256 复核 == 基线 `ff7836cf…12e2` ✓ |
| shadow-log 清理 | 按探针 session_id 精确过滤：移除 8 行（A/B 各 4 行），清理后 grep 两 session_id 命中 0 ✓ |
| events.db | 不存在（app 全程未运行）✓ |
| /tmp 探针产物 | 会话结果文件与一次性目录已删除 |

## 隐私核验

- evidence 全部文件：key path / 结构类型 / 字段名哈希 / 事件名 / 哈希——无任何 value（sink 设计保证 + Step 9 sentinel 扫描）
- 探针会话 prompt 为人工受控值（上文全文引用），无真实用户内容
- session_id 仅用于清理核验（§8.8 允许采集的标识面），非内容

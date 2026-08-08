# M1 影子对照三日执行报告

## 结论

**PASS：连续 3 个真实工作日零 `real_miss`、零 `real_false_positive`。**

本报告只证明 M1 A-only 收件箱在本次冻结版本和已标注口径下，映射类 hook 的投递与入库未观察到真实漏捕或误报。它不改变 Hook 的 `experimental_fragile` 来源等级，不关闭 EG-1/EG-2，也不扩展到 M1.0-B 完整状态总览。

## 执行口径

- 观察窗口：2026-08-05、2026-08-06、2026-08-07 三个 UTC 工作日窗口。
- ground truth：`~/.voice-coding/shadow-log.jsonl`，由 hook 投递脚本独立双写。
- 对照对象：VoiceInk 事件库逐日 `export.csv`。
- 机械结果：`matched` / `missed` / `false_positive` / `malformed`。
- 人工裁决：按 `evidence/voice-coding/m1/shadow-protocol.md`；PreToolUse 非 `permission_requested` 按 2026-08-05 预裁决记为 `by_design`，不是 real 分歧。
- 通过条件：连续三日的所有机械分歧均为允许的非 real 类，且零 `real_miss`、零 `real_false_positive`。

## 三日统计

| UTC 日窗 | export | shadow | matched | missed | false_positive | malformed | 分歧裁决 | verdict |
|---|---:|---:|---:|---:|---:|---:|---|---|
| 2026-08-05 | 219 | 1028 | 219 | 809 | 0 | 0 | 809 条均为 PreToolUse `by_design` | PASS |
| 2026-08-06 | 247 | 1402 | 247 | 1155 | 0 | 0 | 1155 条均为 PreToolUse `by_design` | PASS |
| 2026-08-07 | 85 | 447 | 85 | 362 | 0 | 0 | 362 条均为 PreToolUse `by_design` | PASS |
| **合计** | **551** | **2877** | **551** | **2326** | **0** | **0** | **2326 条全为 `by_design`；real 分歧 0** | **PASS** |

守恒核验：

- export 侧：`matched 551 + false_positive 0 = export 551`；
- shadow 侧：`matched 551 + missed 2326 = shadow 2877`；
- 三日逐类核验均显示 Notification、Stop、SessionStart、SessionEnd、StopFailure 的 matched 数与 shadow 数逐型精确一致，即映射类 hook 零丢失。

## 逐日归因

### 2026-08-05

- `missed=809`：100% 为 PreToolUse 非 permission，按 A-only adapter 设计不入 store，组标注为 `by_design`；
- `false_positive=0`；
- 当日有三次预先记录的 app 运维重启，但映射类 hook 逐型仍与 shadow 精确一致，未观察到真实漏投递。

### 2026-08-06

- `missed=1155`：100% 为同模式 PreToolUse `by_design`；
- `false_positive=0`；
- app PID 88019 全日未重启，无运维归因项。

### 2026-08-07

- `missed=362`：100% 为同模式 PreToolUse `by_design`；
- `false_positive=0`；
- app PID 88019 全日未重启，无运维归因项。

## 证据 SHA-256

| 日窗 | export.csv | compare-report | annotations.md |
|---|---|---|---|
| 2026-08-05 | `ad2ef2ba3c9bb96659952c38a94d7a6883ea1a2dccf28da1345144c48b8fffbd` | `44c997ade8108f48d084dcbf57f5b038533a28752f802fd5e6fe4292531f5dcd` | `226bf87521890c23612db6e0335598d9563493154ead8b68b1def92902f6f806` |
| 2026-08-06 | `c05b564d552a6f9b41846489db4ef2dc33b0dda36fd3420a272bb4e4798f447e` | `94007dbcb4a3240542c2286a4d25e77468afcf1bed42fdd4f05a78063cd4ab58` | `3539d5c4473c26770ee671dfae1ffc097630a8b3ad1aa2a60c5a25e627d05a99` |
| 2026-08-07 | `ee0de1909bd73d0860301cb541bada124e8ca3c44068fb995cf8e2f38bd84fa0` | `61c7235f10a8f5eb5f33b1fe8b22b344b5045ded7d201a73a947826207ac48af` | `abb3c5fb1613cd10f28f67c882c2c056ce45ebfe107c2616af78f0070dec7f65` |

证据文件位于本目录的三个日期子目录；逐日 `annotations.md` 包含组标注、逐类计数、守恒核验和判定。

## 剩余边界

1. Hook 来源仍为 `experimental_fragile`；Claude Code 版本升级时必须按 ADJ-4 重验。
2. PreToolUse 非 permission 的 `by_design` 排除是 A-only 范围，不代表完整权限状态覆盖。
3. `source_claude_version` 当前路由默认值仍固定为 `2.1.220`，是 final review 已登记 known hole；不影响本次同一冻结实现的三日对照，但会影响未来版本漂移归因可信度。
4. I2-I5（测试隔离、SessionEnd 收尾、staleness、状态词汇）按已批准时序交由悬浮灯条 redesign SDD 的 Lane A 处理；本观察期不修改被观察对象。

## 最终 verdict

**Task 21 PASS（3/3）。** 可进入 Task 22 收尾证据包与 EG-1 标记建议；是否调整 EG-1 必须由老林另行书面批准。

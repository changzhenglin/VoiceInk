# M1 收尾 verdict 与 EG-1 标记建议

## 结论

- **M1 A-only 收件箱验收 verdict：PASS。**
- **建议**：由老林书面批准后，将 `EG-1` 正式标记为 `ADJUST_LIMITED_CLOSED`。
- **保持**：`EG-2` 继续 `OPEN`；本证据包不证明 M1.0-B 完整状态总览，不解除 B 轨限制。
- **权限边界**：本文件只提出标记建议，不自行修改 EG-1/EG-2 状态。

## 证据链

### A 轨动态证据

- PR：AgentOS PR#101，merged commit `df55b92`。
- run：`72ac8882-6112-4caa-b0de-c383ae68d68c`。
- 固定证据目录：`AgentOS/evidence/voice-coding/m1/a/72ac8882-6112-4caa-b0de-c383ae68d68c/`。
- 结果：H-A1~H-A7 七硬门全部 PASS；封闭事件矩阵 60/60；开放轨 2.7h、144 事件、7 会话、零反例；Verifier 14/14；老林认可候选 verdict `ADJUST_LIMITED`。
- 上限：核心事件依赖 S-HOOK `experimental_fragile`，所以不能升级为 GO；版本变化必须重验。

### M1 实现与三日影子证据

- 实现范围：A-only 四类关键事件收件箱；默认关闭；不实现 working/idle/legitimate_wait 推断。
- Task 18：冻结清单 10 项 + 追加 A-E 真机验收通过；阶段② final whole-branch review 对 `fa3e2ef..c0f8cbf` 给出 PASS。
- Task 21：`evidence/voice-coding/m1/shadow-runs/shadow-report.md`。
  - 三日合计：export 551、shadow 2877、matched 551、missed 2326、false_positive 0、malformed 0；
  - 2326 条 missed 全为 PreToolUse 非 permission 的 `by_design` 设计排除；
  - Notification、Stop、SessionStart、SessionEnd、StopFailure 三日逐型均与 shadow 精确一致；
  - `real_miss=0`、`real_false_positive=0`，连续 3 日 PASS。

## ADJ-1~5 落点核对

| 约束 | 实现落点 | 验证证据 | 状态 |
|---|---|---|---|
| ADJ-1：拒绝 zero-UUID | `ClaudeCodeAdapter` 入口校验；`AttentionEventRouter` 返回 `E-IDENTITY` | `ClaudeCodeAdapterTests` zero-UUID 负向测试；`AttentionEventRouterTests` 路由拒绝 | 已落地 |
| ADJ-2：同 session_id 互斥 | `SessionMutex` 按 adapter 身份检测碰撞；SessionEnd 成功入库后释放 ownership | `SessionMutexTests` 跨 adapter 冲突；`SessionReleaseWiringTests` 生命周期接线 | 已落地 |
| ADJ-3：Hook 超时重试 | `VoiceInk/Resources/attention-hook-deliver.sh` 使用 `curl --retry 2 --max-time 5`，同进程重试复用 delivery_id | `ClaudeCodeAdapterTests` 与 `AttentionReplayTests` 验证重试幂等；Task 12 review 记录 | 已落地；接收侧用户可见明确错误码仍属既有非阻塞边界 |
| ADJ-4：版本升级重验 | HookInstaller 记录 installed version；`ClaudeVersionProbe` + `AttentionStore.versionDrift` + 设置/诊断页徽标与自检入口 | Task 13/14/16 报告 + Task 18 真机 drift A/B 验收 | 已落地；`source_claude_version` 路由默认值固定 2.1.220 为 known hole，未来版本重验前必须修正或显式 nullable |
| ADJ-5：Stop=单轮完成 | `ClaudeCodeAdapter` 将 Stop 映射为 completed；`AttentionReducer` 保持 lifecycle managed；仅 SessionEnd 关闭 | `ClaudeCodeAdapterTests`、`AttentionReducerTests`、`AttentionReplayTests` 连续轮次与乱序测试 | 已落地 |

## EG-1 建议的依据

冻结 spec 的关闭口径要求：

1. A 轨固定证据充分且 verdict 为 `ADJUST_LIMITED`；
2. ADJ-1~5 传递到生产 adapter；
3. M1 影子对照连续 3 个真实工作日通过；
4. 关闭动作由老林书面批准。

前三项均已有上述证据。因此本文件提出：

> **建议将 EG-1 标记为 `ADJUST_LIMITED_CLOSED`，但仅在老林书面批准后执行状态修改。**

`ADJUST_LIMITED_CLOSED` 的含义是：A 轨可行性门在限定范围内闭合，产品可以继续使用 A-only 关键事项收件箱；它不是 GO，不提升 Hook 来源等级，不证明完整状态总览，也不允许把 `experimental_fragile` 事件源描述成稳定公共 API。

## EG-2 保持 OPEN

M1.0-B 已裁决为 `INSUFFICIENT_EVIDENCE`，A-only 实现明确不支持 working/idle/legitimate_wait。三日影子对照只验证已映射的 A 轨关键事件，不提供 B 轨新增证据。因此：

> **EG-2 必须继续 OPEN。**

## 剩余风险与后续时序

1. `source_claude_version` 默认固定为 2.1.220；未来版本漂移归因前必须修正或改为可信探测值。
2. I2-I5（测试隔离、SessionEnd 收尾、异常终止 staleness、状态词汇缺口）不影响本次映射类零丢失结论，但影响收件箱数量与交互语义；按批准时序进入悬浮灯条 redesign SDD Lane A。
3. Hook、settings.json 和 AX 都是平台脆弱边界；继续保持默认关闭、可卸载、零通知、fail-closed 与版本重验。
4. 本文件不授权 push、PR、merge 或发布。

## 最终状态

| 项 | 状态 |
|---|---|
| Task 21 三日影子对照 | PASS（3/3） |
| M1 A-only 收件箱 | PASS（限定范围） |
| EG-1 | OPEN，**建议老林批准后改为 ADJUST_LIMITED_CLOSED** |
| EG-2 | OPEN（保持） |

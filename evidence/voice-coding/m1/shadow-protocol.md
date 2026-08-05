# M1 影子对照标注协议

## 每日流程（C7 fold：机械对比优先，人工标注只裁决分歧）
1. 工作日结束前，VoiceInk 诊断页点「导出当日时间线」→ shadow-runs/YYYY-MM-DD/export.csv
2. 诊断页点「影子对比」→ 自动机械对比 export.csv vs ~/.voice-coding/shadow-log.jsonl
   （ground truth = 投递脚本双写的独立日志，不依赖人回忆）
   → compare-report.csv：每条 matched / missed（shadow-log 有、导出无）/ false_positive（导出有、shadow-log 无）
3. 人工只处理分歧：对照 compare-report 中 missed/false_positive 条目逐条标注 verdict ∈
   {real_miss, real_false_positive, benign_dup, clock_skew, by_design} 并写 note（裁决责任，非回忆责任）
   - **by_design**（2026-08-05 老林裁决新增）：shadow 侧 hook 按 A-only 设计不入 store——
     仅 PreToolUse 非 permission_requested 类（adapter 只收 permission→waitingPermission，
     普通工具调用丢弃）。非 real 分歧。同模式条目允许**组标注**：一条标注覆盖 N 条同模式+note 记数

## 通过标准（spec §6）
- 连续 3 个工作日：机械对比零 missed 且零 false_positive（或全部标注为 benign_dup/clock_skew/by_design）= PASS
- 任一 real_miss/real_false_positive → 归因三选一：adapter bug / hook 语义漂移 / 对比口径
  → 修复后计数清零重新来

## 诚实性
- 判官 = 老林；标注件留档可复核
- 影子期 EG-1 保持 OPEN；PASS 后产出 EG-1 ADJUST_LIMITED_CLOSED 标记建议（不自行关闭）
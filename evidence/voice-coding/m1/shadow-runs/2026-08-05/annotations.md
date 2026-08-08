# day 1 影子对照标注（2026-08-05 UTC 窗口，2026-08-06 上午执行）

- 判官：老林（by_design 组标注规则 2026-08-05 预裁决，协议 commit eb441b6）
- 机械对比 SUMMARY：export=219; shadow=1028; matched=219; missed=809; false_positive=0; malformed=0
- 双侧守恒：matched+missed=1028=shadow ✓ / matched+fp=219=export ✓
- 产物 SHA-256：
  - export.csv `ad2ef2ba3c9bb96659952c38a94d7a6883ea1a2dccf28da1345144c48b8fffbd`
  - compare-report-2026-08-05.csv `44c997ade8108f48d084dcbf57f5b038533a28752f802fd5e6fe4292531f5dcd`（落点 AgentOS/test/）

## 组标注

| # | verdict | 条数 | 模式 | note |
|---|---|---|---|---|
| 1 | by_design | 809 | missed × PreToolUse（非 permission） | adapter 按 A-only 设计只收 permission_requested→waitingPermission，普通工具调用丢弃；非 real |

## 逐类核验

- matched 219 = Notification 148 / Stop 60 / SessionStart 5 / SessionEnd 5 / StopFailure 1 —— 与 shadow 侧映射类 hook 总数精确一致（映射类零丢失；含三次 app 重启窗口 12:18/15:03/15:41 本地时间，间隙无丢投递）
- false_positive = 0（08-05 无手动注入事件；测试残留已于 08-05 晚清理）
- real_miss = 0；real_false_positive = 0

## 判定

**day 1 PASS**（零 real 分歧；809 missed 全 by_design 非 real）

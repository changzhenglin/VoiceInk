# day 2 影子对照标注（2026-08-06 UTC 窗口，2026-08-07 上午执行）

- 判官：老林（by_design 组标注规则 2026-08-05 预裁决，协议 commit eb441b6）
- 机械对比 SUMMARY：export=247; shadow=1402; matched=247; missed=1155; false_positive=0; malformed=0
- 双侧守恒：matched+missed=1402=shadow ✓ / matched+fp=247=export ✓（shadow 1402 与对照前独立计数 shadow-log 08-06 UTC 窗条数精确一致）
- 产物 SHA-256：
  - export.csv `c05b564d552a6f9b41846489db4ef2dc33b0dda36fd3420a272bb4e4798f447e`
  - compare-report-2026-08-06.csv `94007dbcb4a3240542c2286a4d25e77468afcf1bed42fdd4f05a78063cd4ab58`（落点 AgentOS/test/）

## 组标注

| # | verdict | 条数 | 模式 | note |
|---|---|---|---|---|
| 1 | by_design | 1155 | missed × PreToolUse（非 permission） | adapter 按 A-only 设计只收 permission_requested→waitingPermission，普通工具调用丢弃；非 real（与 day 1 同模式，协议 eb441b6） |

## 逐类核验

- matched 247 = Notification 193 / Stop 43 / SessionStart 5 / SessionEnd 4 / StopFailure 2 —— 与 shadow 侧映射类 hook 总数逐型精确一致（映射类零丢失）
- 08-06 窗内 app 无重启（PID 88019 自 08-05 15:41 连续运行，无运维归因项）
- false_positive = 0（08-06 无手动注入事件；测试残留已于 08-05 晚清理）
- real_miss = 0；real_false_positive = 0

## 判定

**day 2 PASS**（零 real 分歧；1155 missed 全 by_design 非 real）；计数 2/3；next=08-08 上午对照 08-07（day 3）

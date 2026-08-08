# day 3 影子对照标注（2026-08-07 UTC 窗口，2026-08-08 执行）

- 判官：老林（by_design 组标注规则 2026-08-05 预裁决，协议 commit eb441b6）
- 机械对比 SUMMARY：export=85; shadow=447; matched=85; missed=362; false_positive=0; malformed=0
- 双侧守恒：matched+missed=447=shadow ✓ / matched+fp=85=export ✓（shadow 447 与对照后独立读取 shadow-log 的 08-07 UTC 窗条数精确一致）
- 产物 SHA-256：
  - export.csv `ee0de1909bd73d0860301cb541bada124e8ca3c44068fb995cf8e2f38bd84fa0`
  - compare-report-2026-08-07.csv `61c7235f10a8f5eb5f33b1fe8b22b344b5045ded7d201a73a947826207ac48af`（落点 AgentOS/test/）

## 组标注

| # | verdict | 条数 | 模式 | note |
|---|---|---|---|---|
| 1 | by_design | 362 | missed × PreToolUse（非 permission） | adapter 按 A-only 设计只收 permission_requested→waitingPermission，普通工具调用丢弃；非 real（与 day 1/day 2 同模式，协议 eb441b6） |

## 逐类核验

- matched 85 = Notification 66 / Stop 11 / SessionStart 3 / SessionEnd 3 / StopFailure 2 —— 与 shadow 侧映射类 hook 总数逐型精确一致（映射类零丢失）
- 08-07 窗内 app 无重启（PID 88019 自 08-05 15:41 持续运行，无运维归因项）
- false_positive = 0
- real_miss = 0；real_false_positive = 0

## 判定

**day 3 PASS**（零 real 分歧；362 missed 全 by_design 非 real）；连续计数 3/3；Task 21 三日观察期达到预注册通过条件，next=三日汇总 shadow-report.md → Task 22 证据包

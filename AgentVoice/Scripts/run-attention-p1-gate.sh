#!/bin/bash
# Task 14A-1（plan Step 9 框架）：P1 注意力 gate 脚本——顺序运行 unit/replay-shadow/
# 故障矩阵/manifest 结构，硬校验 manifest 诚实纪律；任一失败 exit 非 0。
#
# gate 语义（plan Step 9 逐字）：任一失败不得开启 P1 feature flag 或标
# validated_contract。14A-1 只交付包域段；14A-2（UITests/E2E/环境矩阵）与
# 14A-3（3 日观察）段为 placeholder，段内实现后在本脚本顺序追加。
#
# 用法：bash AgentVoice/Scripts/run-attention-p1-gate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$PACKAGE_DIR/Evidence/attention-p1-gate-manifest.json"

echo "=== [14A-1 gate] 段 1：包域测试（replay shadow + 故障矩阵 + manifest 结构）==="
swift test --package-path "$PACKAGE_DIR" \
  --filter ReplayShadowHarnessTests \
  --filter AttentionFailureMatrixTests \
  --filter GateManifestStructureTests

echo ""
echo "=== [14A-1 gate] 段 2：manifest 状态硬校验（诚实纪律）==="
python3 - "$MANIFEST" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    items = json.load(f)

errors = []
required_keys = {"id", "owner", "phase", "automated_or_manual",
                 "evidence_path", "status", "measurement", "threshold"}
allowed_status = {"PASS", "PENDING", "EVIDENCE_REQUIRED", "blocked_by_p2"}
expected_blocked = {"s9-10-gradient", "s9-11-keyboard", "s9-13-task0-capability-gate"}

if not isinstance(items, list):
    errors.append("manifest 顶层必须是对象数组")
    items = []
if len(items) != 13:
    errors.append(f"§9 判据必须恰 13 项（实际 {len(items)}）")

ids = set()
blocked_ids = set()
for item in items:
    iid = item.get("id", "<no-id>")
    missing = required_keys - set(item.keys())
    if missing:
        errors.append(f"{iid}: 缺键 {sorted(missing)}")
    ids.add(iid)
    status = item.get("status")
    if status not in allowed_status:
        errors.append(f"{iid}: 非法 status '{status}'（词表 {sorted(allowed_status)}）")
    # 诚实纪律硬门：PASS 必有非空 evidence_path（无证据不得 PASS）
    if status == "PASS" and not str(item.get("evidence_path", "")).strip():
        errors.append(f"{iid}: status=PASS 但 evidence_path 为空（违反诚实纪律硬门）")
    if status == "blocked_by_p2":
        blocked_ids.add(iid)

if len(ids) != len(items):
    errors.append("id 存在重复")
if blocked_ids != expected_blocked:
    errors.append(f"blocked_by_p2 集合不符：实际 {sorted(blocked_ids)}，"
                  f"期望 {sorted(expected_blocked)}（§9 #10/#11/#13 V2/PoC 恰 3 项）")

if errors:
    print("manifest 硬校验 FAIL：")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

print(f"manifest 硬校验 PASS：13 项×8 键齐全；PASS 项均带 evidence；"
      f"blocked_by_p2 恰 3 项（{', '.join(sorted(blocked_ids))}）；无静默跳过")
PY

# === [14A-2 placeholder] 工程段 B（前置=老林清除系统认证阻塞）===
# 待实现后在此顺序追加：
#   - VoiceInkUITests 灯条验收面（plan Step 4 逐项：completed 5min 退灯保留摘要/
#     Off 绝对安静/非激活不抢焦点/previous-focus 恢复/8槽+N/VoiceOver/纯键盘/Reduce Motion）
#   - P1 critical E2E 双场景（真实 hook deliver → 灯条/通知；断线重连/冷启动各一条）
#   - 环境/降级矩阵 evidence + supported-host 矩阵
#   - 最小通知/音频面（播放前提=drainedEntries 非空）+ settings preset/muted 真值
# 本段 GREEN 后更新 manifest #4/#5/#6/#7/#8/#11/#12 未覆盖项状态。

# === [14A-3 placeholder] 观察段（老林在场，3 个工作日）===
# 待 14A-2 GREEN 后追加：
#   - 3 日×≥5 次×4/6/8 会话分层样本 → attention-one-glance-observation.csv（人工标签）
#   - 一眼二问全对率≥80% + 假?灰率≤5% + p95≤2s 真机抽查
#   - manifest 终版状态更新 → 本脚本全绿 → P1 flag 启用裁决呈报

echo ""
echo "=== [14A-1 gate] 包域段 GREEN（14A-2/3 段为 placeholder，P1 flag 保持 Off）==="

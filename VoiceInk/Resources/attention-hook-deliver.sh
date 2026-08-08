#!/bin/bash
# Voice Coding M1 hook 投递脚本（ADJ-3：--retry 2 --max-time 5）
# stdin = Claude Code hook JSON；环境变量 ATTENTION_PORT/ATTENTION_TOKEN 由安装器写入 hooks command
set -u
# F7：python3 依赖探测——缺失则静默退出（不阻塞 Claude Code），
# VoiceInk 诊断页以 E-DELIVERY 计数提示「投递脚本依赖缺失」
if ! command -v /usr/bin/python3 >/dev/null 2>&1; then
  cat >/dev/null  # 消费 stdin 避免 SIGPIPE 影响 Claude Code
  exit 0
fi
INPUT=$(cat)
# C6 修法 B（re-review，老林拍板）：delivery nonce——每次 hook 调用生成一次。
# curl --retry 是同进程重发同一 $PAYLOAD，nonce 不变 → 重试幂等保留；
# 同 session 多轮同内容 Stop 拿到不同 nonce → 不被幂等吐掉（B 轨实测 14 Stop 中 5 会话 ≥2 次）
DELIVERY_ID=$(/usr/bin/python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || true)
export DELIVERY_ID
# C7（codex fold）：shadow-log 双写——影子对照的独立 ground truth
# 机械对比 shadow-log vs VoiceInk 导出判漏捕/误报；双写失败不阻塞投递主路径
# delivery_id 一并入 shadow-log（C6 协同：对比可精确到事件级 join）
LOG_DIR="$HOME/.voice-coding"
mkdir -p "$LOG_DIR" 2>/dev/null
printf '%s\n' "$INPUT" | /usr/bin/python3 -c '
import sys, json, time, os
d = json.load(sys.stdin)
print(json.dumps({"hook_event_name": d.get("hook_event_name",""),
                  "session_id": d.get("session_id",""),
                  "delivery_id": os.environ.get("DELIVERY_ID",""),
                  "ts": time.time()}, ensure_ascii=False))
' >> "$LOG_DIR/shadow-log.jsonl" 2>/dev/null || true
EVENT_NAME=$(printf '%s' "$INPUT" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("hook_event_name",""))' 2>/dev/null)
PORT="${ATTENTION_PORT:-47821}"
TOKEN="${ATTENTION_TOKEN:-}"
PAYLOAD=$(printf '%s' "$INPUT" | /usr/bin/python3 -c '
import sys, json, os
d = json.load(sys.stdin)
d.pop("transcript_content", None)
d.pop("prompt", None)
d["delivery_id"] = os.environ.get("DELIVERY_ID","")
print(json.dumps({"hook_event_name": d.get("hook_event_name",""), "payload": d}))
' 2>/dev/null)
[ -z "$PAYLOAD" ] && exit 0
curl -s --retry 2 --max-time 5 -X POST "http://127.0.0.1:${PORT}/ingest" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" >/dev/null 2>&1
exit 0  # 投递失败不阻塞 Claude Code（丢失计数在 VoiceInk 侧）

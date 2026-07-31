#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""盲测 harness（Task 12，M0.5）

对 audio/ 下每段音频跑两路：
  A = Whisper 本地裸转写（whisper-cli，不润色）—— VoiceInk v2.1 原文基线
  B = DashScope ASR 转写 + qwen 润色（openclaw agent CLI，coding 场景 prompt）—— 我们的输出

随机排列 A/B 去标识 → 出盲评 markdown（review_sheet.md）+ 答案 key（answer_key.md，评审后才看）。
评审在 review_sheet 填选择，跑 tally.py 统计 B 胜率。

用法：
  source ../../.blindtest-venv/bin/activate   # 带 DASHSCOPE_API_KEY
  python3 run_blindtest.py
"""
import os
import re
import sys
import json
import random
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
AUDIO_DIR = HERE / "audio"
OUT_DIR = HERE / "out"

# ── 外部工具定位 ──
WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
WHISPER_MODEL = os.path.expanduser(
    "~/Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/ggml-large-v3-turbo-q5_0.bin")
OPENCLAW_DIR = os.path.expanduser("~/projects/OpenClaw")
OPENCLAW_ENV = {"OPENCLAW_GATEWAY_PORT": "18789", "OPENCLAW_GATEWAY_TOKEN": "c2-dev-token"}

# 生产 coding 场景润色 prompt（对齐 AgentVoice PromptTemplates.build .coding）
POLISH_PROMPT = (
    "你是编程语音输入助手。将以下口述内容转为清晰的技术表述/代码注释/commit message。"
    "保留技术术语，去除口语冗余（嗯/那个/就是）。输出纯文本，不加 markdown 格式。\n\n"
    "口述内容：{raw}\n\n"
    "只输出润色后的结果，不要任何解释。"
)


def to_wav16k(src: Path) -> Path:
    """任意音频 → 16k 单声道 wav（whisper/dashscope 要求）"""
    dst = OUT_DIR / "wav" / (src.stem + ".wav")
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(src), "-ar", "16000", "-ac", "1", str(dst)],
        check=True, capture_output=True)
    return dst


def whisper_transcribe(wav: Path) -> str:
    """A 侧：whisper-cli 本地裸转写"""
    of = OUT_DIR / "whisper" / wav.stem
    (OUT_DIR / "whisper").mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [WHISPER_CLI, "-m", WHISPER_MODEL, "-l", "auto", "-f", str(wav),
         "-otxt", "-of", str(of)],
        check=True, capture_output=True)
    txt = (of.with_suffix(".txt")).read_text(encoding="utf-8").strip()
    # whisper-cli 输出带时间戳行，取纯文本
    lines = [ln.strip() for ln in txt.splitlines() if ln.strip() and not ln.strip().startswith("[")]
    return " ".join(lines).strip()


def dashscope_transcribe(wav: Path) -> str:
    """B 侧 ASR：dashscope paraformer-realtime-v2"""
    from dashscope.audio.asr import Recognition
    rec = Recognition(model="paraformer-realtime-v2", format="wav",
                      sample_rate=16000, language_hints=["zh", "en"], callback=None)
    result = rec.call(str(wav))
    if result.status_code != 200:
        raise RuntimeError(f"dashscope ASR 失败: {result.message}")
    sents = result.get_sentence()
    if isinstance(sents, dict):
        sents = [sents]
    return "".join(s.get("text", "") for s in sents).strip()


def openclaw_polish(raw: str) -> str:
    """B 侧润色：openclaw agent CLI（真 qwen，经 :18789 gateway）"""
    prompt = POLISH_PROMPT.format(raw=raw)
    env = dict(os.environ, **OPENCLAW_ENV)
    proc = subprocess.run(
        ["node", "openclaw.mjs", "agent", "--agent", "dev", "--json",
         "--timeout", "60", "-m", prompt],
        cwd=OPENCLAW_DIR, env=env, check=True, capture_output=True, text=True)
    # --json 输出可能带前导日志，取最后一个完整 JSON 对象
    out = proc.stdout
    m = re.search(r'\{.*\}\s*$', out, re.DOTALL)
    if not m:
        raise RuntimeError(f"openclaw 无 JSON 输出:\n{out[-500:]}")
    data = json.loads(m.group(0))
    # finalAssistantVisibleText 在嵌套 result 里
    def find_text(obj):
        if isinstance(obj, dict):
            if "finalAssistantVisibleText" in obj and obj["finalAssistantVisibleText"]:
                return obj["finalAssistantVisibleText"]
            for v in obj.values():
                r = find_text(v)
                if r:
                    return r
        elif isinstance(obj, list):
            for v in obj:
                r = find_text(v)
                if r:
                    return r
        return None
    text = find_text(data)
    if not text:
        raise RuntimeError(f"openclaw 未提取到润色文本:\n{json.dumps(data, ensure_ascii=False)[:500]}")
    return text.strip()


def main():
    if not Path(WHISPER_CLI).exists():
        sys.exit(f"❌ whisper-cli 不在 {WHISPER_CLI}")
    if not Path(WHISPER_MODEL).exists():
        sys.exit(f"❌ whisper 模型不在 {WHISPER_MODEL}")
    if not os.environ.get("DASHSCOPE_API_KEY"):
        sys.exit("❌ 无 DASHSCOPE_API_KEY（source ../../.blindtest-venv/bin/activate）")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    audios = sorted([p for p in AUDIO_DIR.iterdir()
                     if p.suffix.lower() in (".wav", ".aiff", ".aif", ".m4a", ".mp3", ".flac")])
    if not audios:
        sys.exit(f"❌ audio/ 目录为空，先放录音（见 RECORDING_GUIDE.md）")

    print(f"=== 盲测 harness：{len(audios)} 段音频 ===\n")
    results = []
    for i, src in enumerate(audios, 1):
        print(f"[{i}/{len(audios)}] {src.name}")
        wav = to_wav16k(src)

        a_text = whisper_transcribe(wav)
        print(f"  A (whisper 裸转写): {a_text}")

        b_raw = dashscope_transcribe(wav)
        print(f"  B-asr (dashscope): {b_raw}")
        b_text = openclaw_polish(b_raw)
        print(f"  B (润色后): {b_text}")

        results.append({
            "file": src.name,
            "a_whisper": a_text,
            "b_asr_raw": b_raw,
            "b_polished": b_text,
        })
        print()

    # ── 去标识随机排列 ──
    pairs = []
    for idx, r in enumerate(results, 1):
        # 随机决定甲/乙哪个是 A 哪个是 B
        a_is_first = random.random() < 0.5
        pairs.append({
            "sample": idx,
            "file": r["file"],
            "a_is_first": a_is_first,
            "first": r["a_whisper"] if a_is_first else r["b_polished"],
            "second": r["b_polished"] if a_is_first else r["a_whisper"],
        })

    # ── 盲评表（评审看，无答案）──
    sheet = ["# 盲评表（Task 12）\n",
             "每段有甲/乙两个转写结果，不知道哪个来自哪个方案。",
             "请逐段选出「更好」的一个（准确性 + 可用性 + 整体偏好），填在【选择】栏（填 甲 或 乙）。\n"]
    for p in pairs:
        sheet.append(f"\n## 样本 {p['sample']}\n")
        sheet.append(f"**甲**：{p['first']}\n")
        sheet.append(f"**乙**：{p['second']}\n")
        sheet.append(f"**选择**（甲/乙）：______\n")
    (OUT_DIR / "review_sheet.md").write_text("\n".join(sheet), encoding="utf-8")

    # ── 答案 key（评审后才看，tally 用）──
    key = ["# 答案 key（评审完成前勿看）\n",
           "| 样本 | 文件 | 甲是 | 乙是 |",
           "|---|---|---|---|"]
    for p in pairs:
        jia = "A(whisper裸)" if p["a_is_first"] else "B(我们润色)"
        yi = "B(我们润色)" if p["a_is_first"] else "A(whisper裸)"
        key.append(f"| {p['sample']} | {p['file']} | {jia} | {yi} |")
    (OUT_DIR / "answer_key.md").write_text("\n".join(key), encoding="utf-8")

    # ── 原始数据（调试用）──
    (OUT_DIR / "raw_results.json").write_text(
        json.dumps({"results": results, "pairs": pairs}, ensure_ascii=False, indent=2),
        encoding="utf-8")

    print(f"=== 完成 ===")
    print(f"盲评表: {OUT_DIR / 'review_sheet.md'}")
    print(f"答案 key: {OUT_DIR / 'answer_key.md'}（评审后才看）")
    print(f"原始数据: {OUT_DIR / 'raw_results.json'}")
    print(f"\n下一步：填好 review_sheet.md 的【选择】栏，跑 python3 tally.py")


if __name__ == "__main__":
    main()

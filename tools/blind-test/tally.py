#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""盲测统计（Task 12，M0.5）

读填好的 review_sheet.md（【选择】栏）+ answer_key.md，统计 B（我们润色）胜率。
Phase 0 通过条件：B 胜率 > 70%。

用法：填好 out/review_sheet.md 后跑 python3 tally.py
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT_DIR = HERE / "out"


def parse_sheet(text: str) -> dict:
    """从 review_sheet.md 提取每样本的【选择】（甲/乙）"""
    choices = {}
    # 匹配 "## 样本 N" ... "**选择**（甲/乙）：X"
    blocks = re.split(r"## 样本 (\d+)", text)
    # blocks[0] 是头部，之后成对：[样本号, 内容, 样本号, 内容, ...]
    for i in range(1, len(blocks), 2):
        sample = int(blocks[i])
        content = blocks[i + 1]
        m = re.search(r"\*\*选择\*\*（甲/乙）：\s*([甲乙])", content)
        if m:
            choices[sample] = m.group(1)
    return choices


def parse_key(text: str) -> dict:
    """从 answer_key.md 提取每样本甲是哪个方案"""
    mapping = {}
    for line in text.splitlines():
        m = re.match(r"\|\s*(\d+)\s*\|[^|]*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|", line)
        if m:
            sample = int(m.group(1))
            jia = m.group(2)
            mapping[sample] = jia  # "A(whisper裸)" 或 "B(我们润色)"
    return mapping


def main():
    sheet_path = OUT_DIR / "review_sheet.md"
    key_path = OUT_DIR / "answer_key.md"
    if not sheet_path.exists():
        sys.exit(f"❌ {sheet_path} 不存在，先跑 run_blindtest.py")
    if not key_path.exists():
        sys.exit(f"❌ {key_path} 不存在")

    choices = parse_sheet(sheet_path.read_text(encoding="utf-8"))
    mapping = parse_key(key_path.read_text(encoding="utf-8"))

    if not choices:
        sys.exit("❌ review_sheet.md 里没填任何【选择】（甲/乙）")

    total = 0
    b_wins = 0
    a_wins = 0
    detail = []
    for sample in sorted(mapping):
        if sample not in choices:
            detail.append(f"样本 {sample}：未填选择（跳过）")
            continue
        pick = choices[sample]  # 甲 或 乙
        jia_is = mapping[sample]  # 甲是哪个方案
        # 用户选的那个是哪个方案
        if pick == "甲":
            picked_scheme = jia_is
        else:
            picked_scheme = "B(我们润色)" if jia_is.startswith("A") else "A(whisper裸)"
        total += 1
        if picked_scheme.startswith("B"):
            b_wins += 1
            detail.append(f"样本 {sample}：选 {pick} → B(我们) 胜")
        else:
            a_wins += 1
            detail.append(f"样本 {sample}：选 {pick} → A(whisper裸) 胜")

    print("=== 盲测统计 ===\n")
    for d in detail:
        print("  " + d)
    print()
    if total == 0:
        sys.exit("❌ 无有效样本")
    rate = b_wins / total * 100
    print(f"有效样本：{total}")
    print(f"B（我们润色）胜：{b_wins}")
    print(f"A（whisper裸）胜：{a_wins}")
    print(f"B 胜率：{rate:.0f}%")
    print()
    if rate > 70:
        print("✅ Phase 0 通过（胜率 > 70%）→ 进 Phase 1")
    elif rate > 50:
        print("⚠️  50% < 胜率 ≤ 70% → 分析原因，调整 prompt/ASR 后重测")
    else:
        print("❌ 胜率 ≤ 50% → 重新评估差异化策略")


if __name__ == "__main__":
    main()

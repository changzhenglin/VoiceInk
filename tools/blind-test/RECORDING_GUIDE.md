# 盲测录音规范（Task 12，M0.5）

> 目的：录 10 段真实编程口述音频，喂给 `run_blindtest.py` 跑 A/B 对比盲评。
> A = Whisper 本地裸转写（VoiceInk v2.1 基线）；B = DashScope ASR + qwen 润色（我们的输出）。

## 录音要求

| 项 | 要求 |
|---|---|
| 段数 | **10 段**（按下面脚本，每类场景数量固定） |
| 时长 | 每段 **5–15 秒**（一句话为主，别太长） |
| 格式 | 任意常见格式都行（wav / m4a / aiff / mp3 / flac），harness 会自动转 16k 单声道 |
| 环境 | 安静室内，正常说话音量，**别刻意播音腔**——要的就是真实口语（嗯/那个/就是 这些冗余词留着，这正是润色要处理的） |
| 命名 | `01.wav` ~ `10.wav`（按脚本顺序，前缀数字即样本号） |
| 放哪 | 全部丢进 `tools/blind-test/audio/` 目录 |

**录音方式**（任选）：
- Mac 语音备忘录（录完导出 m4a）
- QuickTime Player → 新建音频录制
- 或直接用 VoiceInk 竞品录——但**只录原始口述音频**，别用它的转写结果

## 10 段脚本（照着念，口语化）

> 念的时候自然一点，带点口语冗余词更真实。括号里是场景说明，不用念出来。

**代码意图（3 段）**
1. 「嗯那个，帮我调用一下 audio subsystem 的 create 方法，然后把返回值存到一个局部变量里」
2. 「就是，给这个 user 对象加一个 is_active 的字段，默认值设成 true」
3. 「那个，把这个函数改成 async 的，然后里面 await 一下数据库的查询」

**注释意图（2 段）**
4. 「加一个 TODO 注释，就是说这里以后要换成真正的鉴权逻辑，现在先临时放行」
5. 「嗯，给这段代码写个注释，解释一下为什么要用二分查找而不是线性遍历」

**commit message（2 段）**
6. 「修复了设备注册时候的一个内存泄漏问题，就是那个 listener 没解绑」
7. 「嗯那个，重构了一下配置加载的模块，把硬编码的路径都抽到配置文件里了」

**提问 / 讨论（2 段）**
8. 「这个接口为什么返回的是 optional 啊，是有可能拿不到数据吗」
9. 「就是我在想，这个地方用锁会不会有性能问题，还是说换成无锁队列比较好」

**办公混合（1 段）**
10. 「嗯那个就是，我觉得这个方案整体还行，就是实现上有点复杂，能不能再简化一下」

## 跑盲测

```bash
cd ~/projects/voice-coding/tools/blind-test

# 1. 确认 10 段音频都在 audio/ 里
ls audio/

# 2. 激活带 key 的 venv
source ../../.blindtest-venv/bin/activate

# 3. 跑 harness（A/B 两路转写 + 润色 + 随机去标识出盲评表）
python3 run_blindtest.py

# 4. 打开盲评表，逐段填【选择】（甲/乙）—— 凭直觉选更好的，别偷看 answer_key.md
open out/review_sheet.md

# 5. 填完统计胜率
python3 tally.py
```

## 通过标准

- **B 胜率 > 70%** → Phase 0 通过，进 Phase 1
- 50% < 胜率 ≤ 70% → 分析原因（prompt/ASR），调整后重测
- 胜率 ≤ 50% → 重新评估差异化策略

## 注意

- `out/answer_key.md` 是答案对照表，**评审填完选择前别看**，否则盲评失效
- `out/raw_results.json` 是原始数据（含 A/B 全文 + 去标识映射），调试用
- 冒烟验证已过（2026-07-31）：whisper-cli + dashscope paraformer + openclaw qwen 润色全链路通

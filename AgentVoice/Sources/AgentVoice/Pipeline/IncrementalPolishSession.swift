// AgentVoice/Sources/AgentVoice/Pipeline/IncrementalPolishSession.swift
import Foundation

/// 逐句润色状态（spec §2.1 四状态表真落地——fold：补齐 .pending，
/// 等待队列里的句子不再冒认 .polishing）
public enum SentencePolishState: Sendable, Equatable {
    case pending           // 已派列入等待队列（并发上限占满），请求尚未开始
    case polishing         // 请求在飞
    case polished(String)  // 润色成功（携带润色文本）
    case failed            // 失败/润色无变化 → 该句按原文参与重组
}

/// 单句呈现状态（UI 与重组共用）
public struct SentenceRenderState: Sendable, Equatable {
    public let index: Int
    /// 识别返回的逐字原文（不 trim——fold GC15：回退与拼接保真）
    public let originalText: String
    /// 送模型的润色输入（trim 后；trim 只用于判空与送模型两处）
    public let polishInput: String
    public var state: SentencePolishState
    /// 呈现文本 = 润色成功取润色文本，否则逐字原文（spec §4.1 失败静默降级）
    public var displayText: String {
        if case .polished(let text) = state { return text }
        return originalText
    }
}

/// 增量润色快照（UI 消费 + 组装结果）
public struct IncrementalSnapshot: Sendable, Equatable {
    public let sentences: [SentenceRenderState]
    public let assembledText: String
    public let allDone: Bool
}

/// 逐句润色缝隙（生产实现包装 VoicePipeline.polish；测试注 fake）
public protocol SentencePolishPort: Sendable {
    /// context=预留上下文窗口参数（spec §2.1 升级后门，决策 4）：当前恒传 nil；
    /// 实测跨句不一致需带前文时，由此参数注入，不改签名
    func polishSentence(_ text: String, scene: SceneContext, traceId: String,
                        context: String?) async -> PolishOutcome
}

/// 增量润色会话（spec §2.1 新增组件；方案 1 裁决）。
/// 并发语义：@MainActor 隔离（与 VoiceInputSessionController 同域，无跨 actor 数据竞争）；
/// 润色 await 挂起不阻塞 MainActor 事件循环。token 失效在飞续体（cancel/会话切换）。
@MainActor
public final class IncrementalPolishSession {

    private let polishPort: any SentencePolishPort
    private let scene: SceneContext
    private let traceId: String
    private let maxInFlight: Int
    /// 连续失败熔断阈值（spec §5.2：建议值 3，实现计划定案）
    private let circuitBreakThreshold = 3

    private var sentences: [SentenceRenderState] = []
    private var waitQueue: [Int] = []
    private var inFlight = 0
    private var consecutiveFailures = 0
    private var halted = false
    private var generation = 0        // cancel 递增，失效在飞续体
    public var onUpdate: (@Sendable (IncrementalSnapshot) -> Void)?

    public init(polishPort: any SentencePolishPort, scene: SceneContext,
                traceId: String, maxInFlight: Int = 3) {
        self.polishPort = polishPort
        self.scene = scene
        self.traceId = traceId
        self.maxInFlight = max(1, maxInFlight)
    }

    /// 新定稿句批量派发（句序=传入顺序；空白句直接丢弃——非空即润的反面）。
    /// fold（P2-8）：originalText 存逐字原文不 trim；trim 只用于判空与生成 polishInput。
    public func dispatch(newSentences: [String]) {
        for raw in newSentences {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let index = sentences.count
            if halted {
                sentences.append(SentenceRenderState(index: index, originalText: raw,
                                                     polishInput: trimmed, state: .failed))
                continue
            }
            // fold（P2-1）：入队即 .pending；有槽位立即转 .polishing 并发起请求
            sentences.append(SentenceRenderState(index: index, originalText: raw,
                                                 polishInput: trimmed, state: .pending))
            if inFlight >= maxInFlight {
                waitQueue.append(index)
            } else {
                startPolish(index: index)
            }
        }
        notify()
    }

    /// 松手补尾后取快照（不等待——预览立即呈现，完成句渐进替换，spec §3/§4.2）
    public func snapshot() -> IncrementalSnapshot {
        IncrementalSnapshot(sentences: sentences,
                            assembledText: sentences.map(\.displayText).joined(),
                            allDone: !sentences.contains {
                                $0.state == .polishing || $0.state == .pending
                            })
    }

    /// 取消 = 失效全部在飞续体（generation 递增）；后续 dispatch 无效（调用方不再调）
    public func cancel() {
        generation += 1
        waitQueue.removeAll()
    }

    private func startPolish(index: Int) {
        sentences[index].state = .polishing   // fold（P2-1）：真正开始请求才转 .polishing
        inFlight += 1
        let gen = generation
        let input = sentences[index].polishInput
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.polishPort.polishSentence(input, scene: self.scene,
                                                               traceId: self.traceId,
                                                               context: nil)   // 上下文窗口预留，当前不传
            guard self.generation == gen else { return }   // cancel 后在飞续体作废
            self.inFlight -= 1
            guard index < self.sentences.count else { return }
            if outcome.polished, !outcome.finalText.isEmpty, outcome.finalText != input {
                self.sentences[index].state = .polished(outcome.finalText)
                self.consecutiveFailures = 0
            } else {
                self.sentences[index].state = .failed
                self.consecutiveFailures += 1
            }
            self.evaluateHalt()   // fold（P2-2）：halt 仅在无在飞时生效；先于 pump 评估——阈值时刻不偷派新句
            if self.inFlight == 0 { self.pumpQueue() }   // plan 冻结测试语义：整批空闲后波浪式补位（在飞未耗尽不提升排队句）
            self.notify()
        }
    }

    /// fold（codex P2-2）熔断窗口顺序语义（定案）：
    /// 「连续失败」按完成顺序统计可以，但 halt 只在**无在飞请求**时生效——
    /// 防止并发下三个快失败抢在一个慢成功返回前触发永久 halt（慢成功回来会重置计数，
    /// 说明链路其实是通的）。inFlight>0 时只累计不 halt；任一在飞成功返回即重置。
    private func evaluateHalt() {
        guard !halted, consecutiveFailures >= circuitBreakThreshold, inFlight == 0 else { return }
        halt()
    }

    private func pumpQueue() {
        while !halted, inFlight < maxInFlight, !waitQueue.isEmpty {
            startPolish(index: waitQueue.removeFirst())
        }
        // 熔断时等待队列全部转原文（不再派发）
        if halted, !waitQueue.isEmpty {
            for index in waitQueue { sentences[index].state = .failed }
            waitQueue.removeAll()
        }
    }

    private func halt() {
        halted = true
        for index in waitQueue { sentences[index].state = .failed }
        waitQueue.removeAll()
    }

    private func notify() { onUpdate?(snapshot()) }
}

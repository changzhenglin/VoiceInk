import Foundation

/// 润色错误（映射 bridge result degraded_reason，对齐 5b D4 BridgeTextReason）
/// wire 字面量来源：merged bridge_sink.c:228-274
public enum PolishError: Error, Sendable {
    /// WS 连接/ACK 失败
    case transport(String)
    /// command_id 不匹配 / card_payload 解析失败
    case malformedResult(String)
    /// DONE_WITH_CONCERNS 但 text 空（truthfulness：不 yield 空字符串）
    case emptyResponse
    /// bridge 报 provider_error
    case providerError(String)
    /// 端侧 prompt 组装 bug（不应发生）
    case badPayload
    /// gateway 不可达/超时（wire: openclaw_unreachable / gateway_timeout）
    case unreachable
    /// CLI fallback 不支持（wire: cli_text_unsupported）
    case cliUnsupported
}

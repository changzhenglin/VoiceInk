import Foundation

/// C-ERROR（Phase 1 spec §9.4 Error & Rescue Registry，M1 首版）
public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case hookInstallConflict = "E-HOOK-INSTALL-CONFLICT"
    case hookInstallFailed = "E-HOOK-INSTALL-FAILED"
    case identity = "E-IDENTITY"                    // ADJ-1
    case sessionConflict = "E-SESSION-CONFLICT"     // ADJ-2（身份碰撞，见 Task 3）
    case deliveryTimeout = "E-DELIVERY-TIMEOUT"     // ADJ-3
    case authReject = "E-AUTH-REJECT"
    case versionDrift = "E-VERSION-DRIFT"           // ADJ-4
    case axNavFailed = "E-AX-NAV-FAILED"
    case recvCapacity = "E-RECV-CAPACITY"           // 仅缓冲/容量满
    case malformedEvent = "E-MALFORMED-EVENT"       // 未识别 hook/缺 session_id/JSON 坏
    case privacyGate = "E-PRIVACY-GATE"             // Task 4：privacy 门拒绝（源禁止/超限/未审查，read-only）
}

import Foundation

enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case enhancing
    case busy
    case previewing   // V1：预览确认中（AgentVoice 分支专属；Task 7）
}

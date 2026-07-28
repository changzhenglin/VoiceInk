import Foundation

/// DI 容器（composition root，唯一知道具体实现的地方）
public final class AppContainer: @unchecked Sendable {
    private var registrations: [ObjectIdentifier: Any] = [:]

    public init() {}

    /// 注册实现
    public func register<T>(_ type: T.Type, _ implementation: T) {
        registrations[ObjectIdentifier(type)] = implementation
    }

    /// 解析实现
    public func resolve<T>(_ type: T.Type) -> T {
        guard let impl = registrations[ObjectIdentifier(type)] as? T else {
            fatalError("No registration for \(type). Did you forget to register in AppContainer?")
        }
        return impl
    }

    /// 可选解析（不崩溃）
    public func resolveOptional<T>(_ type: T.Type) -> T? {
        registrations[ObjectIdentifier(type)] as? T
    }
}

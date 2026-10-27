import Foundation

/// Synchronous calls are deliberately serialized with generation checks in SessionEngine.
public protocol PowerBackend: Sendable {
    func create(kind: PowerKind, timeout: TimeInterval) throws -> PowerToken
    func renew(_ token: PowerToken, timeout: TimeInterval) throws
    func release(_ token: PowerToken) throws
    /// false must mean confirmed absence/inactivity; IPC and inspection failures throw.
    func inspect(_ token: PowerToken) throws -> Bool
}

public protocol MonotonicTimeSource: Sendable {
    func now() -> TimeInterval
}

public struct ContinuousTimeSource: MonotonicTimeSource {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    public init() { origin = ContinuousClock().now }
    public func now() -> TimeInterval {
        let value = origin.duration(to: clock.now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

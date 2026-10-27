import Foundation

public enum PowerKind: String, CaseIterable, Hashable, Sendable {
    case systemIdle, diskIdle
}

public struct PowerToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public enum PowerOperation: String, Sendable { case create, renew, release, inspect }

public struct PowerBackendFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let operation: PowerOperation
    public let code: Int32
    public let detail: String
    public init(operation: PowerOperation, code: Int32, detail: String) {
        self.operation = operation
        self.code = code
        self.detail = detail
    }
    public var description: String { "\(operation.rawValue): \(detail) (\(code))" }
}

public struct SessionRequest: Equatable, Sendable {
    /// nil means manually ended; native assertions still have short system leases.
    public var duration: TimeInterval?
    public var keepDiskActive: Bool
    public var requestLidClosed: Bool
    public init(duration: TimeInterval? = 3600, keepDiskActive: Bool = false, requestLidClosed: Bool = false) {
        self.duration = duration
        self.keepDiskActive = keepDiskActive
        self.requestLidClosed = requestLidClosed
    }
    public var desiredPower: Set<PowerKind> {
        keepDiskActive ? [.systemIdle, .diskIdle] : [.systemIdle]
    }
}

public enum LidCapability: String, Sendable { case notValidated, unsupported }
public enum SessionPhase: String, Sendable { case idle, acquiring, active, releasing, failed, unknown }
public enum SessionEndReason: String, Sendable {
    case userStopped, durationElapsed, leaseExpired, renewalFailed, acquisitionFailed
    case cleanupFailed, lowBattery, thermalCritical, systemSleep, logout
    case lidNotValidated, invalidRequest
}

public enum PowerSource: String, Sendable { case ac, battery, unknown }
public enum ThermalLevel: String, Sendable { case nominal, fair, serious, critical, unknown }
public enum NetworkAvailability: String, Sendable { case available, unavailable, unknown }

public struct EnvironmentSnapshot: Equatable, Sendable {
    public var powerSource: PowerSource
    public var batteryPercent: Int?
    public var thermal: ThermalLevel
    public var network: NetworkAvailability
    public init(powerSource: PowerSource = .unknown, batteryPercent: Int? = nil, thermal: ThermalLevel = .unknown, network: NetworkAvailability = .unknown) {
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.thermal = thermal
        self.network = network
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public let sessionID: UUID?
    public let phase: SessionPhase
    public let request: SessionRequest?
    public let desired: Set<PowerKind>
    public let granted: Set<PowerKind>
    public let unknown: Set<PowerKind>
    public let lidCapability: LidCapability
    public let remainingDuration: TimeInterval?
    public let remainingLease: TimeInterval?
    public let endReason: SessionEndReason?
    public let failureDescription: String?
    public let environment: EnvironmentSnapshot
    public var isActive: Bool { phase == .active }
}

public struct SessionConfiguration: Equatable, Sendable {
    public var leaseDuration: TimeInterval
    public var renewalInterval: TimeInterval
    public var batteryStopPercent: Int
    public init(leaseDuration: TimeInterval = 90, renewalInterval: TimeInterval = 30, batteryStopPercent: Int = 20) {
        self.leaseDuration = leaseDuration
        self.renewalInterval = renewalInterval
        self.batteryStopPercent = batteryStopPercent
    }
}

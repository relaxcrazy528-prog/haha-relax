import Foundation

/// Owns every native token. No suspension occurs between session validation and native calls.
public actor SessionEngine {
    private struct Lease {
        let token: PowerToken
        var expiresAt: TimeInterval
        var certainty: Bool?
    }

    private let backend: any PowerBackend
    private let clock: any MonotonicTimeSource
    private let configuration: SessionConfiguration
    private var sessionID: UUID?
    private var phase: SessionPhase = .idle
    private var request: SessionRequest?
    private var deadline: TimeInterval?
    private var leases: [PowerKind: Lease] = [:]
    private var lastRenewal: TimeInterval?
    private var endReason: SessionEndReason?
    private var failureDescription: String?
    private var environment = EnvironmentSnapshot()

    public init(backend: any PowerBackend, clock: any MonotonicTimeSource = ContinuousTimeSource(), configuration: SessionConfiguration = .init()) {
        self.backend = backend
        self.clock = clock
        self.configuration = configuration
    }

    @discardableResult
    public func start(_ request: SessionRequest) -> SessionSnapshot {
        refreshExpiration()
        // A failed cleanup still owns resources; starting again must never orphan them.
        guard phase != .active, leases.isEmpty else { return makeSnapshot() }
        sessionID = UUID()
        self.request = request
        endReason = nil
        failureDescription = nil
        lastRenewal = nil
        deadline = nil

        guard configuration.leaseDuration.isFinite, configuration.leaseDuration > 0,
              configuration.renewalInterval.isFinite, configuration.renewalInterval > 0,
              configuration.renewalInterval < configuration.leaseDuration,
              (0...100).contains(configuration.batteryStopPercent),
              request.duration.map({ $0.isFinite && $0 > 0 }) ?? true else {
            phase = .failed
            endReason = .invalidRequest
            failureDescription = "Invalid session duration or lease configuration."
            return makeSnapshot()
        }
        guard !request.requestLidClosed else {
            phase = .failed
            endReason = .lidNotValidated
            failureDescription = "Closed-lid operation has no validated backend."
            return makeSnapshot()
        }
        if let reason = environmentStopReason() {
            phase = .failed
            endReason = reason
            return makeSnapshot()
        }

        let startedAt = clock.now()
        if let duration = request.duration { deadline = startedAt + duration }
        phase = .acquiring
        for kind in PowerKind.allCases where request.desiredPower.contains(kind) {
            do {
                let beforeCreate = clock.now()
                guard let timeout = nextTimeout(at: beforeCreate) else {
                    finish(reason: .durationElapsed)
                    return makeSnapshot()
                }
                let token = try backend.create(kind: kind, timeout: timeout)
                // Record before inspecting: inspection can throw after a successful create.
                leases[kind] = Lease(token: token, expiresAt: beforeCreate + timeout, certainty: nil)
                guard try backend.inspect(token) else {
                    failureDescription = "Created \(kind.rawValue) request is not active."
                    finish(reason: .acquisitionFailed)
                    return makeSnapshot()
                }
                leases[kind]?.certainty = true
            } catch {
                appendFailure(error)
                finish(reason: .acquisitionFailed)
                return makeSnapshot()
            }
        }
        phase = .active
        lastRenewal = clock.now()
        refreshExpiration()
        return makeSnapshot()
    }

    @discardableResult
    public func stop(sessionID expectedID: UUID) -> SessionSnapshot {
        guard expectedID == sessionID else { return makeSnapshot() }
        finish(reason: .userStopped)
        return makeSnapshot()
    }

    /// Called by the healthy MainActor every renewalInterval, never by a private watchdog.
    @discardableResult
    public func tick(sessionID expectedID: UUID) -> SessionSnapshot {
        guard expectedID == sessionID else { return makeSnapshot() }
        refreshExpiration()
        guard phase == .active else { return makeSnapshot() }
        let now = clock.now()
        guard now - (lastRenewal ?? now) >= configuration.renewalInterval else { return makeSnapshot() }

        for kind in PowerKind.allCases {
            guard let lease = leases[kind] else { continue }
            do {
                // A delayed tick may not recreate or reactivate an expired token.
                let beforeRenew = clock.now()
                guard beforeRenew < lease.expiresAt, let timeout = nextTimeout(at: beforeRenew) else {
                    finish(reason: expirationReason(at: beforeRenew))
                    return makeSnapshot()
                }
                guard try backend.inspect(lease.token) else {
                    leases[kind]?.certainty = false
                    failureDescription = "\(kind.rawValue) request disappeared before renewal."
                    finish(reason: .renewalFailed)
                    return makeSnapshot()
                }
                try backend.renew(lease.token, timeout: timeout)
                leases[kind]?.expiresAt = beforeRenew + timeout
                leases[kind]?.certainty = nil
                guard try backend.inspect(lease.token) else {
                    leases[kind]?.certainty = false
                    failureDescription = "\(kind.rawValue) request is inactive after renewal."
                    finish(reason: .renewalFailed)
                    return makeSnapshot()
                }
                leases[kind]?.certainty = true
            } catch {
                leases[kind]?.certainty = nil
                appendFailure(error)
                finish(reason: .renewalFailed)
                return makeSnapshot()
            }
        }
        lastRenewal = clock.now()
        refreshExpiration()
        return makeSnapshot()
    }

    /// Reading cannot extend any native lease.
    public func snapshot() -> SessionSnapshot {
        refreshExpiration()
        return makeSnapshot()
    }

    @discardableResult
    public func updateEnvironment(_ environment: EnvironmentSnapshot) -> SessionSnapshot {
        self.environment = environment
        refreshExpiration()
        if phase == .active, let reason = environmentStopReason() { finish(reason: reason) }
        return makeSnapshot()
    }

    @discardableResult
    public func systemWillSleep() -> SessionSnapshot {
        if phase == .active || !leases.isEmpty { finish(reason: .systemSleep) }
        return makeSnapshot()
    }

    @discardableResult
    public func userWillLogout() -> SessionSnapshot {
        if phase == .active || !leases.isEmpty { finish(reason: .logout) }
        return makeSnapshot()
    }

    private func nextTimeout(at now: TimeInterval) -> TimeInterval? {
        let timeout = min(configuration.leaseDuration, deadline.map { $0 - now } ?? configuration.leaseDuration)
        return timeout > 0 ? timeout : nil
    }

    private func environmentStopReason() -> SessionEndReason? {
        if environment.thermal == .critical { return .thermalCritical }
        if environment.powerSource == .battery, let percent = environment.batteryPercent,
           (0...100).contains(percent), percent <= configuration.batteryStopPercent { return .lowBattery }
        return nil
    }

    private func expirationReason(at now: TimeInterval) -> SessionEndReason {
        if let deadline, now >= deadline { return .durationElapsed }
        return .leaseExpired
    }

    private func refreshExpiration() {
        guard phase == .active else { return }
        let now = clock.now()
        if (deadline.map { now >= $0 } ?? false) || leases.values.contains(where: { now >= $0.expiresAt }) {
            finish(reason: expirationReason(at: now))
        }
    }

    private func finish(reason: SessionEndReason) {
        phase = .releasing
        endReason = reason
        for kind in PowerKind.allCases {
            guard let lease = leases[kind] else { continue }
            do {
                try backend.release(lease.token)
                leases.removeValue(forKey: kind)
            } catch let releaseError {
                // A failed release is only harmless after the system confirms absence.
                do {
                    let active = try backend.inspect(lease.token)
                    if active {
                        leases[kind]?.certainty = true
                        appendFailure(releaseError)
                    } else { leases.removeValue(forKey: kind) }
                } catch {
                    leases[kind]?.certainty = nil
                    appendFailure(releaseError)
                    appendFailure(error)
                }
            }
        }
        if leases.isEmpty && reason == .userStopped { failureDescription = nil }
        lastRenewal = nil
        if leases.values.contains(where: { $0.certainty == nil }) { phase = .unknown }
        else if !leases.isEmpty { phase = .failed }
        else {
            switch reason {
            case .acquisitionFailed, .renewalFailed, .invalidRequest, .lidNotValidated, .cleanupFailed:
                phase = .failed
            default: phase = .idle
            }
        }
    }

    private func appendFailure(_ error: any Error) {
        let detail = String(describing: error)
        if let previous = failureDescription { failureDescription = previous + "\n" + detail }
        else { failureDescription = detail }
    }

    private func makeSnapshot() -> SessionSnapshot {
        let now = clock.now()
        // An elapsed local lease is never displayed as a still-granted capability.
        let granted = Set(leases.compactMap { kind, lease in
            lease.certainty == true && now < lease.expiresAt ? kind : nil
        })
        let unknown = Set(leases.compactMap { kind, lease in
            lease.certainty == nil || now >= lease.expiresAt ? kind : nil
        })
        return SessionSnapshot(
            sessionID: sessionID, phase: phase, request: request,
            desired: request?.desiredPower ?? [], granted: granted, unknown: unknown,
            lidCapability: .notValidated,
            remainingDuration: deadline.map { max(0, $0 - now) },
            remainingLease: leases.values.map { max(0, $0.expiresAt - now) }.min(),
            endReason: endReason, failureDescription: failureDescription, environment: environment
        )
    }
}

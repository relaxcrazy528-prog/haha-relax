import Foundation
import XCTest
@testable import KeepOnlineCore

private final class TestClock: MonotonicTimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { instant } }
    func advance(_ amount: TimeInterval) { lock.withLock { instant += amount } }
}

private final class TestBackend: PowerBackend, @unchecked Sendable {
    struct State {
        var nextID: UInt32 = 1
        var live: [PowerToken: PowerKind] = [:]
        var creates: [(PowerKind, TimeInterval)] = []
        var renews: [(PowerToken, TimeInterval)] = []
        var releases: [PowerToken] = []
        var failCreate: PowerKind?
        var failRenew: PowerKind?
        var failRelease = false
        var failInspect = false
        var removeOnFailedRelease = false
        var reuseToken = false
    }
    private let lock = NSLock()
    private var storage = State()
    func read() -> State { lock.withLock { storage } }
    func change(_ change: (inout State) -> Void) { lock.withLock { change(&storage) } }
    private func failure(_ operation: PowerOperation) -> PowerBackendFailure {
        PowerBackendFailure(operation: operation, code: -123, detail: "Injected test failure")
    }
    func create(kind: PowerKind, timeout: TimeInterval) throws -> PowerToken {
        try lock.withLock {
            storage.creates.append((kind, timeout))
            if storage.failCreate == kind { throw failure(.create) }
            let token = PowerToken(rawValue: storage.reuseToken ? 1 : storage.nextID)
            storage.nextID += 1
            storage.live[token] = kind
            return token
        }
    }
    func renew(_ token: PowerToken, timeout: TimeInterval) throws {
        try lock.withLock {
            storage.renews.append((token, timeout))
            guard let kind = storage.live[token], storage.failRenew != kind else { throw failure(.renew) }
        }
    }
    func release(_ token: PowerToken) throws {
        try lock.withLock {
            storage.releases.append(token)
            if storage.failRelease {
                if storage.removeOnFailedRelease { storage.live.removeValue(forKey: token) }
                throw failure(.release)
            }
            storage.live.removeValue(forKey: token)
        }
    }
    func inspect(_ token: PowerToken) throws -> Bool {
        try lock.withLock {
            if storage.failInspect { throw failure(.inspect) }
            return storage.live[token] != nil
        }
    }
}

@MainActor
final class SessionEngineTests: XCTestCase {
    private func makeEngine() -> (SessionEngine, TestBackend, TestClock) {
        let backend = TestBackend()
        let clock = TestClock()
        return (SessionEngine(backend: backend, clock: clock), backend, clock)
    }

    func testStartCreatesOneSystemLeaseAndRepeatedStartIsIdempotent() async {
        let (engine, backend, _) = makeEngine()
        let first = await engine.start(.init())
        let second = await engine.start(.init(keepDiskActive: true))
        XCTAssertEqual(first.phase, .active)
        XCTAssertEqual(first.granted, [.systemIdle])
        XCTAssertEqual(first.remainingLease, 90)
        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(backend.read().creates.count, 1)
        XCTAssertEqual(backend.read().creates.first?.1, 90)
    }

    func testDiskAcquisitionFailureRollsBackSystemLease() async {
        let (engine, backend, _) = makeEngine()
        backend.change { $0.failCreate = .diskIdle }
        let result = await engine.start(.init(keepDiskActive: true))
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.endReason, .acquisitionFailed)
        XCTAssertEqual(result.desired, [.systemIdle, .diskIdle])
        XCTAssertTrue(result.granted.isEmpty)
        XCTAssertTrue(backend.read().live.isEmpty)
        XCTAssertEqual(backend.read().releases.count, 1)
    }

    func testInspectionAfterCreateCannotLoseNewNativeToken() async {
        let (engine, backend, _) = makeEngine()
        backend.change { $0.failInspect = true }
        let result = await engine.start(.init())
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.endReason, .acquisitionFailed)
        XCTAssertTrue(backend.read().live.isEmpty)
        XCTAssertEqual(backend.read().releases.count, 1)
    }

    func testRollbackFailureRetainsResourceAndBlocksNewStartUntilCleanup() async throws {
        let (engine, backend, _) = makeEngine()
        backend.change { $0.failCreate = .diskIdle; $0.failRelease = true }
        let failed = await engine.start(.init(keepDiskActive: true))
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.granted, [.systemIdle])
        let blocked = await engine.start(.init())
        XCTAssertEqual(blocked.sessionID, failed.sessionID)
        XCTAssertEqual(backend.read().creates.count, 2)
        backend.change { $0.failRelease = false }
        let cleaned = await engine.stop(sessionID: try XCTUnwrap(failed.sessionID))
        XCTAssertEqual(cleaned.phase, .idle)
        XCTAssertTrue(backend.read().live.isEmpty)
    }

    func testUnknownCleanupKeepsTokenForRetryAndPreservesDiagnosticCode() async throws {
        let (engine, backend, _) = makeEngine()
        let active = await engine.start(.init())
        backend.change { $0.failRelease = true; $0.failInspect = true }
        let unknown = await engine.stop(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(unknown.phase, .unknown)
        XCTAssertEqual(unknown.unknown, [.systemIdle])
        XCTAssertTrue(unknown.failureDescription?.contains("-123") == true)
        XCTAssertEqual(backend.read().live.count, 1)
        backend.change { $0.failRelease = false; $0.failInspect = false }
        let cleaned = await engine.stop(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(cleaned.phase, .idle)
        XCTAssertTrue(cleaned.unknown.isEmpty)
        XCTAssertTrue(backend.read().live.isEmpty)
    }

    func testReleaseErrorIsAcceptedOnlyAfterConfirmedAbsence() async throws {
        let (engine, backend, _) = makeEngine()
        let active = await engine.start(.init())
        backend.change { $0.failRelease = true; $0.removeOnFailedRelease = true }
        let result = await engine.stop(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(result.phase, .idle)
        XCTAssertTrue(result.granted.isEmpty)
        XCTAssertTrue(result.unknown.isEmpty)
    }

    func testSnapshotsAndEarlyTicksDoNotRenewButHealthTickDoes() async throws {
        let (engine, backend, clock) = makeEngine()
        let active = await engine.start(.init())
        let id = try XCTUnwrap(active.sessionID)
        clock.advance(29)
        _ = await engine.tick(sessionID: id)
        _ = await engine.snapshot()
        XCTAssertTrue(backend.read().renews.isEmpty)
        clock.advance(1)
        let beforeTick = await engine.snapshot()
        XCTAssertEqual(beforeTick.remainingLease, 60)
        XCTAssertTrue(backend.read().renews.isEmpty)
        let renewed = await engine.tick(sessionID: id)
        XCTAssertEqual(backend.read().renews.count, 1)
        XCTAssertEqual(renewed.remainingLease, 90)
    }

    func testOldSessionCannotReleaseOrRenewNewSessionEvenIfNativeIDIsReused() async throws {
        let (engine, backend, clock) = makeEngine()
        backend.change { $0.reuseToken = true }
        let first = await engine.start(.init())
        let oldID = try XCTUnwrap(first.sessionID)
        _ = await engine.stop(sessionID: oldID)
        let second = await engine.start(.init())
        clock.advance(30)
        _ = await engine.tick(sessionID: oldID)
        let result = await engine.stop(sessionID: oldID)
        XCTAssertEqual(result.sessionID, second.sessionID)
        XCTAssertEqual(result.phase, .active)
        XCTAssertEqual(backend.read().releases.count, 1)
        XCTAssertTrue(backend.read().renews.isEmpty)
    }

    func testFiniteSessionCapsNativeTimeoutAndDoesNotReviveAtDeadline() async throws {
        let (engine, backend, clock) = makeEngine()
        let active = await engine.start(.init(duration: 40))
        XCTAssertEqual(backend.read().creates.first?.1, 40)
        clock.advance(30)
        _ = await engine.tick(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(backend.read().renews.first?.1, 10)
        clock.advance(10)
        let result = await engine.tick(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.endReason, .durationElapsed)
        XCTAssertEqual(backend.read().renews.count, 1)
        XCTAssertEqual(backend.read().creates.count, 1)
    }

    func testDelayedHealthTickPastLeaseEndsWithoutRenewalOrRecreation() async throws {
        let (engine, backend, clock) = makeEngine()
        let active = await engine.start(.init(duration: nil))
        clock.advance(90)
        let result = await engine.tick(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.endReason, .leaseExpired)
        XCTAssertTrue(backend.read().renews.isEmpty)
        XCTAssertEqual(backend.read().creates.count, 1)
        clock.advance(30)
        _ = await engine.tick(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(backend.read().creates.count, 1)
    }

    func testRenewalFailureStopsWholeSessionAndNeverRebuilds() async throws {
        let (engine, backend, clock) = makeEngine()
        let active = await engine.start(.init(keepDiskActive: true))
        backend.change { $0.failRenew = .diskIdle }
        clock.advance(30)
        let result = await engine.tick(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.endReason, .renewalFailed)
        XCTAssertTrue(result.granted.isEmpty)
        XCTAssertTrue(backend.read().live.isEmpty)
        XCTAssertEqual(backend.read().releases.count, 2)
        _ = await engine.tick(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(backend.read().creates.count, 2)
    }

    func testUnexpectedMissingAssertionStopsRatherThanRecreating() async throws {
        let (engine, backend, clock) = makeEngine()
        let active = await engine.start(.init())
        backend.change { $0.live.removeAll() }
        clock.advance(30)
        let result = await engine.tick(sessionID: try XCTUnwrap(active.sessionID))
        XCTAssertEqual(result.endReason, .renewalFailed)
        XCTAssertTrue(backend.read().renews.isEmpty)
        XCTAssertEqual(backend.read().creates.count, 1)
    }

    func testBatteryThresholdOnlyAppliesToKnownValidBatteryReading() async {
        let (engine, _, _) = makeEngine()
        _ = await engine.updateEnvironment(.init(powerSource: .ac, batteryPercent: 10))
        let active = await engine.start(.init())
        XCTAssertEqual(active.phase, .active)
        let unknown = await engine.updateEnvironment(.init(powerSource: .battery))
        XCTAssertEqual(unknown.phase, .active)
        let invalid = await engine.updateEnvironment(.init(powerSource: .battery, batteryPercent: -1))
        XCTAssertEqual(invalid.phase, .active)
        let low = await engine.updateEnvironment(.init(powerSource: .battery, batteryPercent: 20))
        XCTAssertEqual(low.phase, .idle)
        XCTAssertEqual(low.endReason, .lowBattery)
    }

    func testCriticalTemperatureStopsButSeriousAndNetworkLossDoNot() async {
        let (engine, _, _) = makeEngine()
        _ = await engine.start(.init())
        let serious = await engine.updateEnvironment(.init(thermal: .serious, network: .unavailable))
        XCTAssertEqual(serious.phase, .active)
        let critical = await engine.updateEnvironment(.init(thermal: .critical))
        XCTAssertEqual(critical.phase, .idle)
        XCTAssertEqual(critical.endReason, .thermalCritical)
        let refused = await engine.start(.init())
        XCTAssertEqual(refused.phase, .failed)
        XCTAssertEqual(refused.endReason, .thermalCritical)
    }

    func testSleepAndLogoutEndWithoutAutomaticResume() async {
        let (engine, backend, _) = makeEngine()
        _ = await engine.start(.init())
        let sleeping = await engine.systemWillSleep()
        XCTAssertEqual(sleeping.endReason, .systemSleep)
        _ = await engine.updateEnvironment(.init())
        let stayedOff = await engine.snapshot()
        XCTAssertEqual(stayedOff.phase, .idle)
        XCTAssertEqual(backend.read().creates.count, 1)
        _ = await engine.start(.init())
        let logout = await engine.userWillLogout()
        XCTAssertEqual(logout.phase, .idle)
        XCTAssertEqual(logout.endReason, .logout)
    }

    func testUnvalidatedLidRequestCreatesNoPowerResources() async {
        let (engine, backend, _) = makeEngine()
        let result = await engine.start(.init(requestLidClosed: true))
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.endReason, .lidNotValidated)
        XCTAssertEqual(result.lidCapability, .notValidated)
        XCTAssertTrue(result.granted.isEmpty)
        XCTAssertTrue(backend.read().creates.isEmpty)
    }

    func testInvalidDurationAndConfigurationFailBeforeCallingBackend() async {
        let (engine, backend, _) = makeEngine()
        for duration in [0, -1, Double.infinity, Double.nan] {
            let result = await engine.start(.init(duration: duration))
            XCTAssertEqual(result.endReason, .invalidRequest)
        }
        let invalid = SessionEngine(backend: backend, configuration: .init(leaseDuration: 20, renewalInterval: 30))
        let result = await invalid.start(.init())
        XCTAssertEqual(result.endReason, .invalidRequest)
        XCTAssertTrue(backend.read().creates.isEmpty)
    }
    func testConfirmedCleanupRetryClearsResolvedFailureDiagnostic() async throws {
        let (engine, backend, _) = makeEngine()
        let active = await engine.start(.init())
        let id = try XCTUnwrap(active.sessionID)
        backend.change { $0.failRelease = true; $0.failInspect = true }
        let failed = await engine.stop(sessionID: id)
        XCTAssertEqual(failed.phase, .unknown)
        XCTAssertTrue(failed.failureDescription != nil)
        backend.change { $0.failRelease = false; $0.failInspect = false }
        let recovered = await engine.stop(sessionID: id)
        XCTAssertEqual(recovered.phase, .idle)
        XCTAssertTrue(recovered.failureDescription == nil)
    }

}

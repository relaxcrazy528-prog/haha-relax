import Foundation
import IOKit.pwr_mgt
import KeepOnlineCore

/// No state escapes to a worker queue: SessionEngine serializes all calls and identities.
public struct IOKitPowerBackend: PowerBackend {
    public init() {}

    public func create(kind: PowerKind, timeout: TimeInterval) throws -> PowerToken {
        try validate(timeout, operation: .create)
        let type = kind == .systemIdle ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertPreventDiskIdle
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: type,
            kIOPMAssertionNameKey as String: "KeepOnline: \(kind.rawValue)",
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey as String: timeout,
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease
        ]
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &identifier)
        try check(result, operation: .create)
        return PowerToken(rawValue: identifier)
    }

    public func renew(_ token: PowerToken, timeout: TimeInterval) throws {
        try validate(timeout, operation: .renew)
        let result = IOPMAssertionSetProperty(token.rawValue, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: timeout))
        try check(result, operation: .renew)
    }

    public func release(_ token: PowerToken) throws {
        let result = IOPMAssertionRelease(token.rawValue)
        if result == kIOReturnSuccess { return }
        // Expiration destroys the ID. Only a successful system query can establish absence.
        if result == kIOReturnBadArgument || result == kIOReturnNotFound || result == kIOReturnInvalid {
            if try !inspect(token) { return }
        }
        try check(result, operation: .release)
    }

    public func inspect(_ token: PowerToken) throws -> Bool {
        if let properties = IOPMAssertionCopyProperties(token.rawValue)?.takeRetainedValue() {
            return try active(properties as NSDictionary)
        }
        // The convenience API above drops error information; nil alone is not "off".
        var unmanaged: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&unmanaged)
        try check(result, operation: .inspect)
        guard let processes = unmanaged?.takeRetainedValue() as NSDictionary? else {
            throw malformed("Missing process assertion dictionary")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let ownEntry = processes.object(forKey: NSNumber(value: pid)) ?? processes.object(forKey: String(pid)) else { return false }
        guard let assertions = ownEntry as? [NSDictionary] else { throw malformed("Malformed process assertions") }
        for properties in assertions {
            guard let identifier = properties["AssertionId"] as? NSNumber else { throw malformed("Missing assertion identifier") }
            if identifier.uint32Value == token.rawValue { return try active(properties) }
        }
        return false
    }

    private func active(_ properties: NSDictionary) throws -> Bool {
        guard let level = properties[kIOPMAssertionLevelKey as String] as? NSNumber,
              let type = properties[kIOPMAssertionTypeKey as String] as? String,
              type == (kIOPMAssertionTypePreventUserIdleSystemSleep as String) || type == (kIOPMAssertPreventDiskIdle as String) else {
            throw malformed("Unrecognized assertion properties")
        }
        guard level.intValue == Int(kIOPMAssertionLevelOn) else {
            throw malformed("Assertion still allocated but inactive")
        }
        return true
    }

    private func validate(_ timeout: TimeInterval, operation: PowerOperation) throws {
        guard timeout.isFinite && timeout > 0 else {
            throw PowerBackendFailure(operation: operation, code: kIOReturnBadArgument, detail: "Invalid assertion timeout")
        }
    }
    private func check(_ result: IOReturn, operation: PowerOperation) throws {
        guard result == kIOReturnSuccess else {
            throw PowerBackendFailure(operation: operation, code: result, detail: "macOS power request failed")
        }
    }
    private func malformed(_ message: String) -> PowerBackendFailure {
        PowerBackendFailure(operation: .inspect, code: kIOReturnError, detail: message)
    }
}

import Foundation
import IOKit.ps
import KeepOnlineCore
import Network

/// Event observation only. No packets, disk writes, global power preferences, or daemon.
@MainActor
public final class SystemEnvironmentMonitor {
    public private(set) var current = EnvironmentSnapshot()
    private let onChange: @MainActor @Sendable (EnvironmentSnapshot) -> Void
    private var pathMonitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var thermalObserver: (any NSObjectProtocol)?
    private var started = false

    public init(onChange: @escaping @MainActor @Sendable (EnvironmentSnapshot) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard !started else { return }
        started = true
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // IOPS source is installed exclusively on the main run loop.
            MainActor.assumeIsolated {
                let monitor = Unmanaged<SystemEnvironmentMonitor>.fromOpaque(context).takeUnretainedValue()
                _ = monitor.refresh()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source = powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let availability: NetworkAvailability
            switch path.status {
            case .satisfied: availability = .available
            case .unsatisfied: availability = .unavailable
            case .requiresConnection: availability = .unknown
            @unknown default: availability = .unknown
            }
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.current.network = availability
                self.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "KeepOnline.NetworkPath", qos: .utility))
        refresh()
    }

    public func stop() {
        started = false
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        powerSource = nil
        if let observer = thermalObserver { NotificationCenter.default.removeObserver(observer) }
        thermalObserver = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    @discardableResult public func refresh() -> EnvironmentSnapshot {
        let power = Self.readPower()
        current.powerSource = power.source
        current.batteryPercent = power.percent
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: current.thermal = .nominal
        case .fair: current.thermal = .fair
        case .serious: current.thermal = .serious
        case .critical: current.thermal = .critical
        @unknown default: current.thermal = .unknown
        }
        onChange(current)
        return current
    }

    private static func readPower() -> (source: PowerSource, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (.unknown, nil) }
        let provider = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let source: PowerSource = provider == kIOPSACPowerValue ? .ac : provider == kIOPSBatteryPowerValue ? .battery : .unknown
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (source, nil) }
        for handle in sources {
            guard let description = IOPSGetPowerSourceDescription(info, handle)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0 else { continue }
            let percent = Int((capacity.doubleValue / maximum.doubleValue * 100).rounded())
            return (source, min(100, max(0, percent)))
        }
        return (source, nil)
    }
}

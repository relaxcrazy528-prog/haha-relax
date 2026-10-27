import AppKit
import Combine
import Foundation
import KeepOnlineCore
import KeepOnlinePlatform
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var panel = PanelPresentation()
    @Published var duration: SessionLength = .hour
    @Published var keepDiskActive = false
    var changed: (() -> Void)?

    private let engine = SessionEngine(backend: IOKitPowerBackend())
    private var environmentMonitor: SystemEnvironmentMonitor?
    private var healthTimer: Timer?
    private var displayTimer: Timer?
    private var expiryTimer: Timer?
    private var activity: (any NSObjectProtocol)?
    private var currentSnapshot: SessionSnapshot?
    private var environment = EnvironmentSnapshot()
    private var operationInProgress = false
    private var terminating = false
    private var snapshotQuery: UInt64 = 0
    private var loginEnabled = false
    private var loginNeedsApproval = false
    private var loginError: String?

    var hasResources: Bool {
        guard let currentSnapshot else { return false }
        return !currentSnapshot.granted.isEmpty || !currentSnapshot.unknown.isEmpty
    }

    var isBusy: Bool { operationInProgress }

    func startMonitoring() {
        refreshLoginStatus()
        let monitor = SystemEnvironmentMonitor { [weak self] environment in
            guard let self, !self.terminating else { return }
            self.environment = environment
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.engine.updateEnvironment(environment)
                await self.publishLatest()
            }
        }
        environmentMonitor = monitor
        monitor.start()

    }

    func setPanelVisible(_ visible: Bool) {
        displayTimer?.invalidate()
        displayTimer = nil
        guard visible, !terminating else { return }
        refreshLoginStatus()
        Task { @MainActor [weak self] in await self?.publishLatest() }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // This timer only reads a snapshot. It must never renew a power request.
            Task { @MainActor [weak self] in await self?.publishLatest() }
        }
    }

    func toggleSession() {
        guard !operationInProgress, !terminating else { return }
        let request = SessionRequest(duration: duration.seconds, keepDiskActive: keepDiskActive)
        let shouldStop = hasResources
        operationInProgress = true
        rebuildPanel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if shouldStop {
                let latest = await self.engine.snapshot()
                if let id = latest.sessionID { _ = await self.engine.stop(sessionID: id) }
            } else {
                let environment = self.environmentMonitor?.refresh() ?? self.environment
                _ = await self.engine.updateEnvironment(environment)
                _ = await self.engine.start(request)
            }
            self.operationInProgress = false
            await self.publishLatest()
        }
    }

    func systemWillSleep() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.engine.systemWillSleep()
            await self.publishLatest()
        }
    }

    func systemDidWake() {
        let value = environmentMonitor?.refresh() ?? environment
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.engine.updateEnvironment(value)
            // Read the surviving system resources; never acquire a new session on wake.
            await self.publishLatest()
        }
    }

    func userWillLogout() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.engine.userWillLogout()
            await self.publishLatest()
        }
    }

    func stopForQuit() async -> Bool {
        terminating = true
        operationInProgress = true
        healthTimer?.invalidate()
        displayTimer?.invalidate()
        expiryTimer?.invalidate()
        environmentMonitor?.stop()
        rebuildPanel()
        let latest = await engine.snapshot()
        if let id = latest.sessionID { _ = await engine.stop(sessionID: id) }
        await publishLatest()
        operationInProgress = false
        if hasResources {
            terminating = false
            startMonitoring()
            rebuildPanel()
            return false
        }
        rebuildPanel()
        return true
    }

    func shutdownMonitoring() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        terminating = true
        healthTimer?.invalidate()
        displayTimer?.invalidate()
        expiryTimer?.invalidate()
        environmentMonitor?.stop()
    }

    func setLoginEnabled(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "登录启动设置未完成：\(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
        rebuildPanel()
    }

    private func healthCheck() async {
        guard !terminating else { return }
        let value = environmentMonitor?.refresh() ?? environment
        _ = await engine.updateEnvironment(value)
        let current = await engine.snapshot()
        if let id = current.sessionID { _ = await engine.tick(sessionID: id) }
        await publishLatest()
    }

    private func publishLatest() async {
        snapshotQuery &+= 1
        let query = snapshotQuery
        let snapshot = await engine.snapshot()
        guard query == snapshotQuery else { return }
        currentSnapshot = snapshot
        environment = snapshot.environment
        manageSessionTimers(snapshot)
        rebuildPanel()
    }


    private func manageSessionTimers(_ snapshot: SessionSnapshot) {
        if snapshot.isActive && !terminating {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "User-requested keep-awake session")
            }
            if healthTimer == nil || healthTimer?.isValid == false {
                let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in await self?.healthCheck() }
                }
                RunLoop.main.add(timer, forMode: .common)
                healthTimer = timer
            }
        } else {
            healthTimer?.invalidate()
            healthTimer = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
        expiryTimer?.invalidate()
        expiryTimer = nil
        if snapshot.isActive, !terminating,
           let expires = [snapshot.remainingDuration, snapshot.remainingLease].compactMap({ $0 }).min() {
            let timer = Timer(timeInterval: max(0.05, expires + 0.05), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.publishLatest() }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
        }
    }

    private func rebuildPanel() {
        var result = PanelPresentation()
        result.loginEnabled = loginEnabled
        result.loginNeedsApproval = loginNeedsApproval
        result.loginError = loginError
        result.busy = operationInProgress
        result.hasResources = hasResources

        if let snapshot = currentSnapshot {
            result.running = snapshot.isActive
            switch snapshot.phase {
            case .idle:
                result.status = "已关闭"
            case .active:
                result.appearance = .active
                result.status = "保持中"
                result.headline = "保持唤醒，任务继续。"
                result.detail = "屏幕可以熄灭。合盖、手动睡眠和系统电源策略仍然有效。"
                if let seconds = snapshot.remainingDuration {
                    let total = max(0, Int(ceil(seconds)))
                    result.remaining = String(format: "剩余 %02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
                } else {
                    result.remaining = "直到手动结束"
                }
            case .acquiring, .releasing:
                result.appearance = .attention
                result.status = "正在处理"
                result.busy = true
            case .failed, .unknown:
                result.appearance = .attention
                result.status = snapshot.unknown.isEmpty ? "需要注意" : "状态待确认"
                result.headline = snapshot.unknown.isEmpty ? "会话已停止。" : "请确认防休眠状态。"
                result.remaining = "查看下方说明"
            }

            if operationInProgress {
                result.appearance = .attention
                result.status = "正在处理"
            }

            result.note = note(for: snapshot.endReason)
            if let failure = snapshot.failureDescription {
                result.note = "操作未能完整完成，请查看帮助与诊断。若仍有防休眠请求，可再次点击结束。"
                result.diagnostic = "状态：\(snapshot.phase.rawValue)\n\(failure)"
            } else {
                let kinds = snapshot.granted.map(\.rawValue).sorted().joined(separator: ", ")
                let lease = snapshot.remainingLease.map { String(format: "%.1f 秒", max(0, $0)) } ?? "无"
                result.diagnostic = "状态：\(snapshot.phase.rawValue)\n请求：\(kinds.isEmpty ? "无" : kinds)\n系统有效期剩余：\(lease)\n合盖：未验证，当前不可用"
            }
        }

        switch environment.powerSource {
        case .ac:
            result.power = environment.batteryPercent.map { "外接电源 · \($0)%" } ?? "外接电源"
            result.powerIcon = "powerplug.fill"
        case .battery:
            result.power = environment.batteryPercent.map { "电池供电 · \($0)%" } ?? "电池供电"
            result.powerIcon = (environment.batteryPercent ?? 100) <= 20 ? "battery.25percent" : "battery.75percent"
        case .unknown:
            result.power = "电源信息不可用"
            result.powerIcon = "battery.0percent"
        }

        switch environment.network {
        case .available: result.network = "网络路径可用"; result.networkIcon = "network"
        case .unavailable: result.network = "网络路径不可用"; result.networkIcon = "wifi.slash"
        case .unknown: result.network = "网络路径待确认"; result.networkIcon = "questionmark.circle"
        }

        switch environment.thermal {
        case .nominal: result.thermal = "热压力正常"
        case .fair: result.thermal = "热压力轻微"
        case .serious: result.thermal = "热压力偏高"; result.thermalWarning = true
        case .critical: result.thermal = "热压力极高"; result.thermalWarning = true
        case .unknown: result.thermal = "热状态不可用"
        }
        if environment.thermal == .serious, result.running {
            result.note = "系统热压力偏高，请减少负载并保持通风。"
        }
        if operationInProgress {
            result.appearance = .attention
            result.status = "正在处理"
        }
        panel = result
        changed?()
    }

    private func note(for reason: SessionEndReason?) -> String? {
        switch reason {
        case .none, .userStopped: nil
        case .durationElapsed: "设定时长已结束。"
        case .leaseExpired: "会话已到期停止。需要继续时，请重新开始。"
        case .renewalFailed: "未能继续保持唤醒，会话已停止。请重新开始。"
        case .acquisitionFailed: "系统未能开启防休眠，请稍后重试。"
        case .cleanupFailed: "结束时未能确认所有请求已释放，请再次点击结束。"
        case .lowBattery: "电池电量已降至 20%，防休眠已停止。"
        case .thermalCritical: "系统热压力极高，防休眠已停止。"
        case .systemSleep: "Mac 已进入睡眠。唤醒后需要手动重新开始。"
        case .logout: "用户会话正在结束，防休眠已停止。"
        case .lidNotValidated: "合盖能力尚未验证，当前不可用。"
        case .invalidRequest: "无法使用此会话设置，请重新选择。"
        }
    }
}

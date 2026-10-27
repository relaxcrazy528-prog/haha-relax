import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var observers: [any NSObjectProtocol] = []
    private var quitting = false
    private var smokeStagesPassed = false
    private var terminationApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [])
            exit(0)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: LivePanel(model: model, quit: { [weak self] in self?.requestQuit() }))
        model.changed = { [weak self] in self?.refreshIndicator() }
        refreshIndicator()
        observeWorkspace()
        model.startMonitoring()
        if CommandLine.arguments.contains("--smoke-test") {
            Task { @MainActor in await runSmokeTest() }
        }
    }

    private func runSmokeTest() async {
        // Internal fixture exercising the actual model, backend, indicator, and graceful quit.
        model.toggleSession()
        for _ in 0..<60 {
            if model.panel.running && !model.isBusy { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let started = model.panel.running && model.hasResources && model.panel.appearance == .active
        if started { model.toggleSession() }
        for _ in 0..<60 {
            if !model.hasResources && !model.isBusy { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let stopped = !model.hasResources && !model.isBusy && model.panel.appearance == .inactive
        smokeStagesPassed = started && stopped
        if !smokeStagesPassed {
            FileHandle.standardOutput.write(Data("SMOKE_FAIL: \(model.panel.diagnostic)\n".utf8))
        }
        requestQuit()
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.systemWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.systemDidWake() }
        })
        for name in [NSWorkspace.willPowerOffNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.userWillLogout() }
            })
        }
    }

    private func refreshIndicator() {
        guard let button = statusItem?.button else { return }
        let state = model.panel
        let color = state.appearance.nsColor
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor.white.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 10, y: 9.3), radius: 4.3, startAngle: 135, endAngle: 405)
            arc.lineWidth = 1.7
            arc.lineCapStyle = .round
            arc.stroke()
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 10, y: 14.5))
            stem.line(to: NSPoint(x: 10, y: 9.8))
            stem.lineWidth = 1.7
            stem.lineCapStyle = .round
            stem.stroke()
            return true
        }
        image.isTemplate = false
        button.image = image
        button.attributedTitle = NSAttributedString(string: " " + state.status, attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ])
        button.toolTip = "保持在线 · \(state.status)"
        button.setAccessibilityLabel("保持在线，\(state.status)，点击打开控制面板")
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }
    private func showPanel() {
        guard let button = statusItem?.button else { return }
        model.setPanelVisible(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { model.setPanelVisible(false) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }
    private func requestQuit() {
        guard !quitting, !model.isBusy else { return }
        quitting = true
        Task { @MainActor in
            let stopped = await model.stopForQuit()
            if stopped {
                terminationApproved = true
                NSApp.terminate(nil)
            } else {
                showCleanupWarning()
                quitting = false
            }
        }
    }
    private func showCleanupWarning() {
        let alert = NSAlert()
        alert.messageText = "尚未确认所有防休眠请求已释放"
        alert.informativeText = "应用会保留运行。请在面板中再次点击结束；系统请求也有自动到期期限。"
        alert.runModal()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        guard !quitting, !model.isBusy else { return .terminateCancel }
        quitting = true
        Task { @MainActor in
            let stopped = await model.stopForQuit()
            if !stopped {
                showCleanupWarning()
                quitting = false
            }
            NSApp.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdownMonitoring()
        if CommandLine.arguments.contains("--smoke-test"), smokeStagesPassed {
            FileHandle.standardOutput.write(Data("SMOKE_PASS: startup, active indicator, release, idle indicator, graceful quit\n".utf8))
        }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

private struct LivePanel: View {
    @ObservedObject var model: AppModel
    let quit: () -> Void
    var body: some View {
        PanelView(state: model.panel, duration: $model.duration, keepDiskActive: $model.keepDiskActive,
                  toggle: model.toggleSession, setLogin: model.setLoginEnabled,
                  openLoginSettings: model.openLoginSettings, quit: quit)
    }
}

@main
@MainActor
enum KeepOnlineApplication {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Developer-only rendering fixture: no engine, monitor, assertions, or status item.
        if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.indices.contains(index + 1) {
            renderPreview(path: CommandLine.arguments[index + 1])
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func renderPreview(path: String) {
        let appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        var state = PanelPresentation()
        state.power = "外接电源 · 83%"
        state.powerIcon = "powerplug.fill"
        state.thermal = "热压力正常"
        state.network = "网络路径可用"
        if !CommandLine.arguments.contains("--inactive") {
            state.appearance = .active
            state.status = "保持中"
            state.running = true
            state.hasResources = true
            state.headline = "保持唤醒，任务继续。"
            state.remaining = "剩余 00:58:24"
            state.detail = "屏幕可以熄灭。合盖、手动睡眠和系统电源策略仍然有效。"
        }
        let root = PanelView(state: state, duration: .constant(.hour), keepDiskActive: .constant(false),
                             toggle: {}, setLogin: { _ in }, openLoginSettings: {}, quit: {})
        let view = NSHostingView(rootView: root)
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch { FileHandle.standardError.write(Data("Preview failed: \(error)\n".utf8)); exit(1) }
    }
}

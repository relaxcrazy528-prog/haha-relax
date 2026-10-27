import AppKit
import SwiftUI

// Standalone desktop fixture, compiled with the production panel and sizing
// policy. It never imports the power engine or changes login/system settings.
@main
@MainActor
enum PanelLayoutProbe {
    final class Fixture: ObservableObject {
        @Published var options = false
        @Published var help = false
        let state: PanelPresentation
        init(state: PanelPresentation) { self.state = state }
    }

    struct FixturePanel: View {
        @ObservedObject var fixture: Fixture
        let size: NSSize
        var body: some View {
            PanelView(state: fixture.state, viewportSize: size, duration: .constant(.hour),
                      keepDiskActive: .constant(false), showOptions: $fixture.options, showHelp: $fixture.help,
                      toggle: {}, setLogin: { _ in }, openLoginSettings: {}, quit: {})
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func settle() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    static func scroll(_ view: NSScrollView, toEnd: Bool) {
        guard let document = view.documentView else { return }
        let low = document.bounds.minY
        let high = max(low, document.bounds.maxY - view.contentView.bounds.height)
        let y = toEnd == document.isFlipped ? high : low
        view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX, y: y))
        view.reflectScrolledClipView(view.contentView)
        settle()
    }

    static func capture(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure(description: "Could not capture panel")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            do { try run(); exit(0) }
            catch { print("LAYOUT_FAIL: \(error)"); exit(1) }
        }
        app.run()
    }

    static func run() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // Include a small usable area and displays above/left of the primary.
        for screen in [NSRect(x: 0, y: 48, width: 800, height: 528),
                       NSRect(x: 0, y: 80, width: 1440, height: 796),
                       NSRect(x: -1920, y: 120, width: 1920, height: 1056),
                       NSRect(x: 0, y: -900, width: 1200, height: 840)] {
            let anchor = NSRect(x: screen.midX, y: screen.maxY, width: 24, height: 24)
            let size = PanelLayout.contentSize(visibleFrame: screen, anchor: anchor)
            try require(size.width <= screen.width - 24 && size.height <= screen.height - 24,
                        "Viewport exceeds usable area")
        }

        // A dedicated top-edge anchor makes the check independent of whether
        // the user's menu bar has room for another temporary status item.
        guard let screen = NSScreen.main else { throw Failure(description: "No desktop screen") }
        let anchorWindow = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY,
                                                        width: 100, height: 24),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        defer { anchorWindow.close() }
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        button.title = "布局检查"
        anchorWindow.contentView = button
        anchorWindow.orderFrontRegardless()
        settle()
        let normal = PanelLayout.contentSize(for: button)
        var results: [[String: Any]] = []

        for (name, size) in [("normal", normal),
                             ("compact", NSSize(width: normal.width, height: min(360, normal.height))),
                             ("narrow", NSSize(width: min(320, normal.width), height: min(440, normal.height)))] {
            var state = PanelPresentation()
            state.power = "外接电源 · 83%"
            state.thermal = "热压力正常"
            state.network = "网络路径可用"
            state.diagnostic = String(repeating: "布局验证：请求未启动，合盖功能不可用。\n", count: 8)
            let fixture = Fixture(state: state)
            let controller = NSHostingController(rootView: FixturePanel(fixture: fixture, size: size))
            var expectedSize = size
            let popover = NSPopover()
            popover.animates = false
            PanelLayout.apply(size, to: controller, popover: popover)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: PanelLayout.preferredEdge(for: button))
            settle()
            guard let window = controller.view.window, let scroll = scrollView(in: controller.view) else {
                throw Failure(description: "Missing popover window or native scroll view")
            }
            func checkBounds() throws {
                let frame = window.convertToScreen(controller.view.convert(controller.view.bounds, to: nil))
                try require(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(frame), "\(name) panel outside usable screen: \(frame)")
                try require(abs(controller.view.frame.width - expectedSize.width) < 1 && abs(controller.view.frame.height - expectedSize.height) < 1,
                            "\(name) viewport changed size")
                try require(screen.frame.insetBy(dx: -1, dy: -1).contains(window.frame), "\(name) popover outside physical screen")
            }
            try checkBounds()
            try capture(controller.view, to: output.appendingPathComponent(name + ".png"))
            fixture.options = true
            settle()
            try checkBounds()
            fixture.help = true
            settle()
            try checkBounds()
            try require(scroll.documentView!.bounds.height > scroll.contentView.bounds.height,
                        "Expanded content is not scrollable")
            self.scroll(scroll, toEnd: false)
            let start = scroll.contentView.bounds.origin
            try capture(controller.view, to: output.appendingPathComponent(name + "-expanded-top.png"))
            self.scroll(scroll, toEnd: true)
            try require(abs(scroll.contentView.bounds.origin.y - start.y) > 1, "Cannot scroll to expanded content")
            try capture(controller.view, to: output.appendingPathComponent(name + "-expanded-bottom.png"))
            expectedSize.height = min(300, size.height)
            controller.rootView = FixturePanel(fixture: fixture, size: expectedSize)
            PanelLayout.apply(expectedSize, to: controller, popover: popover)
            settle()
            try checkBounds()
            results.append(["case": name, "width": size.width, "height": size.height,
                            "expansion_keeps_viewport": true, "content_scrolls": true, "inside_screen": true,
                            "resize_while_open": true])
            popover.close()
            settle()
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("results.json"))
        print("LAYOUT_PASS: 4 screen geometries; 3 native popover sizes; live expansion; scrolling; resize while open")
    }
}

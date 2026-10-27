import AppKit
import SwiftUI

enum PanelLayout {
    static let preferredSize = NSSize(width: 382, height: 560)

    static func contentSize(visibleFrame: NSRect, anchor: NSRect) -> NSSize {
        // Reserve room for the popover's arrow, border, and a gap above the Dock.
        // AppKit coordinates are points; Retina scale must not be applied here.
        let availableHeight = min(visibleFrame.maxY, anchor.minY) - visibleFrame.minY - 24
        return NSSize(width: max(1, min(preferredSize.width, visibleFrame.width - 24)),
                      height: max(1, min(preferredSize.height, availableHeight)))
    }

    @MainActor
    static func contentSize(for button: NSView) -> NSSize {
        guard let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return preferredSize }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        return contentSize(visibleFrame: screen.visibleFrame, anchor: anchor)
    }

    @MainActor
    static func preferredEdge(for button: NSView) -> NSRectEdge {
        button.isFlipped ? .maxY : .minY
    }

    @MainActor
    static func apply<Content: View>(_ size: NSSize, to controller: NSHostingController<Content>,
                                     popover: NSPopover) {
        // The screen owns the viewport size. Expanding SwiftUI content must not
        // increase the popover's preferred/minimum height beyond that viewport.
        controller.sizingOptions = []
        controller.preferredContentSize = size
        controller.view.setFrameSize(size)
        if popover.contentViewController !== controller { popover.contentViewController = controller }
        popover.contentSize = size
    }
}

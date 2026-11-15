import AppKit

extension NSWindow {
    /// Maximize to the screen's visibleFrame (full monitor minus menu bar & Dock, never Spaces fullscreen).
    func maximizeToVisibleFrame() {
        let targetScreen = self.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = targetScreen?.visibleFrame else { return }
        setFrame(visible, display: true)
    }

    /// Place a secondary window at ~75% of the anchor window's monitor, centered over the anchor window,
    /// sharing one persisted frame size/position across all secondary windows.
    func placeOver(_ anchor: NSWindow?, defaultRatio: CGFloat = 0.75, minSize: NSSize = NSSize(width: 1100, height: 720)) {
        let targetScreen = anchor?.screen ?? self.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = targetScreen?.visibleFrame else { return }

        var targetSize = NSSize(
            width: max(minSize.width, floor(visible.width * defaultRatio)),
            height: max(minSize.height, floor(visible.height * defaultRatio))
        )
        if let savedStr = SharedStore.shared.secondaryWindowFrame {
            let savedRect = NSRectFromString(savedStr)
            if savedRect.width >= minSize.width && savedRect.height >= minSize.height {
                targetSize = NSSize(
                    width: min(savedRect.width, visible.width),
                    height: min(savedRect.height, visible.height)
                )
            }
        }

        let anchorFrame = anchor?.frame ?? visible
        var x = anchorFrame.midX - targetSize.width / 2
        var y = anchorFrame.midY - targetSize.height / 2

        // Clamp cleanly inside the target monitor's visibleFrame
        x = max(visible.minX, min(x, visible.maxX - targetSize.width))
        y = max(visible.minY, min(y, visible.maxY - targetSize.height))

        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: targetSize), display: true)
    }
}

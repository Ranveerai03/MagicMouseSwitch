@preconcurrency import AppKit

@MainActor
final class StatusPopup {
    private let panel: NSPanel
    private let label: NSTextField
    private var dismissal: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14

        label = NSTextField(labelWithString: "")
        label.frame = effect.bounds.insetBy(dx: 18, dy: 18)
        label.autoresizingMask = [.width, .height]
        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        effect.addSubview(label)
        panel.contentView = effect
    }

    func show(_ text: String, dismissAfter seconds: TimeInterval? = nil) {
        precondition(Thread.isMainThread)
        dismissal?.cancel()
        label.stringValue = text
        positionAtBottomCenter()
        panel.orderFrontRegardless()
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        precondition(Thread.isMainThread)
        dismissal?.cancel()
        panel.orderOut(nil)
    }

    private func positionAtBottomCenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + 28
        )
        panel.setFrameOrigin(origin)
    }
}

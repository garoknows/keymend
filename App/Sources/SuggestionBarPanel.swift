import AppKit
import KeymendCore

/// A panel that can never take focus, so clicking it leaves the user in the app they're typing in.
private final class NonFocusingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A button that works on the first click, even though its window is never active.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating bar. It sits at the bottom center of the front window, because Keymend can't read
/// the text cursor's position inside the App Sandbox. It holds the word only while it's showing.
@MainActor
final class SuggestionBarPanel: NSObject {
    private let panel: NonFocusingPanel
    private let stack = NSStackView()
    private var bar: SuggestionBar?
    private var windowBounds: CGRect?
    private let onPick: (Int, UInt64) -> Void
    /// Tells the bridge where the bar is, so a click on it isn't treated as a click elsewhere.
    private let onFrameChange: (CGRect?) -> Void

    init(onPick: @escaping (Int, UInt64) -> Void, onFrameChange: @escaping (CGRect?) -> Void) {
        self.onPick = onPick
        self.onFrameChange = onFrameChange
        panel = NonFocusingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    /// Shows or updates the bar, or hides it for nil.
    func show(_ newBar: SuggestionBar?, frontApp: pid_t?) {
        let wasHidden = bar == nil
        bar = newBar
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let newBar else {
            panel.orderOut(nil)
            windowBounds = nil
            onFrameChange(nil)
            return
        }
        if wasHidden { windowBounds = frontApp.flatMap(Self.frontWindowBounds) }
        let choices = ["\u{201C}\(newBar.typed)\u{201D}"] + newBar.completions
        for (slot, title) in choices.enumerated() {
            stack.addArrangedSubview(button(title: title, slot: slot))
        }
        let size = stack.fittingSize
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = BarPlacement.origin(
            barSize: size, window: windowBounds, primaryHeight: primaryHeight,
            screens: Self.screensMainFirst
        )
        let frame = NSRect(origin: origin, size: size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        onFrameChange(BarPlacement.flip(frame, primaryHeight: primaryHeight))
    }

    private func button(title: String, slot: Int) -> NSButton {
        let label = NSMutableAttributedString(
            string: "\(slot + 1) ",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
        )
        label.append(NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 14)]
        ))
        let b = FirstClickButton(title: "", target: self, action: #selector(picked(_:)))
        b.attributedTitle = label
        b.isBordered = false
        b.refusesFirstResponder = true
        b.tag = slot
        return b
    }

    @objc private func picked(_ sender: NSButton) {
        if let bar { onPick(sender.tag, bar.generation) }
    }

    private static var screensMainFirst: [CGRect] {
        let main = NSScreen.main.map { [$0.visibleFrame] } ?? []
        return main + NSScreen.screens.map(\.visibleFrame)
    }

    /// The front window's position and size. It doesn't need Screen Recording, and window titles
    /// and contents are never read.
    private static func frontWindowBounds(of pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let info = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: info as CFDictionary),
                  bounds.width >= 200, bounds.height >= 100 else { continue }
            return bounds
        }
        return nil
    }
}

import AppKit

struct ToastMessage: Equatable {
    let title: String
    let symbol: String

    static func copied() -> ToastMessage {
        ToastMessage(title: "コピーしました", symbol: "checkmark.circle.fill")
    }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A single nonactivating HUD follows the system appearance and expires without stealing focus.
final class ToastPresenter {
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    static func content(_ message: ToastMessage) -> NSVisualEffectView {
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: message.symbol, accessibilityDescription: nil)
        icon.contentTintColor = message.symbol == "checkmark.circle.fill" ? .systemGreen : .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let title = NSTextField(wrappingLabelWithString: message.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        let lines = NSStackView(views: [title])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 4
        let row = NSStackView(views: [icon, lines])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: material.centerYAnchor)
        ])
        return material
    }

    func show(_ message: ToastMessage) {
        hide()
        let panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 54),
                               styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = Self.content(message)
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 350, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        let task = DispatchWorkItem { [weak self, weak panel] in
            guard let self, self.panel === panel else { return }
            self.hide()
        }
        dismissal = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: task)
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel?.close()
        panel = nil
    }

    deinit { dismissal?.cancel() }
}

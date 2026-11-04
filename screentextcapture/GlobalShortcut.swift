import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let defaultShortcut = Shortcut(keyCode: 17, modifiers: UInt32(cmdKey | optionKey | shiftKey), label: "⇧⌥⌘T")

    static func from(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // charactersIgnoringModifiersは⇧だけは適用するため、⇧⌘6が「⇧⌘^」と⇧を二重に表す表示になっていた。
        // 修飾なしの文字を使い、押したキーそのものを記録する。
        guard flags.contains(.command) || flags.contains(.control),
              event.keyCode != 53, let key = event.characters(byApplyingModifiers: []), !key.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: symbols(for: modifiers) + key.uppercased())
    }

    /// macOSのメニューと同じ⌃⌥⇧⌘の順で修飾キーを並べる
    static func symbols(for modifiers: UInt32) -> String {
        var label = ""
        if modifiers & UInt32(controlKey) != 0 { label += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { label += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { label += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { label += "⌘" }
        return label
    }

    /// 保存済みのlabelは旧版の記録方法や記録時のキー配列に依存するため、表示はキーコードから現在の配列で作り直す。
    /// 文字にならないキー（Return・F1など）や配列情報を取れない場合だけ、保存済みのキー表記を使う。
    var displayLabel: String {
        let storedKey = String(label.drop(while: { "⌃⌥⇧⌘".contains($0) }))
        return Self.symbols(for: modifiers) + (Self.keyName(for: keyCode) ?? storedKey)
    }

    private static func keyName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { buffer -> OSStatus in
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(pointer, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let name = String(utf16CodeUnits: characters, count: length)
        let printable = name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespaces.contains($0) }
        return printable ? name.uppercased() : nil
    }
}

enum ShortcutError: LocalizedError {
    case registration(OSStatus)
    var errorDescription: String? {
        switch self {
        case .registration(let code): return "ショートカットを登録できません（\(code)）。他のアプリで使用中か、macOSが予約しています。別のキーを選んでください。"
        }
    }
}

final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let identifier = EventHotKeyID(signature: 0x53544350, id: UInt32.random(in: 1...UInt32.max))
    private(set) var registered: Shortcut?
    var action: (() -> Void)?
    var suspended = false

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == owner.identifier.signature, identifier.id == owner.identifier.id else {
                return OSStatus(eventNotHandledErr)
            }
            if !owner.suspended { owner.action?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Register the candidate before dropping the previous hotkey, so conflicts preserve the old binding.
    func register(_ shortcut: Shortcut?) throws {
        if shortcut == registered { return }
        if let shortcut, let registered, shortcut.keyCode == registered.keyCode, shortcut.modifiers == registered.modifiers {
            self.registered = shortcut
            return
        }
        guard let shortcut else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            registered = nil
            return
        }
        guard handler != nil else { throw ShortcutError.registration(OSStatus(eventNotHandledErr)) }
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, candidate != nil else { throw ShortcutError.registration(status) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate
        registered = shortcut
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

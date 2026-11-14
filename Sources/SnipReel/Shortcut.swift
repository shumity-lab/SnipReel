import AppKit
import Carbon

/// グローバルショートカットで起動する操作
enum HotKeyAction: UInt32, CaseIterable {
    case capture = 1
    case record = 2

    var defaultsKey: String {
        switch self {
        case .capture: return "captureShortcut"
        case .record: return "recordShortcut"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .capture:
            return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        case .record:
            return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: NSEvent.ModifierFlags([.command, .shift, .option]).rawValue)
        }
    }
}

/// グローバルショートカットの定義
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags の rawValue(⌘⇧⌥⌃ のみ)
    var modifiers: UInt


    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        let f = modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var displayString: String {
        let f = modifierFlags
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + Shortcut.keyName(for: keyCode)
    }

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    // MARK: 保存

    static func load(for action: HotKeyAction) -> Shortcut {
        if let data = UserDefaults.standard.data(forKey: action.defaultsKey),
           let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
            return s
        }
        return action.defaultShortcut
    }

    func save(for action: HotKeyAction) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
    }

    // MARK: キー名

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeyNames[Int(keyCode)] != nil
    }

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    static func keyName(for keyCode: UInt32) -> String {
        if let n = functionKeyNames[Int(keyCode)] ?? specialKeyNames[Int(keyCode)] { return n }
        if let c = translate(keyCode), !c.isEmpty { return c.uppercased() }
        return "Key\(keyCode)"
    }

    /// 現在のキーボードレイアウトで、修飾キーなしの文字に変換する
    private static func translate(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, chars.count, &length, &chars)
            guard status == noErr else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

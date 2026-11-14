import AppKit
import Carbon

/// Carbon の RegisterEventHotKey を使ったグローバルホットキー(アクセシビリティ権限不要)
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onPressed: ((HotKeyAction) -> Void)?
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private static let signature = OSType(0x534E_5250) // 'SNRP'

    @discardableResult
    func register(_ shortcut: Shortcut, for action: HotKeyAction) -> Bool {
        unregister(action)
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: HotKeyManager.signature, id: action.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[action] = ref
        return true
    }

    func unregister(_ action: HotKeyAction) {
        if let ref = refs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    func unregisterAll() {
        for action in HotKeyAction.allCases { unregister(action) }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr, hkID.signature == HotKeyManager.signature,
                  let action = HotKeyAction(rawValue: hkID.id) else { return noErr }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyManager.shared.onPressed?(action) }
            }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

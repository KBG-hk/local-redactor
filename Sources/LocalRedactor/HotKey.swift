import AppKit
import Carbon.HIToolbox

struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let title: String

    static let defaultValue = Shortcut(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(controlKey | optionKey | cmdKey), title: "⌃⌥⌘S"
    )

    static let smokeTestValue = Shortcut(
        keyCode: UInt32(kVK_F19),
        modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), title: "⌃⌥⇧⌘F19"
    )

    var settings: [String: Any] { ["key": Int(keyCode), "modifiers": Int(modifiers), "title": title] }

    init(keyCode: UInt32, modifiers: UInt32, title: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.title = title
    }

    init?(settings: [String: Any]?) {
        guard let key = settings?["key"] as? Int,
              let modifiers = settings?["modifiers"] as? Int,
              let title = settings?["title"] as? String,
              let code = UInt32(exactly: key), let flags = UInt32(exactly: modifiers) else { return nil }
        self.init(keyCode: code, modifiers: flags, title: title)
    }

    @MainActor
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers: [(NSEvent.ModifierFlags, Int, String)] = [
            (.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘"),
        ]
        let active = modifiers.filter { flags.contains($0.0) }
        guard active.count >= 2, flags.contains(.command) || flags.contains(.control),
              event.keyCode != UInt16(kVK_Escape), event.keyCode != UInt16(kVK_Return),
              event.keyCode != UInt16(kVK_Tab),
              let key = event.characters(byApplyingModifiers: [])?.uppercased(),
              key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
              (33...126).contains(scalar.value) else { return nil }
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: UInt32(active.reduce(0) { $0 | $1.1 }),
            title: active.map(\.2).joined() + key
        )
    }
}

@MainActor
final class HotKey {
    private var eventHandler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        if eventHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(), handleHotKey, 1, &event,
                Unmanaged.passUnretained(self).toOpaque(), &eventHandler
            )
            guard status == noErr else { return false }
        }
        let id = EventHotKeyID(signature: 0x52454441, id: 1)
        return RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &registration
        ) == noErr
    }

    func unregister() {
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
    }

    func removeHandler() {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    fileprivate func fire() { action() }
}

private func handleHotKey(
    _ handler: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr, id.signature == 0x52454441, id.id == 1 else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}

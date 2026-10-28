import Carbon
import AppKit

/// A registered hotkey, not a keyboard event tap: no input monitoring permission required.
@MainActor final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var localMonitor: Any?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    func register(_ choice: String) -> OSStatus {
        stop()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x43515836, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.action?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return installed }
        let key = choice == "ctrl-semicolon" ? kVK_ANSI_Semicolon : (choice == "x" ? kVK_ANSI_X : kVK_Space)
        let modifiers = choice == "ctrl-semicolon" ? controlKey : optionKey
        let flags: NSEvent.ModifierFlags = choice == "ctrl-semicolon" ? .control : .option
        let result = RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x43515836, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { stop() } else {
            // App-targeted events (including accessibility tools) do not pass the system hotkey dispatcher.
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == UInt16(key), event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == flags else { return event }
                if !event.isARepeat { MainActor.assumeIsolated { self?.action?() } }
                return nil
            }
        }
        return result
    }
    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

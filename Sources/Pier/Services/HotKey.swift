import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon hot keys need no Accessibility permission.
final class HotKey {
    private var reference: EventHotKeyRef?
    private let action: () -> Void
    private static var handlers: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        Self.installEventHandler()

        let id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5049_4552) /* 'PIER' */, id: id)
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference) == noErr {
            Self.handlers[id] = self
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
    }

    private static func installEventHandler() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.handlers[hotKeyID.id]?.action()
            return noErr
        }, 1, &eventType, nil, nil)
    }
}

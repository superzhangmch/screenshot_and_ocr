import AppKit
import Carbon.HIToolbox

final class GlobalHotKey {
    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let shift   = Modifiers(rawValue: UInt32(shiftKey))
        static let option  = Modifiers(rawValue: UInt32(optionKey))
        static let control = Modifiers(rawValue: UInt32(controlKey))
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32

    private static var nextID: UInt32 = 1
    private static var registry: [UInt32: GlobalHotKey] = [:]

    init(keyCode: UInt32, modifiers: Modifiers, action: @escaping () -> Void) {
        self.action = action
        self.id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        GlobalHotKey.registry[self.id] = self

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout.size(ofValue: hkID), nil, &hkID)
            if let hk = GlobalHotKey.registry[hkID.id] {
                DispatchQueue.main.async { hk.action() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let hkID = EventHotKeyID(signature: OSType(0x534E4F43), id: self.id)
        RegisterEventHotKey(keyCode, modifiers.rawValue, hkID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
        GlobalHotKey.registry.removeValue(forKey: id)
    }
}

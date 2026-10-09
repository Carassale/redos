import Carbon.HIToolbox

/// System-wide shortcuts via Carbon hot keys (no Input Monitoring permission), with press and release events.
@MainActor
final class HotKeyCenter {
    struct Handlers {
        let onPress: @MainActor () -> Void
        let onRelease: (@MainActor () -> Void)?
    }

    static let shared = HotKeyCenter()
    private static let signature = OSType(0x5244_4F53) // "RDOS"

    private var handlers: [UInt32: Handlers] = [:]
    private var hotKeys: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    private init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let id = hotKeyID.id
                // assumeIsolated crashed here once (executor check from a Carbon callback): hop explicitly.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { HotKeyCenter.shared.dispatch(id: id, isPress: isPress) }
                }
                return noErr
            },
            eventTypes.count, &eventTypes, nil, &handlerRef
        )
    }

    func register(
        keyCode: Int, modifiers: Int,
        onPress: @escaping @MainActor () -> Void,
        onRelease: (@MainActor () -> Void)? = nil
    ) {
        let id = UInt32(handlers.count + 1)
        handlers[id] = Handlers(onPress: onPress, onRelease: onRelease)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        if let ref { hotKeys.append(ref) }
    }

    private func dispatch(id: UInt32, isPress: Bool) {
        guard let handler = handlers[id] else { return }
        if isPress {
            handler.onPress()
        } else {
            handler.onRelease?()
        }
    }
}

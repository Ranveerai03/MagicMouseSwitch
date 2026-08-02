import Carbon
import Foundation

final class GlobalHotKey: @unchecked Sendable {
    private static let signature: OSType = 0x4D4D5357 // MMSW
    private let handler: @Sendable () -> Void
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }

    func register() -> OSStatus {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let instance = Unmanaged<GlobalHotKey>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                instance.handler()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )
        guard installStatus == noErr else { return installStatus }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        return RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(controlKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
    }
}

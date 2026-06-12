import Carbon
import Foundation

@MainActor
final class GlobalHotKeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    init() {
        installEventHandler()
    }

    func register(_ hotKey: HotKey?, action: @escaping () -> Void) {
        self.action = action

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        guard let hotKey else { return }

        let hotKeyID = EventHotKeyID(signature: fourCharacterCode("SwBr"), id: 1)
        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        if status == noErr {
            hotKeyRef = registeredHotKey
        }
    }

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                controller.action?()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    private func fourCharacterCode(_ string: String) -> UInt32 {
        string.utf8.reduce(UInt32(0)) { result, character in
            (result << 8) + UInt32(character)
        }
    }
}

import AppKit
import Carbon
import EasyFindCore

struct HotkeyPreset {
    let id: String
    let symbolTitle: String
    let key: String
    let modifiers: [String]

    func title(_ strings: Strings) -> String {
        id == "command-g" ? strings.hotkeyCommandG : symbolTitle
    }
}

struct HotkeySettings: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let title: String

    static let fallback = HotkeySettings(
        keyCode: UInt32(kVK_ANSI_G),
        modifiers: UInt32(cmdKey),
        title: "⌘G"
    )

    static func from(_ config: HotkeyConfig) -> HotkeySettings? {
        let key = config.key.lowercased()
        guard let keyCode = keyCodes[key] else { return nil }

        var flags: UInt32 = 0
        for modifier in config.modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "command", "cmd": flags |= UInt32(cmdKey)
            case "option", "alt": flags |= UInt32(optionKey)
            case "control", "ctrl": flags |= UInt32(controlKey)
            case "shift": flags |= UInt32(shiftKey)
            default: break
            }
        }
        if flags == 0 {
            flags = UInt32(cmdKey)
        }
        return HotkeySettings(keyCode: keyCode, modifiers: flags, title: title(for: key, modifiers: flags))
    }

    static let presets: [HotkeyPreset] = [
        HotkeyPreset(id: "command-g", symbolTitle: "⌘G", key: "g", modifiers: ["command"]),
        HotkeyPreset(id: "option-space", symbolTitle: "⌥Space", key: "space", modifiers: ["option"]),
        HotkeyPreset(id: "control-space", symbolTitle: "⌃Space", key: "space", modifiers: ["control"]),
        HotkeyPreset(id: "command-option-space", symbolTitle: "⌘⌥Space", key: "space", modifiers: ["command", "option"])
    ]

    static func matches(_ preset: HotkeyPreset, config: HotkeyConfig) -> Bool {
        config.key.lowercased() == preset.key.lowercased()
            && Set(config.modifiers.map { $0.lowercased() }) == Set(preset.modifiers.map { $0.lowercased() })
    }

    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
        "space": UInt32(kVK_Space),
        "return": UInt32(kVK_Return),
        "tab": UInt32(kVK_Tab),
        "escape": UInt32(kVK_Escape),
        "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal),
        "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket),
        ";": UInt32(kVK_ANSI_Semicolon), "'": UInt32(kVK_ANSI_Quote),
        ",": UInt32(kVK_ANSI_Comma), ".": UInt32(kVK_ANSI_Period),
        "/": UInt32(kVK_ANSI_Slash), "\\": UInt32(kVK_ANSI_Backslash),
        "`": UInt32(kVK_ANSI_Grave)
    ]

    private static func title(for key: String, modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyDisplay(key)
    }

    private static func keyDisplay(_ key: String) -> String {
        switch key {
        case "space": return "Space"
        case "return": return "↩"
        case "tab": return "⇥"
        case "escape": return "⎋"
        default: return key.uppercased()
        }
    }
}

final class HotkeyManager {
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4546494E // 'EFIN'

    func register(settings: HotkeySettings) {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.onPress?()
            }
            return noErr
        }
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        if installStatus != noErr {
            NSLog("EasyFind: InstallEventHandler failed with status \(installStatus)")
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            settings.keyCode,
            settings.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            NSLog("EasyFind: RegisterEventHotKey failed with status \(registerStatus)")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}
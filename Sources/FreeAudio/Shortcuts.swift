import AppKit
import Carbon.HIToolbox

/// What a keyboard shortcut does, on the default microphone.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case toggleMicrophone, muteMicrophone, unmuteMicrophone

    var id: Self { self }
    var title: String { L("shortcut.\(rawValue)") }
    var hint: String { L("shortcut.\(rawValue)_hint") }

    /// For the log, which is in Chinese.
    var logName: String {
        switch self {
        case .toggleMicrophone: "切換麥克風靜音"
        case .muteMicrophone: "麥克風靜音"
        case .unmuteMicrophone: "麥克風解除靜音"
        }
    }

    /// The number Carbon reports a press by.
    var number: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
}

/// A key with modifiers. Two combos are the same shortcut when their key and modifiers are; `key` is only how the key
/// was labelled when it was recorded, on that keyboard layout.
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw values, only ⌃⌥⇧⌘.
    var modifiers: UInt
    var key: String

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
        self.key = key
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// "⌃⌥⇧⌘M", in the order the menus use.
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    var carbonModifiers: UInt32 {
        var result = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }

    /// A shortcut needs ⌘, ⌥ or ⌃, so typing never sets it off; a function key can stand alone.
    var isUsable: Bool {
        !flags.intersection([.command, .option, .control]).isEmpty || Self.functionKeys.contains(Int(keyCode))
    }

    static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    private static let functionKeys: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// The label of a key that doesn't type a character; `nil` for one that does.
    static func name(keyCode: Int) -> String? {
        if let index = functionKeys.firstIndex(of: keyCode) { return "F\(index + 1)" }
        return switch keyCode {
        case kVK_Space: "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Escape: "⎋"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        default: nil
        }
    }
}

struct ShortcutSettings: StoredSettings {
    static let key = "FreeAudio.shortcuts.v1"
    /// By `ShortcutAction` raw value; none is set at first.
    var combos: [String: KeyCombo] = [:]
    /// Shows the microphone's new state in the top-right corner after a shortcut.
    var showsOSD = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.update(&combos, .combos)
        try container.update(&showsOSD, .showsOSD)
    }

    subscript(action: ShortcutAction) -> KeyCombo? {
        get { combos[action.rawValue] }
        set { combos[action.rawValue] = newValue }
    }

    /// Another action already set to `combo`.
    func action(using combo: KeyCombo, besides action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self[$0] == combo }
    }
}

/// What a key pressed while recording a shortcut does.
enum ShortcutRecording: Equatable {
    case cancel
    case clear
    case set(KeyCombo)
    /// Keeps recording, saying why the key can't be used.
    case reject(String)

    static func decide(keyCode: Int, flags: NSEvent.ModifierFlags, key: String?, for action: ShortcutAction, in settings: ShortcutSettings) -> Self {
        let flags = flags.intersection(KeyCombo.relevant)
        if flags.isEmpty, keyCode == kVK_Escape { return .cancel }
        if flags.isEmpty, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete { return .clear }
        let combo = KeyCombo(keyCode: UInt32(keyCode), modifiers: flags, key: KeyCombo.name(keyCode: keyCode) ?? key?.uppercased() ?? "?")
        guard combo.isUsable else { return .reject(L("shortcuts.needs_modifier")) }
        if let other = settings.action(using: combo, besides: action) { return .reject(LF("shortcuts.in_use", other.title)) }
        return .set(combo)
    }
}

/// The shortcuts, registered with the system so they work whichever app is in front. Registering a hot key needs no
/// Accessibility permission; a combo something else has already taken can't be registered and is listed in
/// `unavailable`.
@MainActor
final class Shortcuts: ObservableObject {
    @Published private(set) var settings: ShortcutSettings
    @Published private(set) var unavailable: Set<ShortcutAction> = []
    var perform: (ShortcutAction) -> Void = { _ in }

    private static let signature: OSType = 0x4652_4155 // 'FRAU'
    private let registers: Bool
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var paused = false

    /// Previews and tests don't register anything.
    init(registers: Bool) {
        self.registers = registers
        settings = registers ? .load() : ShortcutSettings()
        guard registers else { return }
        installHandler()
        register()
    }

    func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        guard settings[action] != combo || settings[action]?.key != combo?.key else { return }
        settings[action] = combo
        if registers { settings.save() }
        Log.info("shortcut", combo.map { "「\(action.logName)」設為 \($0.display)" } ?? "清除「\(action.logName)」的快捷鍵")
        register()
    }

    func setShowsOSD(_ on: Bool) {
        settings.showsOSD = on
        if registers { settings.save() }
    }

    /// While a shortcut is being recorded, so pressing one already set records it rather than running it.
    func pause() {
        paused = true
        register()
    }

    func resume() {
        paused = false
        register()
    }

    private func register() {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        guard registers, !paused else { return }
        var failed: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let combo = settings[action] else { continue }
            var hotKey: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.number)
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
            } else {
                failed.insert(action)
                if !unavailable.contains(action) { Log.warn("shortcut", "無法註冊 \(combo.display)（\(status)），可能已被系統或其他 App 使用") }
            }
        }
        if failed != unavailable { unavailable = failed }
    }

    private func installHandler() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Hot key events arrive on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr else { return status }
            let shortcuts = Unmanaged<Shortcuts>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { shortcuts.pressed(id) }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func pressed(_ id: EventHotKeyID) {
        guard id.signature == Self.signature, let action = ShortcutAction.allCases.first(where: { $0.number == id.id }) else { return }
        perform(action)
    }
}

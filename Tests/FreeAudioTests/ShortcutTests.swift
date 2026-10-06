import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import FreeAudio

@Suite struct ShortcutTests {
    private func decide(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, _ key: String? = "m", for action: ShortcutAction = .toggleMicrophone,
                        in settings: ShortcutSettings = ShortcutSettings()) -> ShortcutRecording {
        ShortcutRecording.decide(keyCode: keyCode, flags: flags, key: key, for: action, in: settings)
    }

    @Test func recordsAKeyWithModifiers() {
        guard case .set(let combo) = decide(kVK_ANSI_M, [.command, .shift, .capsLock]) else { Issue.record("not recorded"); return }
        // Caps Lock and the like aren't part of a shortcut.
        #expect(combo.flags == [.command, .shift] && combo.display == "⇧⌘M")
        #expect(combo.carbonModifiers == UInt32(cmdKey | shiftKey))
    }

    @Test func showsModifiersInTheMenusOrder() {
        let combo = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: [.command, .option, .shift, .control], key: "Space")
        #expect(combo.display == "⌃⌥⇧⌘Space")
    }

    @Test func plainKeysAreRefusedButFunctionKeysAreNot() {
        guard case .reject = decide(kVK_ANSI_M, []) else { Issue.record("a plain letter was taken"); return }
        guard case .reject = decide(kVK_ANSI_M, [.shift]) else { Issue.record("shift alone was taken"); return }
        guard case .set(let combo) = decide(kVK_F13, [], nil) else { Issue.record("F13 was refused"); return }
        #expect(combo.display == "F13")
    }

    @Test func escapeCancelsAndDeleteClears() {
        #expect(decide(kVK_Escape, []) == .cancel)
        #expect(decide(kVK_Delete, []) == .clear)
        #expect(decide(kVK_ForwardDelete, []) == .clear)
        // With a modifier they're keys like any other.
        guard case .set = decide(kVK_Escape, [.option], nil) else { Issue.record("⌥⎋ was refused"); return }
    }

    @Test func twoActionsCantShareKeys() {
        var settings = ShortcutSettings()
        settings[.muteMicrophone] = KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: [.command, .option], key: "M")
        guard case .reject(let reason) = decide(kVK_ANSI_M, [.command, .option], "µ", in: settings) else { Issue.record("shared keys"); return }
        #expect(reason.contains(ShortcutAction.muteMicrophone.title))
        // Setting the same action again is fine.
        guard case .set = decide(kVK_ANSI_M, [.command, .option], "µ", for: .muteMicrophone, in: settings) else { Issue.record("refused own keys"); return }
    }

    @Test func combosAreTheSameKeysWhateverTheirLabel() {
        let us = KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: [.command], key: "M")
        let other = KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: [.command], key: "Ｍ")
        #expect(us == other && Set([us, other]).count == 1)
    }

    @Test func settingsRoundTripAndDefault() throws {
        let empty = try JSONDecoder().decode(ShortcutSettings.self, from: Data("{}".utf8))
        #expect(empty.combos.isEmpty && empty.showsOSD)
        var settings = ShortcutSettings()
        settings[.toggleMicrophone] = KeyCombo(keyCode: UInt32(kVK_F5), modifiers: [], key: "F5")
        settings.showsOSD = false
        let decoded = try JSONDecoder().decode(ShortcutSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings && decoded[.toggleMicrophone]?.display == "F5")
    }

    @Test func actionsHaveDistinctNumbers() {
        #expect(Set(ShortcutAction.allCases.map(\.number)).count == ShortcutAction.allCases.count)
        #expect(!ShortcutAction.allCases.map(\.number).contains(0))
    }
}

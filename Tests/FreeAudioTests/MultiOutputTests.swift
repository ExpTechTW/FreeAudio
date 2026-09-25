import Testing
@testable import FreeAudio

@Suite struct MultiOutputTests {
    private let headphones = "BuiltInHeadphoneOutputDevice"
    private let speakers = "BuiltInSpeakerDevice"
    private let tv = "HDMI-TV"
    private let airpods = "AA-BB:output"

    private func toggle(_ uid: String, main: String, extras: [String], connected: Set<String>? = nil) -> MultiOutput.Selection? {
        MultiOutput.toggle(uid, in: .init(main: main, extras: extras), connected: connected ?? [headphones, speakers, tv])
    }

    @Test func checkingAnOutputAddsIt() {
        #expect(toggle(tv, main: headphones, extras: [speakers]) == .init(main: headphones, extras: [speakers, tv]))
    }

    @Test func uncheckingAnExtraRemovesIt() {
        #expect(toggle(speakers, main: headphones, extras: [speakers, tv]) == .init(main: headphones, extras: [tv]))
    }

    @Test func uncheckingTheMainOutputHandsItsPlaceToTheNextOne() {
        #expect(toggle(headphones, main: headphones, extras: [speakers, tv]) == .init(main: speakers, extras: [tv]))
    }

    @Test func aDisconnectedExtraNeverTakesOverButStaysChecked() {
        let next = toggle(headphones, main: headphones, extras: [airpods, tv])
        #expect(next == .init(main: tv, extras: [airpods]))
    }

    @Test func theLastOutputPlayingCannotBeUnchecked() {
        #expect(toggle(headphones, main: headphones, extras: []) == nil)
        #expect(toggle(headphones, main: headphones, extras: [airpods]) == nil)
    }

    @Test func theMainOutputListedAsAnExtraIsNotItsOwnSuccessor() {
        // The default moved to a device that was an extra.
        #expect(toggle(speakers, main: speakers, extras: [speakers, tv]) == .init(main: tv, extras: []))
    }
}

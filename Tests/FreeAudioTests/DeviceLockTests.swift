import CoreAudio
import Foundation
import Testing
@testable import FreeAudio

@Suite struct DeviceLockTests {
    private let speakers = AudioDevice(id: 70, uid: "BuiltInSpeakerDevice", name: "Speakers", symbol: "laptopcomputer")
    private let headphones = AudioDevice(id: 90, uid: "AA-BB-CC:output", name: "Headphones", symbol: "headphones")
    private let tv = AudioDevice(id: 95, uid: "HDMI-TV", name: "TV", symbol: "tv")

    private func decide(chosen: String, devices: [AudioDevice], current: AudioDeviceID) -> DeviceLockDecision {
        DeviceLock.decide(chosenUID: chosen, devices: devices, currentID: current)
    }

    @Test func keepsTheChosenDevice() {
        #expect(decide(chosen: speakers.uid, devices: [speakers, headphones], current: speakers.id) == .keep)
    }

    @Test func connectingHeadphonesDoesNotTakeOver() {
        // macOS switched to the headphones when they connected, however long after they appeared.
        #expect(decide(chosen: speakers.uid, devices: [speakers, headphones], current: headphones.id) == .switchBack(speakers.id))
    }

    @Test func aNewSpeakerDoesNotTakeOver() {
        #expect(decide(chosen: headphones.uid, devices: [speakers, headphones, tv], current: tv.id) == .switchBack(headphones.id))
    }

    @Test func aSwitchMadeElsewhereIsUndone() {
        // Picked in Control Center: only a choice made in FreeAudio changes the chosen device.
        #expect(decide(chosen: headphones.uid, devices: [speakers, headphones], current: speakers.id) == .switchBack(headphones.id))
    }

    @Test func aMissingDeviceIsNeverReplaced() {
        // Headphones unplugged, macOS fell back to the speakers.
        #expect(decide(chosen: headphones.uid, devices: [speakers, tv], current: speakers.id) == .missing)
        #expect(decide(chosen: headphones.uid, devices: [], current: AudioDeviceID(kAudioObjectUnknown)) == .missing)
    }

    @Test func matchesByUIDNotName() {
        // Same name, different device (e.g. another pair of the same headphones).
        let lookalike = AudioDevice(id: 91, uid: "DD-EE-FF:output", name: "Headphones", symbol: "headphones")
        #expect(decide(chosen: headphones.uid, devices: [speakers, lookalike], current: lookalike.id) == .missing)
    }

    @Test func unknownCurrentDeviceSwitchesBack() {
        #expect(decide(chosen: speakers.uid, devices: [speakers], current: AudioDeviceID(kAudioObjectUnknown)) == .switchBack(speakers.id))
    }

    @Test func findsAHeadsetsOwnMicrophoneExactly() {
        let airpodsOut = AudioDevice(id: 5001, uid: "AC-07-75-CF-A0-C4:output", name: "AirPods", symbol: "airpods.pro")
        let airpodsIn = AudioDevice(id: 5002, uid: "AC-07-75-CF-A0-C4:input", name: "AirPods", symbol: "airpods.pro")
        let otherIn = AudioDevice(id: 5003, uid: "11-22-33-44-55-66:input", name: "AirPods", symbol: "airpods.pro")
        let usbHeadset = AudioDevice(id: 5004, uid: "AppleUSBAudioEngine:Headset:1", name: "Headset", symbol: "headphones")
        let builtInMic = AudioDevice(id: 5005, uid: "BuiltInMicrophoneDevice", name: "Mic", symbol: "mic")
        let inputs = [builtInMic, otherIn, airpodsIn, usbHeadset]
        #expect(AudioDevices.pairedInput(for: airpodsOut, among: inputs) == airpodsIn)
        #expect(AudioDevices.pairedInput(for: usbHeadset, among: inputs) == usbHeadset)
        // Same name but a different address, and a speaker with no microphone, don't match.
        #expect(AudioDevices.pairedInput(for: airpodsOut, among: [builtInMic, otherIn]) == nil)
        #expect(AudioDevices.pairedInput(for: tv, among: inputs) == nil)
    }

    @Test func newDeviceSettingsDefaults() throws {
        let old = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"locksDevices":true}"#.utf8))
        #expect(!old.inputFollowsOutput && old.newDevicesSilent && old.knownDevices == nil)
    }

    @Test func lockIsOnByDefaultAndSurvivesOlderState() throws {
        let old = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"remembersSound":true}"#.utf8))
        #expect(old.locksDevices && !old.lockSeeded && old.silencedLevels.isEmpty)
        var state = PersistedState()
        state.locksDevices = false
        state.silencedLevels["output:BuiltInSpeakerDevice"] = DeviceLevel(volume: 0.4, muted: false)
        #expect(try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state)) == state)
    }
}

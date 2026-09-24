import CoreAudio
import Foundation
import Testing
@testable import FreeAudio

private let sampleRate = 48_000.0

/// Runs a sine through a stage and returns the steady-state output/input RMS ratio of each channel.
private func response(_ control: StageControl, frequency: Double, seconds: Double = 1) -> (left: Double, right: Double) {
    let stage = StageProcessor(control: control, sampleRate: sampleRate)
    let block = 512
    let left = UnsafeMutablePointer<Float>.allocate(capacity: block), right = UnsafeMutablePointer<Float>.allocate(capacity: block)
    defer { left.deallocate(); right.deallocate() }
    let total = Int(seconds * sampleRate)
    var input = 0.0, outLeft = 0.0, outRight = 0.0
    for start in stride(from: 0, to: total, by: block) {
        for i in 0..<block {
            let value = Float(0.25 * sin(2 * .pi * frequency * Double(start + i) / sampleRate))
            left[i] = value
            right[i] = value
        }
        let counted = start > total / 2
        if counted { for i in 0..<block { input += Double(left[i] * left[i]) } }
        stage.refresh()
        stage.process(left, right, frames: block)
        if counted {
            for i in 0..<block {
                outLeft += Double(left[i] * left[i])
                outRight += Double(right[i] * right[i])
            }
        }
    }
    return ((outLeft / input).squareRoot(), (outRight / input).squareRoot())
}

private func decibels(_ ratio: Double) -> Double { 20 * log10(ratio) }

private func control(gain: Double = 1, left: Double? = nil, right: Double? = nil, eq: EQSettings = EQSettings()) -> StageControl {
    let control = StageControl()
    control.update(gainLeft: left ?? gain, gainRight: right ?? gain, eq: eq)
    return control
}

@Suite struct StageTests {
    @Test func unityIsTransparent() {
        let (left, right) = response(control(), frequency: 1_000)
        #expect(abs(left - 1) < 1e-4 && abs(right - 1) < 1e-4)
    }

    @Test(arguments: Array(Equalizer.frequencies.enumerated()))
    func bandHitsItsCentreFrequency(band: Int, frequency: Double) {
        for gain in [12.0, -12.0] {
            var eq = EQSettings()
            eq.enabled = true
            eq.gains[band] = gain
            let measured = decibels(response(control(eq: eq), frequency: frequency, seconds: frequency < 100 ? 4 : 1).left)
            #expect(abs(measured - gain) < 0.3, "\(frequency) Hz at \(gain) dB measured \(measured) dB")
        }
    }

    @Test func disabledEqualizerIsTransparent() {
        var eq = EQSettings()
        eq.gains = Array(repeating: 12, count: Equalizer.bandCount)
        eq.enabled = false
        #expect(abs(response(control(eq: eq), frequency: 1_000).left - 1) < 1e-4)
    }

    @Test func preampScalesTheSignal() {
        var eq = EQSettings()
        eq.setPreamp(-6)
        #expect(eq.preset == .custom && eq.enabled)
        let measured = decibels(response(control(eq: eq), frequency: 1_000).left)
        #expect(abs(measured + 6) < 0.05, "measured \(measured) dB")
    }

    @Test func volumeAndBalance() {
        let half = response(control(gain: 0.5), frequency: 1_000)
        #expect(abs(half.left - 0.5) < 1e-3 && abs(half.right - 0.5) < 1e-3)
        let gains = (-0.5).balanceGains
        let balanced = response(control(left: gains.left, right: gains.right), frequency: 1_000)
        #expect(abs(balanced.left - 1) < 1e-3 && abs(balanced.right - 0.5) < 1e-3)
    }

    @Test func gainChangesAreRamped() {
        let control = control()
        let stage = StageProcessor(control: control, sampleRate: sampleRate)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 512), right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { left.deallocate(); right.deallocate() }
        left.update(repeating: 1, count: 512); right.update(repeating: 1, count: 512)
        stage.refresh(); stage.process(left, right, frames: 512)
        control.update(gainLeft: 0, gainRight: 0, eq: EQSettings())
        left.update(repeating: 1, count: 512); right.update(repeating: 1, count: 512)
        stage.refresh(); stage.process(left, right, frames: 512)
        let largestStep = (1..<512).map { abs(left[$0] - left[$0 - 1]) }.max() ?? 1
        #expect(left[0] > 0.99 && left[511] < 0.01 && largestStep < 0.01)
    }
}

/// Buffer lists shaped like an aggregate device's: the device's own input streams first, the tap last.
private final class IOBuffers {
    let input: UnsafeMutableAudioBufferListPointer
    let output: UnsafeMutableAudioBufferListPointer
    let frames: Int

    init(input: [Int], output: [Int], frames: Int = 512) {
        self.frames = frames
        func make(_ channels: [Int]) -> UnsafeMutableAudioBufferListPointer {
            let list = AudioBufferList.allocate(maximumBuffers: channels.count)
            for (index, count) in channels.enumerated() {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * count)
                data.initialize(repeating: 0, count: frames * count)
                list[index] = AudioBuffer(mNumberChannels: UInt32(count), mDataByteSize: UInt32(frames * count * 4), mData: data)
            }
            return list
        }
        self.input = make(input)
        self.output = make(output)
    }

    deinit {
        for list in [input, output] {
            for buffer in list { buffer.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    /// Fills the tap buffer with `sample(frame, channel)` and renders `cycles` IO cycles.
    func render(_ renderer: RouteRenderer, cycles: Int = 1, _ sample: (Int, Int) -> Float) {
        let block = renderer.makeIOBlock()
        var time = AudioTimeStamp()
        let tap = input[input.count - 1]
        let channels = Int(tap.mNumberChannels)
        for cycle in 0..<cycles {
            if let data = tap.mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frames {
                    for channel in 0..<channels { data[frame * channels + channel] = sample(cycle * frames + frame, channel) }
                }
            }
            block(&time, UnsafePointer(input.unsafePointer), &time, output.unsafeMutablePointer, &time)
        }
    }

    /// Peak level of every output channel, or `nil` if any sample isn't finite.
    var outputPeaks: [Float]? {
        var peaks: [Float] = []
        for buffer in output {
            let channels = Int(buffer.mNumberChannels)
            let data = buffer.mData!.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                var peak: Float = 0
                for frame in 0..<frames {
                    let value = data[frame * channels + channel]
                    guard value.isFinite else { return nil }
                    peak = max(peak, abs(value))
                }
                peaks.append(peak)
            }
        }
        return peaks
    }
}

private func sine(_ amplitude: Double) -> (Int, Int) -> Float {
    { frame, _ in Float(amplitude * sin(2 * .pi * 1_000 * Double(frame) / sampleRate)) }
}

private func renderer(
    app: StageControl? = nil, device: StageControl? = nil, left: Int = 0, right: Int = 1, tapLeft: Int = 0, tapRight: Int = 1
) -> RouteRenderer {
    RouteRenderer(
        sampleRate: sampleRate,
        appStage: app.map { StageProcessor(control: $0, sampleRate: sampleRate) },
        deviceStage: device.map { StageProcessor(control: $0, sampleRate: sampleRate) },
        leftChannel: left,
        rightChannel: right,
        tapLeftChannel: tapLeft,
        tapRightChannel: tapRight
    )
}

@Suite struct RendererTests {
    @Test func appliesAppVolume() throws {
        let buffers = IOBuffers(input: [2], output: [2])
        let route = renderer(app: control(gain: 0.5))
        buffers.render(route, cycles: 20, sine(0.5))
        let peaks = try #require(buffers.outputPeaks)
        #expect(peaks.allSatisfy { abs($0 - 0.25) < 0.002 })
        #expect(route.cycles.load(ordering: .relaxed) == 20)
    }

    @Test func limiterKeepsBoostBelowFullScale() throws {
        var eq = EQSettings()
        eq.enabled = true
        eq.gains = Array(repeating: 12, count: Equalizer.bandCount)
        let buffers = IOBuffers(input: [2], output: [2])
        let route = renderer(app: control(gain: 2, eq: eq))
        var loudest: Float = 0
        for _ in 0..<40 {
            buffers.render(route, sine(0.9))
            loudest = max(loudest, try #require(buffers.outputPeaks).max() ?? 0)
        }
        #expect(loudest <= 1)
        buffers.render(route, cycles: 50, sine(0.9))
        #expect(try #require(buffers.outputPeaks).max() ?? 1 <= 0.981)
    }

    @Test(arguments: [Float.nan, .infinity])
    func brokenSamplesNeverReachTheDevice(bad: Float) throws {
        let buffers = IOBuffers(input: [2], output: [2])
        let route = renderer()
        buffers.render(route) { frame, channel in channel == 1 && frame == 100 ? bad : 0.3 }
        #expect(try #require(buffers.outputPeaks) == [0, 0])
        buffers.render(route) { _, _ in 0.3 }
        #expect(try #require(buffers.outputPeaks) == [0.3, 0.3])
    }

    @Test func passesLoudInputUntouchedWithoutBoost() throws {
        let buffers = IOBuffers(input: [2], output: [2])
        buffers.render(renderer(), cycles: 3) { _, _ in 0.99 }
        #expect(try #require(buffers.outputPeaks) == [0.99, 0.99])
    }

    @Test func mutedAppWritesSilence() throws {
        let buffers = IOBuffers(input: [2], output: [2])
        buffers.output[0].mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.7, count: 1024)
        buffers.render(renderer(app: control(gain: 0)), cycles: 3, sine(0.5))
        #expect(try #require(buffers.outputPeaks) == [0, 0])
    }

    @Test func readsTheTapAfterDeviceInputsAndUsesThePreferredStereoPair() throws {
        let buffers = IOBuffers(input: [1, 1], output: [4])
        buffers.input[0].mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.9, count: 512)
        buffers.render(renderer(app: control(left: 1, right: 0), left: 2, right: 3), cycles: 5, sine(0.5))
        let peaks = try #require(buffers.outputPeaks)
        #expect(peaks[0] == 0 && peaks[1] == 0 && abs(peaks[2] - 0.5) < 0.002 && peaks[3] < 1e-6)
    }

    @Test func readsTheStereoPairOfADeviceTap() throws {
        // A four-channel interface playing on channels 3 and 4.
        let buffers = IOBuffers(input: [4], output: [2])
        buffers.render(renderer(tapLeft: 2, tapRight: 3), cycles: 2) { _, channel in [0.9, 0.9, 0.4, 0.2][channel] }
        #expect(try #require(buffers.outputPeaks) == [0.4, 0.2])
        // A stereo mixdown has no such channels; the pair falls back to the first two.
        let stereo = IOBuffers(input: [2], output: [2])
        stereo.render(renderer(tapLeft: 2, tapRight: 3), cycles: 2) { _, channel in [0.4, 0.2][channel] }
        #expect(try #require(stereo.outputPeaks) == [0.4, 0.2])
    }

    @Test func writesNonInterleavedOutputAndAppliesDeviceStage() throws {
        let buffers = IOBuffers(input: [2], output: [1, 1])
        buffers.render(renderer(app: control(), device: control(left: 1, right: 0.5)), cycles: 5, sine(0.5))
        let peaks = try #require(buffers.outputPeaks)
        #expect(abs(peaks[0] - 0.5) < 0.002 && abs(peaks[1] - 0.25) < 0.002)
    }

    @Test func downmixesForMonoDevices() throws {
        let buffers = IOBuffers(input: [2], output: [1])
        buffers.render(renderer(), cycles: 2) { _, channel in channel == 0 ? 0.4 : 0.2 }
        #expect(abs((try #require(buffers.outputPeaks))[0] - 0.3) < 1e-5)
    }

    @Test func clearsWhatTheTapDoesNotCover() throws {
        let buffers = IOBuffers(input: [2], output: [2])
        let output = buffers.output[0].mData!.assumingMemoryBound(to: Float.self)
        buffers.input[0].mDataByteSize = 256 * 2 * 4
        output.update(repeating: 0.7, count: 1024)
        buffers.render(renderer()) { _, _ in 0.5 }
        #expect(output[0] == 0.5 && output[256 * 2] == 0 && output[1023] == 0)

        let data = buffers.input[0].mData
        buffers.input[0].mData = nil
        output.update(repeating: 0.7, count: 1024)
        buffers.render(renderer()) { _, _ in 0.5 }
        buffers.input[0].mData = data
        #expect(try #require(buffers.outputPeaks) == [0, 0])
    }
}

@Suite struct RouteDescriptionTests {
    private func description(_ source: RouteKey.Source, tapOn device: String?, mute: CATapMuteBehavior = .muted) -> CATapDescription {
        AudioRoute.makeDescription(RouteSpec(key: RouteKey(source: source, deviceUID: "tv", tapDeviceUID: device), processes: [7, 9], mute: mute))
    }

    @Test func aDeviceTapOnlyTakesThatDevicesAudio() {
        // Asked for a mixdown, a tap takes its processes' audio from every device, whatever device it names: an app
        // would keep playing on a device it had left.
        let app = description(.app("com.example.player"), tapOn: "speakers")
        #expect(app.deviceUID == "speakers" && app.stream == 0 && !app.isMixdown && !app.isExclusive && app.processes == [7, 9])
        let mirror = description(.system, tapOn: "speakers", mute: .unmuted)
        #expect(mirror.deviceUID == "speakers" && !mirror.isMixdown && mirror.isExclusive && mirror.muteBehavior == .unmuted)
    }

    @Test func movingAnAppTakesItsAudioFromEveryDevice() {
        let moved = description(.app("com.example.player"), tapOn: nil)
        #expect(moved.deviceUID == nil && moved.isMixdown && !moved.isMono && moved.muteBehavior == .muted)
        #expect(moved.isPrivate)
    }
}

@Suite struct SettingsTests {
    @Test func editingABandMakesTheCurveCustom() {
        var eq = EQSettings()
        eq.apply(.rock)
        #expect(eq.enabled && eq.preset == .rock)
        eq.setGain(20, band: 0)
        #expect(eq.gains[0] == 12 && eq.preset == .custom)
        eq.apply(.flat)
        #expect(eq.gains.allSatisfy { $0 == 0 } && !eq.isActive)
    }

    @Test func presetsCoverEveryBand() throws {
        for preset in EQPreset.allCases where preset != .custom {
            let values = try #require(preset.values, "\(preset)")
            #expect(values.bands.count == Equalizer.bandCount, "\(preset)")
            #expect((values.bands + [values.preamp]).allSatisfy { Equalizer.gainRange.contains($0) }, "\(preset)")
        }
    }

    /// Spot checks against the Music app's own preset store (values in 1/100 dB).
    @Test func presetsUseTheMusicAppValues() throws {
        #expect(try #require(EQPreset.rnb.values).bands == [2.62, 6.92, 5.65, 1.33, -2.19, -1.50, 2.32, 2.65, 3.00, 3.75])
        #expect(try #require(EQPreset.spokenWord.values).bands == [-3.46, -0.47, 0, 0.69, 3.46, 4.61, 4.84, 4.28, 2.54, 0])
        #expect(try #require(EQPreset.bassBoost.values).bands == [5.50, 4.25, 3.50, 2.50, 1.25, 0, 0, 0, 0, 0])
        #expect(try #require(EQPreset.vocal.values).bands == [-1.50, -3.00, -3.00, 1.50, 3.75, 3.75, 3.00, 1.50, 0, -1.50])
        for preset in EQPreset.allCases where preset != .custom {
            #expect(try #require(preset.values).preamp == 0, "\(preset)")
        }
        #expect(Equalizer.frequencies == [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000])
    }

    @Test func editingBackToAPresetShowsItsNameAgain() {
        var eq = EQSettings()
        eq.apply(.rock)
        let original = eq.gains[4]
        eq.setGain(original + 2, band: 4)
        #expect(eq.preset == .custom)
        eq.setGain(original, band: 4)
        #expect(eq.preset == .rock)
    }

    @Test func savedPresetsPickUpTheOfficialValues() throws {
        let json = #"{"enabled":true,"preset":"rock","preamp":3,"gains":[1,1,1,1,1,1,1,1,1,1]}"#
        let eq = try JSONDecoder().decode(EQSettings.self, from: Data(json.utf8))
        #expect(eq.preset == .rock && eq.preamp == 0 && eq.gains == EQPreset.rock.values?.bands)
    }

    @Test func decodesPartialAndOutdatedState() throws {
        let json = #"{"apps":{"com.example":{"volume":0.4,"eq":{"preset":"removed","gains":[1,2,3]}}},"unknown":true}"#
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        let app = try #require(state.apps["com.example"])
        #expect(state.perAppEnabled && app.volume == 0.4 && !app.muted && app.outputUID == nil)
        #expect(app.eq.preset == .custom && app.eq.gains == Array(repeating: 0, count: Equalizer.bandCount))
    }

    @Test func remembersSoundByDefaultAndKeepsSavedLevels() throws {
        let old = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"perAppEnabled":false}"#.utf8))
        #expect(old.remembersSound && old.preferredDevices.isEmpty && old.deviceLevels.isEmpty && !old.perAppEnabled)

        var state = PersistedState()
        state.preferredDevices["output"] = "BuiltInSpeakerDevice"
        state.deviceLevels["input:BuiltInMicrophoneDevice"] = DeviceLevel(volume: 0.8, muted: true)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func routingNeedsFollowTheSettings() {
        var settings = AppAudioSettings()
        #expect(settings.isDefault && !settings.needsProcessing && !settings.isSilenced)
        settings.volume = 0
        #expect(settings.isSilenced)
        settings.volume = 1.2
        #expect(settings.needsProcessing && !settings.isSilenced)
    }
}

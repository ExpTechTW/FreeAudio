import Accelerate
import CoreAudio
import Foundation
import os
import Synchronization

enum Equalizer {
    /// The Music app's equalizer bands (see its scripting dictionary, `EQ preset` band 1–10).
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let bandCount = frequencies.count
    static let gainRange = -12.0...12.0
    /// One-octave bandwidth for the peaking filters.
    static let q = 1.41
}

/// How a stage passes the two channels on.
enum ChannelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case stereo, mono, swapped
    var id: Self { self }
    var title: String { L("channels.\(rawValue)") }
}

/// Filter shapes from the Audio EQ Cookbook, the ones AutoEq and Equalizer APO profiles use.
enum FilterKind: Int, Codable, Sendable {
    case peak, lowShelf, highShelf, lowPass, highPass
}

struct Filter: Codable, Equatable, Sendable {
    var kind: FilterKind
    var frequency: Double
    /// In dB; the pass filters have none.
    var gain = 0.0
    var q = 0.7071
}

/// Up to `capacity` filters, stored flat so the audio thread can copy them without allocating. The graphic
/// equalizer's bands take the first slots and headphone correction the rest.
struct FilterSet: Equatable, Sendable {
    static let capacity = 32
    static let correctionCapacity = capacity - Equalizer.bandCount

    /// `FilterKind` raw values; -1 marks an empty slot.
    private var kinds = SIMD32<Float>(repeating: -1)
    private var frequencies = SIMD32<Float>()
    private var gains = SIMD32<Float>()
    private var qs = SIMD32<Float>()

    subscript(slot: Int) -> Filter? {
        get {
            guard kinds[slot] >= 0, let kind = FilterKind(rawValue: Int(kinds[slot])) else { return nil }
            return Filter(kind: kind, frequency: Double(frequencies[slot]), gain: Double(gains[slot]), q: Double(qs[slot]))
        }
        set {
            kinds[slot] = newValue.map { Float($0.kind.rawValue) } ?? -1
            frequencies[slot] = Float(newValue?.frequency ?? 0)
            gains[slot] = Float(newValue?.gain ?? 0)
            qs[slot] = Float(newValue?.q ?? 0)
        }
    }

    /// Whether any filter raises a band, so the output can go over full scale.
    func boosts() -> Bool {
        (0..<Self.capacity).contains { slot in
            guard let filter = self[slot] else { return false }
            return filter.kind != .lowPass && filter.kind != .highPass && filter.gain > 0
        }
    }
}

/// Everything a stage does, as the settings describe it.
struct StageSetup: Equatable, Sendable {
    var gainLeft = 1.0
    var gainRight = 1.0
    var eq = EQSettings()
    var correction: HeadphoneCorrection?
    var channels = ChannelMode.stereo
    var leveling = false
    /// Seconds, up to `DelayLine.maximum`; only a device's stage has one.
    var delay = 0.0
}

/// A stage's settings as published to the audio threads.
struct StageParameters: Sendable {
    var gainLeft: Float = 1
    var gainRight: Float = 1
    var channels = ChannelMode.stereo
    var leveling = false
    var delay: Float = 0
    var filters = FilterSet()
    var filtersBoost = false
    /// Changes whenever `filters` does, so the audio thread only works out coefficients then.
    var filterGeneration: UInt32 = 0

    var canBoost: Bool { max(gainLeft, gainRight) > 1 || leveling || filtersBoost }
}

/// UI-side handle for a stage. Audio threads read it with a try-lock and never block.
final class StageControl: Sendable {
    private let parameters = OSAllocatedUnfairLock(initialState: StageParameters())

    func update(_ setup: StageSetup) {
        var filters = FilterSet()
        var preamp = 0.0
        if setup.eq.isActive {
            for (band, gain) in setup.eq.gains.prefix(Equalizer.bandCount).enumerated() where gain != 0 {
                filters[band] = Filter(kind: .peak, frequency: Equalizer.frequencies[band], gain: gain, q: Equalizer.q)
            }
            preamp += setup.eq.preamp
        }
        if let correction = setup.correction, correction.enabled {
            for (index, filter) in correction.filters.prefix(FilterSet.correctionCapacity).enumerated() {
                filters[Equalizer.bandCount + index] = filter
            }
            preamp += correction.preamp
        }
        let scale = Float(pow(10, preamp / 20))
        let delay = Float(setup.delay.clamped(to: 0...DelayLine.maximum))
        let bank = filters, boosts = filters.boosts()
        parameters.withLock {
            $0.gainLeft = Float(setup.gainLeft) * scale
            $0.gainRight = Float(setup.gainRight) * scale
            $0.channels = setup.channels
            $0.leveling = setup.leveling
            $0.delay = delay
            if $0.filters != bank {
                $0.filters = bank
                $0.filtersBoost = boosts
                $0.filterGeneration &+= 1
            }
        }
    }

    var current: StageParameters { parameters.withLock { $0 } }
    func snapshot() -> StageParameters? { parameters.withLockIfAvailable { $0 } }
}

/// One second-order section (transposed direct form II) filtering both channels at once: left and right sit side
/// by side in the lanes of a `SIMD2`. Doubles keep the lowest bands accurate.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = SIMD2<Double>.zero, z2 = SIMD2<Double>.zero

    /// Passes the sound through unchanged.
    init() {}

    /// Coefficients normalised so a0 is 1.
    init(b: (Double, Double, Double), a: (Double, Double)) {
        (b0, b1, b2) = b
        (a1, a2) = a
    }

    /// The Audio EQ Cookbook's filters, as AutoEq computes them; `nil` where one changes nothing (0 dB) or can't be
    /// made (at or past 0.45 of the sample rate, or with a frequency or Q that isn't positive).
    init?(_ filter: Filter, sampleRate: Double) {
        let passes = filter.kind == .lowPass || filter.kind == .highPass
        guard filter.frequency > 0, filter.q > 0, filter.frequency < sampleRate * 0.45, passes || filter.gain != 0 else { return nil }
        let omega = 2 * Double.pi * filter.frequency / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * filter.q)
        let amplitude = pow(10, filter.gain / 40)
        let root = 2 * amplitude.squareRoot() * alpha
        let (b, a0, a): ((Double, Double, Double), Double, (Double, Double))
        switch filter.kind {
        case .peak:
            b = (1 + alpha * amplitude, -2 * cosine, 1 - alpha * amplitude)
            (a0, a) = (1 + alpha / amplitude, (-2 * cosine, 1 - alpha / amplitude))
        case .lowShelf:
            let (plus, minus) = (amplitude + 1, amplitude - 1)
            b = (amplitude * (plus - minus * cosine + root), 2 * amplitude * (minus - plus * cosine), amplitude * (plus - minus * cosine - root))
            (a0, a) = (plus + minus * cosine + root, (-2 * (minus + plus * cosine), plus + minus * cosine - root))
        case .highShelf:
            let (plus, minus) = (amplitude + 1, amplitude - 1)
            b = (amplitude * (plus + minus * cosine + root), -2 * amplitude * (minus + plus * cosine), amplitude * (plus + minus * cosine - root))
            (a0, a) = (plus - minus * cosine + root, (2 * (minus - plus * cosine), plus - minus * cosine - root))
        case .lowPass:
            b = ((1 - cosine) / 2, 1 - cosine, (1 - cosine) / 2)
            (a0, a) = (1 + alpha, (-2 * cosine, 1 - alpha))
        case .highPass:
            b = ((1 + cosine) / 2, -(1 + cosine), (1 + cosine) / 2)
            (a0, a) = (1 + alpha, (-2 * cosine, 1 - alpha))
        }
        self.init(b: (b.0 / a0, b.1 / a0, b.2 / a0), a: (a.0 / a0, a.1 / a0))
    }

    /// |H| at `frequency`.
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(omega), sin(omega), cos(2 * omega), sin(2 * omega))
        let numerator = (b0 + b1 * c1 + b2 * c2, b1 * s1 + b2 * s2)
        let denominator = (1 + a1 * c1 + a2 * c2, a1 * s1 + a2 * s2)
        return ((numerator.0 * numerator.0 + numerator.1 * numerator.1) / (denominator.0 * denominator.0 + denominator.1 * denominator.1)).squareRoot()
    }

    @inline(__always)
    mutating func process(_ x: SIMD2<Double>) -> SIMD2<Double> {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func takeCoefficients(of other: Biquad) {
        (b0, b1, b2, a1, a2) = (other.b0, other.b1, other.b2, other.a1, other.a2)
    }

    /// Clears denormals, and whatever a blow-up left behind.
    mutating func settle() {
        func settled(_ value: Double) -> Double { value.isFinite && abs(value) > 1e-18 ? value : 0 }
        z1 = SIMD2(settled(z1.x), settled(z1.y))
        z2 = SIMD2(settled(z2.x), settled(z2.y))
    }
}

/// Runs a chain of sections sample by sample: the recursions of different sections don't wait on each other, so the
/// processor overlaps them, and each sample is converted to and from `Double` only once.
private func filter(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int,
                    _ sections: UnsafeMutablePointer<Biquad>, _ order: UnsafePointer<Int>, count: Int) {
    for i in 0..<frames {
        var x = SIMD2(Double(left[i]), Double(right[i]))
        for j in 0..<count { x = sections[order[j]].process(x) }
        left[i] = Float(x.x)
        right[i] = Float(x.y)
    }
    for j in 0..<count { sections[order[j]].settle() }
}

/// Night mode: a compressor that turns loud passages down and brings quiet ones up, so dialogue and explosions end up
/// closer together. It follows the louder channel 32 frames at a time: a louder chunk is turned down at once, from its
/// own peak, so a sudden bang doesn't get through at the gain meant for the quiet before it; the gain comes back up
/// slowly, which keeps it from wobbling with each wave of a bass note.
struct Leveler {
    static let threshold: Float = -24
    static let ratio: Float = 3
    static let knee: Float = 6
    static let makeup: Float = 8
    private static let chunk = 32

    private let release: Float
    /// Back to unity after it's switched off.
    private let fade: Float
    /// How far loud audio is being turned down, in dB.
    private var reduction: Float = 0
    private var gain: Float = 1

    init(sampleRate: Double) {
        release = 1 - expf(-Float(Self.chunk) / (0.5 * Float(sampleRate)))
        fade = 1 - expf(-Float(Self.chunk) / (0.1 * Float(sampleRate)))
    }

    /// The static curve: how many dB audio at `level` dBFS is turned down, with a soft knee around the threshold.
    static func reduction(at level: Float) -> Float {
        let over = level - threshold, slope = 1 - 1 / ratio
        if over <= -knee / 2 { return 0 }
        if over >= knee / 2 { return over * slope }
        return slope * (over + knee / 2) * (over + knee / 2) / (2 * knee)
    }

    /// Whether switching it off has finished fading its gain back to 1.
    var isIdle: Bool { gain == 1 && reduction == 0 }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int, on: Bool) {
        var offset = 0
        while offset < frames {
            let count = min(Self.chunk, frames - offset)
            var target: Float = 1
            if on {
                var peakLeft: Float = 0, peakRight: Float = 0
                vDSP_maxmgv(left + offset, 1, &peakLeft, vDSP_Length(count))
                vDSP_maxmgv(right + offset, 1, &peakRight, vDSP_Length(count))
                let wanted = Self.reduction(at: 20 * log10f(max(peakLeft, peakRight, 1e-6)))
                reduction = wanted > reduction ? wanted : reduction + (wanted - reduction) * release
                target = powf(10, (Self.makeup - reduction) / 20)
            } else {
                reduction = 0
                // Off: ease back to unity, then stop.
                target = abs(gain - 1) < 0.001 ? 1 : gain + (1 - gain) * fade
            }
            var start = gain, step = (target - gain) / Float(count)
            vDSP_vrampmul(left + offset, 1, &start, &step, left + offset, 1, vDSP_Length(count))
            start = gain
            vDSP_vrampmul(right + offset, 1, &start, &step, right + offset, 1, vDSP_Length(count))
            gain = target
            offset += count
        }
    }
}

/// Filter and gain state for one stage of one route. Only the route's IO thread touches it.
final class StageProcessor {
    private let control: StageControl
    private let sampleRate: Double
    private(set) var parameters: StageParameters
    private var generation: UInt32
    private var gainLeft: Float
    private var gainRight: Float
    /// A section per slot, so a filter keeps its state while its settings move.
    private let sections = UnsafeMutablePointer<Biquad>.allocate(capacity: FilterSet.capacity)
    /// The slots that change the sound, in order; empty and flat ones are skipped.
    private let active = UnsafeMutablePointer<Int>.allocate(capacity: FilterSet.capacity)
    private var activeCount = 0
    private var leveler: Leveler

    init(control: StageControl, sampleRate: Double) {
        self.control = control
        self.sampleRate = sampleRate
        parameters = control.current
        generation = parameters.filterGeneration &- 1
        gainLeft = parameters.gainLeft
        gainRight = parameters.gainRight
        leveler = Leveler(sampleRate: sampleRate)
        sections.initialize(repeating: Biquad(), count: FilterSet.capacity)
        active.initialize(repeating: 0, count: FilterSet.capacity)
    }

    deinit {
        sections.deallocate()
        active.deallocate()
    }

    var canBoost: Bool { parameters.canBoost || max(gainLeft, gainRight) > 1 || !leveler.isIdle }

    /// Pulls the latest parameters; call once per IO cycle before `process`.
    func refresh() {
        if let latest = control.snapshot() { parameters = latest }
        if parameters.filterGeneration != generation { updateCoefficients() }
    }

    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        switch parameters.channels {
        case .stereo:
            break
        case .mono:
            var half: Float = 0.5
            vDSP_vasm(left, 1, right, 1, &half, left, 1, vDSP_Length(frames))
            right.update(from: left, count: frames)
        case .swapped:
            vDSP_vswap(left, 1, right, 1, vDSP_Length(frames))
        }
        if activeCount > 0 { filter(left, right, frames: frames, sections, active, count: activeCount) }
        if parameters.leveling || !leveler.isIdle { leveler.process(left, right, frames: frames, on: parameters.leveling) }
        Self.applyGain(left, frames: frames, from: gainLeft, to: parameters.gainLeft)
        Self.applyGain(right, frames: frames, from: gainRight, to: parameters.gainRight)
        gainLeft = parameters.gainLeft
        gainRight = parameters.gainRight
    }

    private func updateCoefficients() {
        var count = 0
        for slot in 0..<FilterSet.capacity {
            guard let filter = parameters.filters[slot], let section = Biquad(filter, sampleRate: sampleRate) else { continue }
            // A slot that was off starts from silence rather than from its state of long ago.
            if !(0..<activeCount).contains(where: { active[$0] == slot }) { sections[slot] = section }
            sections[slot].takeCoefficients(of: section)
            active[count] = slot
            count += 1
        }
        activeCount = count
        generation = parameters.filterGeneration
    }

    private static func applyGain(_ samples: UnsafeMutablePointer<Float>, frames: Int, from start: Float, to end: Float) {
        if start == end {
            if end != 1 {
                var gain = end
                vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frames))
            }
        } else {
            // Ramp across the block so volume changes don't click.
            var gain = start
            var step = (end - start) / Float(frames)
            vDSP_vrampmul(samples, 1, &gain, &step, samples, 1, vDSP_Length(frames))
        }
    }
}

/// Holds both channels back by a number of frames. Changing the delay crossfades from the old one to the new one
/// over a block, so it doesn't click.
final class DelayLine {
    /// The longest delay, in seconds.
    static let maximum = 0.5

    private let size: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let fadeLeft: UnsafeMutablePointer<Float>
    private let fadeRight: UnsafeMutablePointer<Float>
    private var position = 0
    private var current = 0

    /// Starts out `delay` frames behind, rather than fading into it.
    init(sampleRate: Double, block: Int, delay: Int) {
        size = Int(Self.maximum * sampleRate) + block
        current = min(max(delay, 0), size - block)
        left = .allocate(capacity: size)
        right = .allocate(capacity: size)
        fadeLeft = .allocate(capacity: block)
        fadeRight = .allocate(capacity: block)
        left.initialize(repeating: 0, count: size)
        right.initialize(repeating: 0, count: size)
        fadeLeft.initialize(repeating: 0, count: block)
        fadeRight.initialize(repeating: 0, count: block)
    }

    deinit {
        for buffer in [left, right, fadeLeft, fadeRight] { buffer.deallocate() }
    }

    func process(_ blockLeft: UnsafeMutablePointer<Float>, _ blockRight: UnsafeMutablePointer<Float>, frames: Int, delay requested: Int) {
        let delay = min(max(requested, 0), size - frames)
        // Always kept, so a delay set later has the audio it needs.
        store(blockLeft, in: left, frames: frames)
        store(blockRight, in: right, frames: frames)
        if delay != current {
            load(fadeLeft, from: left, delay: current, frames: frames)
            load(fadeRight, from: right, delay: current, frames: frames)
            load(blockLeft, from: left, delay: delay, frames: frames)
            load(blockRight, from: right, delay: delay, frames: frames)
            Self.crossfade(from: fadeLeft, to: blockLeft, frames: frames)
            Self.crossfade(from: fadeRight, to: blockRight, frames: frames)
            current = delay
        } else if delay > 0 {
            load(blockLeft, from: left, delay: delay, frames: frames)
            load(blockRight, from: right, delay: delay, frames: frames)
        }
        position = (position + frames) % size
    }

    private func store(_ block: UnsafePointer<Float>, in ring: UnsafeMutablePointer<Float>, frames: Int) {
        let first = min(frames, size - position)
        (ring + position).update(from: block, count: first)
        ring.update(from: block + first, count: frames - first)
    }

    /// The `frames` that were stored `delay` frames before the block just stored.
    private func load(_ block: UnsafeMutablePointer<Float>, from ring: UnsafeMutablePointer<Float>, delay: Int, frames: Int) {
        let start = (position - delay + size) % size
        let first = min(frames, size - start)
        block.update(from: ring + start, count: first)
        (block + first).update(from: ring, count: frames - first)
    }

    /// `to` fades in while `from` fades out.
    private static func crossfade(from old: UnsafeMutablePointer<Float>, to new: UnsafeMutablePointer<Float>, frames: Int) {
        var up: Float = 0, down: Float = 1, step = 1 / Float(frames), back = -step
        vDSP_vrampmul(new, 1, &up, &step, new, 1, vDSP_Length(frames))
        vDSP_vrampmul(old, 1, &down, &back, old, 1, vDSP_Length(frames))
        vDSP_vadd(new, 1, old, 1, new, 1, vDSP_Length(frames))
    }
}

/// Renders one tap into one output device: app stage → device stage → limiter → delay → channel mapping.
final class RouteRenderer: @unchecked Sendable {
    private static let capacity = 4096

    let cycles = Atomic<UInt64>(0)
    /// Uptime in nanoseconds when the tap last delivered anything but silence; 0 until it has.
    let lastSound = Atomic<UInt64>(0)
    private let appStage: StageProcessor?
    private let deviceStage: StageProcessor?
    private let leftChannel: Int
    private let rightChannel: Int
    private let tapLeftChannel: Int
    private let tapRightChannel: Int
    private let sampleRate: Double
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private var limiterGain: Float = 1
    private let delay: DelayLine?

    /// `leftChannel`/`rightChannel` are zero-based indices across all output channels of the device.
    /// `tapLeftChannel`/`tapRightChannel` pick the stereo pair out of a tap that carries a device's own channels.
    init(
        sampleRate: Double, appStage: StageProcessor?, deviceStage: StageProcessor?, leftChannel: Int, rightChannel: Int,
        tapLeftChannel: Int = 0, tapRightChannel: Int = 1
    ) {
        self.sampleRate = sampleRate
        self.appStage = appStage
        self.deviceStage = deviceStage
        self.leftChannel = leftChannel
        self.rightChannel = rightChannel
        self.tapLeftChannel = tapLeftChannel
        self.tapRightChannel = tapRightChannel
        delay = deviceStage.map {
            DelayLine(sampleRate: sampleRate, block: Self.capacity, delay: Self.frames($0.parameters.delay, at: sampleRate))
        }
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func makeIOBlock() -> AudioDeviceIOBlock {
        { [self] _, input, _, output, _ in render(input, output) }
    }

    private func render(_ inputData: UnsafePointer<AudioBufferList>, _ outputData: UnsafeMutablePointer<AudioBufferList>) {
        cycles.add(1, ordering: .relaxed)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)
        guard let firstOutput = outputs.first, firstOutput.mNumberChannels > 0 else { return }
        let outputFrames = Int(firstOutput.mDataByteSize) / MemoryLayout<Float>.size / Int(firstOutput.mNumberChannels)

        // The aggregate lists the device's own input streams first and the tap last.
        guard let tap = inputs.last, tap.mNumberChannels > 0,
              let source = tap.mData?.assumingMemoryBound(to: Float.self) else {
            Self.clear(outputs, from: 0, to: outputFrames)
            return
        }
        let inputChannels = Int(tap.mNumberChannels)
        let frames = min(Int(tap.mDataByteSize) / MemoryLayout<Float>.size / inputChannels, outputFrames)
        var inputPeak: Float = 0
        vDSP_maxmgv(source, 1, &inputPeak, vDSP_Length(frames * inputChannels))
        if inputPeak > 0 { lastSound.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed) }

        appStage?.refresh()
        deviceStage?.refresh()
        let boosting = appStage?.canBoost == true || deviceStage?.canBoost == true
        let delayFrames = Self.frames(deviceStage?.parameters.delay ?? 0, at: sampleRate)
        var offset = 0
        while offset < frames {
            let count = min(Self.capacity, frames - offset)
            deinterleave(source + offset * inputChannels, channels: inputChannels, frames: count)
            appStage?.process(left, right, frames: count)
            deviceStage?.process(left, right, frames: count)
            limit(frames: count, boosting: boosting)
            delay?.process(left, right, frames: count, delay: delayFrames)
            write(outputs, offset: offset, frames: count)
            offset += count
        }
        Self.clear(outputs, from: frames, to: outputFrames)
    }

    private static func frames(_ seconds: Float, at sampleRate: Double) -> Int {
        Int((Double(seconds) * sampleRate).rounded())
    }

    private func deinterleave(_ source: UnsafeMutablePointer<Float>, channels: Int, frames: Int) {
        if channels == 1 {
            left.update(from: source, count: frames)
            right.update(from: source, count: frames)
            return
        }
        // A mixdown is plain stereo, which the pair falls back to.
        let leftIndex = tapLeftChannel < channels ? tapLeftChannel : 0
        let rightIndex = tapRightChannel < channels ? tapRightChannel : 1
        for frame in 0..<frames {
            left[frame] = source[frame * channels + leftIndex]
            right[frame] = source[frame * channels + rightIndex]
        }
    }

    /// Block peak limiter (fast attack, slow release) with a soft clipper for what the attack ramp lets through.
    private func limit(frames: Int, boosting: Bool) {
        var peakLeft: Float = 0, peakRight: Float = 0
        vDSP_maxmgv(left, 1, &peakLeft, vDSP_Length(frames))
        vDSP_maxmgv(right, 1, &peakRight, vDSP_Length(frames))
        let peak = max(peakLeft, peakRight)
        // vDSP's max doesn't reliably propagate NaN; a sum does.
        var sumLeft: Float = 0, sumRight: Float = 0
        vDSP_sve(left, 1, &sumLeft, vDSP_Length(frames))
        vDSP_sve(right, 1, &sumRight, vDSP_Length(frames))
        guard peak.isFinite, (sumLeft + sumRight).isFinite else {
            // A broken source must never reach the speakers.
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }
        // Without boost the source passes through untouched, as it would without FreeAudio.
        guard boosting || limiterGain < 1 else { return }

        let ceiling: Float = 0.98
        let target: Float = peak > ceiling ? ceiling / peak : 1
        let next = target < limiterGain
            ? target
            : limiterGain + (target - limiterGain) * (1 - expf(-Float(frames) / (0.25 * Float(sampleRate))))
        if limiterGain != 1 || next != 1 {
            var gain = limiterGain
            var step = (next - limiterGain) / Float(frames)
            vDSP_vrampmul(left, 1, &gain, &step, left, 1, vDSP_Length(frames))
            gain = limiterGain
            vDSP_vrampmul(right, 1, &gain, &step, right, 1, vDSP_Length(frames))
        }
        if peak * max(limiterGain, next) > Self.knee {
            Self.softClip(left, frames: frames)
            Self.softClip(right, frames: frames)
        }
        limiterGain = next > 0.9999 ? 1 : next
    }

    private static let knee: Float = 0.9

    /// Maps everything above the knee smoothly into (knee, 1).
    private static func softClip(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        let headroom = 1 - knee
        for index in 0..<frames {
            let magnitude = abs(samples[index])
            guard magnitude > knee else { continue }
            let shaped = knee + headroom * tanhf((magnitude - knee) / headroom)
            samples[index] = samples[index] < 0 ? -shaped : shaped
        }
    }

    private func write(_ outputs: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int) {
        var totalChannels = 0
        for buffer in outputs { totalChannels += Int(buffer.mNumberChannels) }
        let mono = totalChannels == 1 || leftChannel == rightChannel
        let leftIndex = leftChannel < totalChannels ? leftChannel : 0
        let rightIndex = rightChannel < totalChannels ? rightChannel : min(1, totalChannels - 1)

        var base = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { base += channels }
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            let count = min(frames, capacity - offset)
            guard count > 0 else { continue }
            for channel in 0..<channels {
                let target = data + offset * channels + channel
                let index = base + channel
                if mono && index == leftIndex {
                    for frame in 0..<count { target[frame * channels] = (left[frame] + right[frame]) * 0.5 }
                } else if !mono && index == leftIndex {
                    for frame in 0..<count { target[frame * channels] = left[frame] }
                } else if !mono && index == rightIndex {
                    for frame in 0..<count { target[frame * channels] = right[frame] }
                } else {
                    for frame in 0..<count { target[frame * channels] = 0 }
                }
            }
        }
    }

    private static func clear(_ outputs: UnsafeMutableAudioBufferListPointer, from start: Int, to end: Int) {
        guard end > start else { return }
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            let upper = min(end, capacity)
            guard upper > start else { continue }
            (data + start * channels).update(repeating: 0, count: (upper - start) * channels)
        }
    }
}

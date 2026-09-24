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
    fileprivate static let q = 1.41
}

/// Gain and EQ for one processing stage, as published to the audio threads.
struct StageParameters: Sendable {
    var gainLeft: Float = 1
    var gainRight: Float = 1
    var eqEnabled = false
    var eqGains = SIMD16<Float>()
    var eqGeneration: UInt32 = 0

    var canBoost: Bool {
        max(gainLeft, gainRight) > 1 || (eqEnabled && eqGains.max() > 0)
    }
}

/// UI-side handle for a stage. Audio threads read it with a try-lock and never block.
final class StageControl: Sendable {
    private let parameters = OSAllocatedUnfairLock(initialState: StageParameters())

    func update(gainLeft: Double, gainRight: Double, eq: EQSettings) {
        var bands = SIMD16<Float>()
        for (band, gain) in eq.gains.prefix(Equalizer.bandCount).enumerated() { bands[band] = Float(gain) }
        let gains = bands
        let enabled = eq.isActive
        let preamp = enabled ? Float(pow(10, eq.preamp / 20)) : 1
        parameters.withLock {
            $0.gainLeft = Float(gainLeft) * preamp
            $0.gainRight = Float(gainRight) * preamp
            if $0.eqEnabled != enabled || $0.eqGains != gains {
                $0.eqEnabled = enabled
                $0.eqGains = gains
                $0.eqGeneration &+= 1
            }
        }
    }

    var current: StageParameters { parameters.withLock { $0 } }
    func snapshot() -> StageParameters? { parameters.withLockIfAvailable { $0 } }
}

/// Filter and gain state for one stage of one route. Only the route's IO thread touches it.
final class StageProcessor {
    private let control: StageControl
    private let sampleRate: Double
    private var parameters: StageParameters
    private var generation: UInt32
    private var gainLeft: Float
    private var gainRight: Float
    private var activeBands: UInt16 = 0
    /// Per band: cos(w0), alpha for the fixed centre frequency.
    private let shape = UnsafeMutablePointer<Double>.allocate(capacity: Equalizer.bandCount * 2)
    /// Per band: b0 b1 b2 a1 a2.
    private let coefficients = UnsafeMutablePointer<Double>.allocate(capacity: Equalizer.bandCount * 5)
    /// Per band: left z1 z2, right z1 z2.
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: Equalizer.bandCount * 4)

    init(control: StageControl, sampleRate: Double) {
        self.control = control
        self.sampleRate = sampleRate
        parameters = control.current
        generation = parameters.eqGeneration &- 1
        gainLeft = parameters.gainLeft
        gainRight = parameters.gainRight
        coefficients.initialize(repeating: 0, count: Equalizer.bandCount * 5)
        state.initialize(repeating: 0, count: Equalizer.bandCount * 4)
        for (band, frequency) in Equalizer.frequencies.enumerated() {
            let omega = 2 * Double.pi * frequency / sampleRate
            // Bands too close to Nyquist are left flat.
            shape[band * 2] = frequency < sampleRate * 0.45 ? cos(omega) : .nan
            shape[band * 2 + 1] = sin(omega) / (2 * Equalizer.q)
        }
    }

    deinit {
        shape.deallocate()
        coefficients.deallocate()
        state.deallocate()
    }

    var canBoost: Bool { parameters.canBoost || max(gainLeft, gainRight) > 1 }
    var isSilent: Bool { gainLeft == 0 && gainRight == 0 && parameters.gainLeft == 0 && parameters.gainRight == 0 }

    /// Pulls the latest parameters; call once per IO cycle before `process`.
    func refresh() {
        if let latest = control.snapshot() { parameters = latest }
        if parameters.eqGeneration != generation { updateCoefficients() }
    }

    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        if activeBands != 0 {
            for band in 0..<Equalizer.bandCount where activeBands & (1 << band) != 0 {
                let c = coefficients + band * 5
                Self.filter(left, frames: frames, c, state + band * 4)
                Self.filter(right, frames: frames, c, state + band * 4 + 2)
            }
        }
        Self.applyGain(left, frames: frames, from: gainLeft, to: parameters.gainLeft)
        Self.applyGain(right, frames: frames, from: gainRight, to: parameters.gainRight)
        gainLeft = parameters.gainLeft
        gainRight = parameters.gainRight
    }

    private func updateCoefficients() {
        var active: UInt16 = 0
        for band in 0..<Equalizer.bandCount {
            let gain = Double(parameters.eqGains[band])
            let cosine = shape[band * 2]
            guard parameters.eqEnabled, gain != 0, !cosine.isNaN else { continue }
            if activeBands & (1 << band) == 0 {
                (state + band * 4).update(repeating: 0, count: 4)
            }
            active |= 1 << band
            let amplitude = pow(10, gain / 40)
            let alpha = shape[band * 2 + 1]
            let a0 = 1 + alpha / amplitude
            let c = coefficients + band * 5
            c[0] = (1 + alpha * amplitude) / a0
            c[1] = -2 * cosine / a0
            c[2] = (1 - alpha * amplitude) / a0
            c[3] = -2 * cosine / a0
            c[4] = (1 - alpha / amplitude) / a0
        }
        activeBands = active
        generation = parameters.eqGeneration
    }

    private static func filter(
        _ samples: UnsafeMutablePointer<Float>,
        frames: Int,
        _ c: UnsafeMutablePointer<Double>,
        _ z: UnsafeMutablePointer<Double>
    ) {
        let (b0, b1, b2, a1, a2) = (c[0], c[1], c[2], c[3], c[4])
        var z1 = z[0], z2 = z[1]
        for i in 0..<frames {
            let x = Double(samples[i])
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            samples[i] = Float(y)
        }
        // Flush denormals and recover from any blow-up.
        z[0] = z1.isFinite && abs(z1) > 1e-18 ? z1 : 0
        z[1] = z2.isFinite && abs(z2) > 1e-18 ? z2 : 0
    }

    private static func applyGain(_ samples: UnsafeMutablePointer<Float>, frames: Int, from start: Float, to end: Float) {
        if start == end {
            guard end != 1 else { return }
            var gain = end
            vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frames))
        } else {
            var gain = start
            var step = (end - start) / Float(frames)
            vDSP_vrampmul(samples, 1, &gain, &step, samples, 1, vDSP_Length(frames))
        }
    }
}

/// Renders one tap into one output device: app stage → device stage → limiter → channel mapping.
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
    private let sampleRate: Float
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private var limiterGain: Float = 1

    /// `leftChannel`/`rightChannel` are zero-based indices across all output channels of the device.
    /// `tapLeftChannel`/`tapRightChannel` pick the stereo pair out of a tap that carries a device's own channels.
    init(
        sampleRate: Double, appStage: StageProcessor?, deviceStage: StageProcessor?, leftChannel: Int, rightChannel: Int,
        tapLeftChannel: Int = 0, tapRightChannel: Int = 1
    ) {
        self.sampleRate = Float(sampleRate)
        self.appStage = appStage
        self.deviceStage = deviceStage
        self.leftChannel = leftChannel
        self.rightChannel = rightChannel
        self.tapLeftChannel = tapLeftChannel
        self.tapRightChannel = tapRightChannel
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
        if appStage?.isSilent == true {
            Self.clear(outputs, from: 0, to: outputFrames)
            return
        }

        let boosting = appStage?.canBoost == true || deviceStage?.canBoost == true
        var offset = 0
        while offset < frames {
            let count = min(Self.capacity, frames - offset)
            deinterleave(source + offset * inputChannels, channels: inputChannels, frames: count)
            appStage?.process(left, right, frames: count)
            deviceStage?.process(left, right, frames: count)
            limit(frames: count, boosting: boosting)
            write(outputs, offset: offset, frames: count)
            offset += count
        }
        Self.clear(outputs, from: frames, to: outputFrames)
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
            : limiterGain + (target - limiterGain) * (1 - expf(-Float(frames) / (0.25 * sampleRate)))
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

import AudioToolbox
import CoreAudio
import Foundation

struct RouteKey: Hashable {
    enum Source: Hashable {
        case app(String)
        /// Everything playing on the system default device that no app route takes over.
        case system
    }

    let source: Source
    /// Output device the route renders to.
    let deviceUID: String
    /// The device whose audio is taken, or `nil` for all of an app's audio wherever it plays. Part of the key:
    /// an app processed on a device and copied there from the default device has two routes to it.
    let tapDeviceUID: String?
}

struct RouteSpec: Equatable {
    let key: RouteKey
    /// Tapped processes for app routes; excluded processes for system routes. Sorted.
    var processes: [AudioObjectID]
    /// `.mutedWhenTapped` replaces the source with FreeAudio's rendering, `.unmuted` adds a copy,
    /// and `.muted` keeps the source silent even before the route starts.
    var mute: CATapMuteBehavior

    var tapDeviceUID: String? { key.tapDeviceUID }

    func canUpdateInPlace(to other: RouteSpec) -> Bool {
        key == other.key && mute == other.mute
    }
}

/// A process tap rendered into one output device through a private aggregate device.
///
/// The aggregate auto-starts when the tapped audio begins, so an idle route costs nothing;
/// `rearm()` returns a running route to that waiting state once its source goes quiet.
final class AudioRoute {
    private(set) var spec: RouteSpec
    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var renderer: RouteRenderer?
    private var observedCycles: UInt64 = 0

    init(spec: RouteSpec, appControl: StageControl?, deviceControl: StageControl?) throws {
        self.spec = spec
        description = Self.makeDescription(spec)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "error.create_process_tap")
        let deviceUID = spec.key.deviceUID

        do {
            let configuration = Self.aggregateConfiguration(deviceUID: deviceUID, tapDeviceUID: spec.tapDeviceUID, tap: description.uuid)
            try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregateID), "error.create_mixer_output")

            let sampleRate = CA.value(aggregateID, CA.address(kAudioDevicePropertyNominalSampleRate), fallback: Float64(48_000))
            let stereo = Self.stereoPair(of: deviceUID)
            // A device tap carries that device's channels, with the audio on its stereo pair.
            let tapStereo = spec.tapDeviceUID.map(Self.stereoPair(of:)) ?? (left: 0, right: 1)
            let renderer = RouteRenderer(
                sampleRate: sampleRate,
                appStage: appControl.map { StageProcessor(control: $0, sampleRate: sampleRate) },
                deviceStage: deviceControl.map { StageProcessor(control: $0, sampleRate: sampleRate) },
                leftChannel: stereo.left,
                rightChannel: stereo.right,
                tapLeftChannel: tapStereo.left,
                tapRightChannel: tapStereo.right
            )
            self.renderer = renderer
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, renderer.makeIOBlock()), "error.create_audio_processor")
            disableDeviceInputs()
            try check(AudioDeviceStart(aggregateID, ioProcID), "error.start_audio_processor")
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    /// Changes the tapped (or excluded) processes without rebuilding the route.
    func updateProcesses(_ processes: [AudioObjectID]) -> Bool {
        guard processes != spec.processes else { return true }
        description.processes = processes
        var object: CATapDescription = description
        var address = CA.address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &object) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else { return false }
        spec.processes = processes
        return true
    }

    /// Whether the route rendered since the last poll, and how long its input has been silent
    /// (`nil` until the tap has delivered sound).
    func poll() -> (rendering: Bool, silentFor: TimeInterval?) {
        guard let renderer else { return (false, nil) }
        let cycles = renderer.cycles.load(ordering: .relaxed)
        defer { observedCycles = cycles }
        let lastSound = renderer.lastSound.load(ordering: .relaxed)
        let silentFor = lastSound == 0 ? nil : Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - lastSound) / 1e9
        return (cycles != observedCycles, silentFor)
    }

    /// Stops the route so it waits for the source's next audio.
    func rearm() {
        guard let ioProcID else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        AudioDeviceStart(aggregateID, ioProcID)
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    static func makeDescription(_ spec: RouteSpec) -> CATapDescription {
        // A device tap keeps the device's own channels, which the renderer reads. Asked for a mixdown, it takes the
        // processes' audio from every device instead, so a route would play an app wherever it had ever played.
        let description = switch (spec.key.source, spec.tapDeviceUID) {
        case (.app, nil): CATapDescription(stereoMixdownOfProcesses: spec.processes)
        case (.app, let device?): CATapDescription(processes: spec.processes, deviceUID: device, stream: 0)
        case (.system, nil): CATapDescription(stereoGlobalTapButExcludeProcesses: spec.processes)
        case (.system, let device?): CATapDescription(excludingProcesses: spec.processes, deviceUID: device, stream: 0)
        }
        description.uuid = UUID()
        description.name = "FreeAudio"
        description.isPrivate = true
        description.muteBehavior = spec.mute
        return description
    }

    /// The device's stereo pair, zero-based across its output channels.
    private static func stereoPair(of uid: String) -> (left: Int, right: Int) {
        let pair = CA.device(uid: uid).map {
            CA.array($0, CA.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput), as: UInt32.self)
        } ?? []
        return (max(Int(pair.first ?? 1) - 1, 0), max(Int(pair.dropFirst().first ?? 2) - 1, 0))
    }

    private static func aggregateConfiguration(deviceUID: String, tapDeviceUID: String?, tap: UUID) -> [String: Any] {
        var configuration: [String: Any] = [
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
        ]
        // Aggregates don't nest, so an aggregate output (such as a Multi-Output Device) lends its members instead.
        if let device = CA.device(uid: deviceUID),
           let composition = CA.dictionary(device, CA.address(kAudioAggregateDevicePropertyComposition)),
           composition[kAudioAggregateDeviceSubDeviceListKey] != nil {
            for key in [kAudioAggregateDeviceSubDeviceListKey, kAudioAggregateDeviceMainSubDeviceKey,
                        kAudioAggregateDeviceClockDeviceKey, kAudioAggregateDeviceIsStackedKey] {
                configuration[key] = composition[key]
            }
        }
        configuration[kAudioAggregateDeviceNameKey] = "FreeAudio"
        configuration[kAudioAggregateDeviceUIDKey] = "FreeAudio-\(UUID().uuidString)"
        configuration[kAudioAggregateDeviceIsPrivateKey] = true
        configuration[kAudioAggregateDeviceTapAutoStartKey] = true
        configuration[kAudioAggregateDeviceTapListKey] = [[
            kAudioSubTapUIDKey: tap.uuidString,
            // A tap of the device the route plays on runs on that device's clock. Compensating anyway resamples it,
            // which costs coreaudiod time and now and then drops a sample; only a tap of another device drifts.
            kAudioSubTapDriftCompensationKey: tapDeviceUID != deviceUID,
        ]]
        return configuration
    }

    /// Keeps the device's own inputs (e.g. a headset microphone) off; only the tap stream is read.
    private func disableDeviceInputs() {
        guard let ioProcID else { return }
        let count = CA.array(aggregateID, CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), as: AudioStreamID.self).count
        guard count > 1 else { return }

        var address = CA.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let size = offset + count * MemoryLayout<UInt32>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(count), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.stride, as: UInt32.self)
        // The aggregate lists the device's input streams first and the tap last.
        for index in 0..<count {
            raw.storeBytes(of: index == count - 1 ? 1 : 0, toByteOffset: offset + index * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), raw)
    }
}

struct AudioError: LocalizedError {
    let action: String
    let status: OSStatus
    var errorDescription: String? { LF("error.operation_failed", L(action), status) }
}

private func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw AudioError(action: action, status: status) }
}

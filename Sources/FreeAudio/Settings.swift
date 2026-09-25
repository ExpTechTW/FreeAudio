import Foundation

enum EQPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case flat, acoustic, bassBoost, bassCut, classical, dance, deep, electronic, hipHop, jazz, latin
    case loudness, lounge, piano, pop, rnb, rock, smallSpeakers, spokenWord, trebleBoost, trebleCut, vocal
    case custom

    var id: Self { self }
    var title: String { L("preset.\(rawValue)") }

    /// Preamp and band gains in dB for 32 Hz … 16 kHz; `nil` for `.custom` (the Music app's "Manual").
    var values: (preamp: Double, bands: [Double])? {
        gains.map { (0, $0) }
    }

    /// The Music app's built-in presets, read from its own preset store
    /// (`~/Library/Preferences/com.apple.Music.eq.plist`, key `eqps:129:EQPresets`, values in 1/100 dB).
    /// Every built-in preset leaves the preamp at 0 dB.
    private var gains: [Double]? {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .acoustic: [5.00, 4.90, 3.95, 1.05, 2.15, 1.75, 3.50, 4.10, 3.55, 2.15]
        case .bassBoost: [5.50, 4.25, 3.50, 2.50, 1.25, 0, 0, 0, 0, 0]
        case .bassCut: [-5.50, -4.25, -3.50, -2.50, -1.25, 0, 0, 0, 0, 0]
        case .classical: [4.75, 3.75, 3.00, 2.50, -1.50, -1.50, 0, 2.25, 3.25, 3.75]
        case .dance: [3.57, 6.55, 4.99, 0, 1.92, 3.65, 5.15, 4.54, 3.59, 0]
        case .deep: [4.95, 3.55, 1.75, 1.00, 2.85, 2.50, 1.45, -2.15, -3.55, -4.60]
        case .electronic: [4.25, 3.80, 1.20, 0, -2.15, 2.25, 0.85, 1.25, 3.95, 4.80]
        case .hipHop: [5.00, 4.25, 1.50, 3.00, -1.00, -1.00, 1.50, -0.50, 2.00, 3.00]
        case .jazz: [4.00, 3.00, 1.50, 2.25, -1.50, -1.50, 0, 1.50, 3.00, 3.75]
        case .latin: [4.50, 3.00, 0, 0, -1.50, -1.50, -1.50, 0, 3.00, 4.50]
        case .loudness: [6.00, 4.00, 0, 0, -2.00, 0, -1.00, -5.00, 5.00, 1.00]
        case .lounge: [-3.00, -1.50, -0.50, 1.50, 4.00, 2.50, 0, -1.50, 2.00, 1.00]
        case .piano: [3.00, 2.00, 0, 2.50, 3.00, 1.50, 3.50, 4.50, 3.00, 3.50]
        case .pop: [-1.50, -1.00, 0, 2.00, 4.00, 4.00, 2.00, 0, -1.00, -1.50]
        case .rnb: [2.62, 6.92, 5.65, 1.33, -2.19, -1.50, 2.32, 2.65, 3.00, 3.75]
        case .rock: [5.00, 4.00, 3.00, 1.50, -0.50, -1.00, 0.50, 2.50, 3.50, 4.50]
        case .smallSpeakers: [5.50, 4.25, 3.50, 2.50, 1.25, 0, -1.25, -2.50, -3.50, -4.25]
        case .spokenWord: [-3.46, -0.47, 0, 0.69, 3.46, 4.61, 4.84, 4.28, 2.54, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 1.25, 2.50, 3.50, 4.25, 5.50]
        case .trebleCut: [0, 0, 0, 0, 0, -1.25, -2.50, -3.50, -4.25, -5.50]
        case .vocal: [-1.50, -3.00, -3.00, 1.50, 3.75, 3.75, 3.00, 1.50, 0, -1.50]
        case .custom: nil
        }
    }
}

struct EQSettings: Codable, Equatable, Sendable {
    var enabled = false
    var preset = EQPreset.flat
    /// Gain before the bands, in dB, like the Music app's Preamp slider.
    var preamp = 0.0
    var gains = Array(repeating: 0.0, count: Equalizer.bandCount)

    var isActive: Bool { enabled && (preamp != 0 || gains.contains { $0 != 0 }) }

    mutating func apply(_ preset: EQPreset) {
        self.preset = preset
        if let values = preset.values {
            preamp = values.preamp
            gains = values.bands
        }
        enabled = true
    }

    mutating func setGain(_ gain: Double, band: Int) {
        gains[band] = gain.clamped(to: Equalizer.gainRange)
        matchPreset()
    }

    mutating func setPreamp(_ gain: Double) {
        preamp = gain.clamped(to: Equalizer.gainRange)
        matchPreset()
    }

    /// Edited values become "Manual" unless they equal a built-in preset, as in the Music app.
    private mutating func matchPreset() {
        preset = EQPreset.allCases.first { $0.values.map { $0.preamp == preamp && $0.bands == gains } ?? false } ?? .custom
        enabled = true
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        preset = (try? container.decodeIfPresent(EQPreset.self, forKey: .preset)) ?? .custom
        preamp = try container.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
        let stored = try container.decodeIfPresent([Double].self, forKey: .gains) ?? []
        gains = stored.count == Equalizer.bandCount ? stored : Array(repeating: 0, count: Equalizer.bandCount)
        // A named preset always uses its current official values.
        if let values = preset.values {
            preamp = values.preamp
            gains = values.bands
        }
    }
}

/// Everything FreeAudio remembers about one application, keyed by bundle identifier.
struct AppAudioSettings: Codable, Equatable, Sendable {
    var volume = 1.0
    var muted = false
    var balance = 0.0
    /// `nil` follows the system default output device.
    var outputUID: String?
    var multiOutput = false
    var extraOutputUIDs: [String] = []
    var excludeFromGlobal = false
    var eq = EQSettings()

    var isSilenced: Bool { muted || volume == 0 }
    var needsProcessing: Bool { muted || volume != 1 || balance != 0 || eq.isActive }
    var isDefault: Bool { self == AppAudioSettings() }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        balance = try container.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        outputUID = try container.decodeIfPresent(String.self, forKey: .outputUID)
        multiOutput = try container.decodeIfPresent(Bool.self, forKey: .multiOutput) ?? false
        extraOutputUIDs = try container.decodeIfPresent([String].self, forKey: .extraOutputUIDs) ?? []
        excludeFromGlobal = try container.decodeIfPresent(Bool.self, forKey: .excludeFromGlobal) ?? false
        eq = try container.decodeIfPresent(EQSettings.self, forKey: .eq) ?? EQSettings()
    }
}

/// Processing applied to everything FreeAudio plays through one output device, keyed by device UID.
struct DeviceAudioSettings: Codable, Equatable, Sendable {
    var balance = 0.0
    var eq = EQSettings()
    /// The level FreeAudio gives what it renders on a device without a volume control (e.g. HDMI), and its mute
    /// when the device has no mute control either. Devices with their own controls keep 100% and unmuted here.
    var volume = 1.0
    var muted = false

    var gain: Double { muted ? 0 : volume }
    var needsProcessing: Bool { balance != 0 || eq.isActive || gain != 1 }
    var isDefault: Bool { self == DeviceAudioSettings() }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        balance = try container.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        eq = try container.decodeIfPresent(EQSettings.self, forKey: .eq) ?? EQSettings()
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

/// A device's volume and mute, remembered across restarts.
struct DeviceLevel: Codable, Equatable, Sendable {
    var volume: Double
    var muted: Bool
}

struct PersistedState: Codable, Equatable {
    /// Puts back the devices, volumes and mutes below when FreeAudio starts.
    var remembersSound = true
    /// Uses only the chosen devices: new devices don't take over, and a missing one is never replaced.
    var locksDevices = true
    /// Moves the microphone to a headset's own microphone when the headset becomes the output.
    var inputFollowsOutput = false
    /// A device FreeAudio has never seen starts at 0% and muted.
    var newDevicesSilent = true
    /// Devices FreeAudio has seen, keyed like `deviceLevels`; `nil` until the first launch lists them.
    var knownDevices: [String]?
    /// Whether the chosen devices were set up for the lock. Earlier versions also recorded devices
    /// macOS switched to by itself, so those records aren't trusted.
    var lockSeeded = false
    /// How devices were before FreeAudio silenced them as stand-ins, keyed like `deviceLevels`.
    var silencedLevels: [String: DeviceLevel] = [:]
    /// The output and input device last chosen, keyed by `DeviceDirection.key`.
    var preferredDevices: [String: String] = [:]
    /// Volume and mute per device, keyed "output:<uid>" or "input:<uid>".
    var deviceLevels: [String: DeviceLevel] = [:]
    /// Microphones muted in FreeAudio, by UID; they stay muted until they're unmuted in FreeAudio (`MicrophoneHold`).
    /// `nil` until the first launch takes over the mutes already in place.
    var mutedMicrophones: [String]?
    /// Volumes to give back when a microphone held at zero is unmuted in FreeAudio, by UID.
    var parkedMicrophones: [String: Double] = [:]
    var perAppEnabled = true
    var globalMultiOutput = false
    var globalOutputUIDs: [String] = []
    var apps: [String: AppAudioSettings] = [:]
    var appNames: [String: String] = [:]
    var devices: [String: DeviceAudioSettings] = [:]
    var deviceNames: [String: String] = [:]

    private static let key = "FreeAudio.state.v1"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remembersSound = try container.decodeIfPresent(Bool.self, forKey: .remembersSound) ?? true
        locksDevices = try container.decodeIfPresent(Bool.self, forKey: .locksDevices) ?? true
        lockSeeded = try container.decodeIfPresent(Bool.self, forKey: .lockSeeded) ?? false
        inputFollowsOutput = try container.decodeIfPresent(Bool.self, forKey: .inputFollowsOutput) ?? false
        newDevicesSilent = try container.decodeIfPresent(Bool.self, forKey: .newDevicesSilent) ?? true
        knownDevices = try container.decodeIfPresent([String].self, forKey: .knownDevices)
        silencedLevels = try container.decodeIfPresent([String: DeviceLevel].self, forKey: .silencedLevels) ?? [:]
        preferredDevices = try container.decodeIfPresent([String: String].self, forKey: .preferredDevices) ?? [:]
        deviceLevels = try container.decodeIfPresent([String: DeviceLevel].self, forKey: .deviceLevels) ?? [:]
        mutedMicrophones = try container.decodeIfPresent([String].self, forKey: .mutedMicrophones)
        parkedMicrophones = try container.decodeIfPresent([String: Double].self, forKey: .parkedMicrophones) ?? [:]
        perAppEnabled = try container.decodeIfPresent(Bool.self, forKey: .perAppEnabled) ?? true
        globalMultiOutput = try container.decodeIfPresent(Bool.self, forKey: .globalMultiOutput) ?? false
        globalOutputUIDs = try container.decodeIfPresent([String].self, forKey: .globalOutputUIDs) ?? []
        apps = try container.decodeIfPresent([String: AppAudioSettings].self, forKey: .apps) ?? [:]
        appNames = try container.decodeIfPresent([String: String].self, forKey: .appNames) ?? [:]
        devices = try container.decodeIfPresent([String: DeviceAudioSettings].self, forKey: .devices) ?? [:]
        deviceNames = try container.decodeIfPresent([String: String].self, forKey: .deviceNames) ?? [:]
    }

    static func load() -> PersistedState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return PersistedState() }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

extension Double {
    /// Left/right gains for a balance value in -1 (left) … 1 (right).
    var balanceGains: (left: Double, right: Double) {
        (self > 0 ? 1 - self : 1, self < 0 ? 1 + self : 1)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

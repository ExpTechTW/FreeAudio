import AudioToolbox
import CoreAudio
import Foundation
import IOKit.ps

enum DeviceDirection: Sendable {
    case input, output

    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    /// Stable name for saved settings.
    var key: String { self == .input ? "input" : "output" }
}

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let symbol: String
}

enum AudioDevices {
    static func list(_ direction: DeviceDirection) -> [AudioDevice] {
        CA.array(CA.system, CA.address(kAudioHardwarePropertyDevices), as: AudioDeviceID.self).compactMap { id in
            guard !CA.array(id, CA.address(kAudioDevicePropertyStreams, scope: direction.scope), as: AudioStreamID.self).isEmpty,
                  CA.value(id, CA.address(kAudioDevicePropertyIsHidden), fallback: UInt32(0)) == 0,
                  CA.value(id, CA.address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: direction.scope), fallback: UInt32(1)) != 0,
                  let uid = CA.string(id, CA.address(kAudioDevicePropertyDeviceUID)), !uid.hasPrefix("FreeAudio-"),
                  let rawName = CA.string(id, CA.address(kAudioObjectPropertyName)) else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            let transport = CA.value(id, CA.address(kAudioDevicePropertyTransportType), fallback: UInt32(0))
            return AudioDevice(id: id, uid: uid, name: name, symbol: symbol(transport: transport, name: name, direction: direction))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The microphone of the same physical device as an output (e.g. a headset's), matched exactly.
    static func pairedInput(for output: AudioDevice, among inputs: [AudioDevice]) -> AudioDevice? {
        // One device with both directions, e.g. a USB headset.
        if let same = inputs.first(where: { $0.uid == output.uid }) { return same }
        // Devices macOS reports as one piece of hardware, e.g. the built-in speakers and microphone.
        let related = Set(CA.array(output.id, CA.address(kAudioDevicePropertyRelatedDevices), as: AudioDeviceID.self))
        if let match = inputs.first(where: { related.contains($0.id) && $0.id != output.id }) { return match }
        // Bluetooth headsets list their halves as "<address>:output" and "<address>:input".
        if output.uid.hasSuffix(":output") {
            let input = output.uid.dropLast("output".count) + "input"
            return inputs.first { $0.uid == input }
        }
        return nil
    }

    static func defaultDevice(_ direction: DeviceDirection) -> AudioDeviceID {
        CA.value(CA.system, defaultAddress(direction), fallback: AudioDeviceID(kAudioObjectUnknown))
    }

    static func setDefault(_ id: AudioDeviceID, _ direction: DeviceDirection) {
        let previous = defaultDevice(direction)
        CA.set(CA.system, defaultAddress(direction), value: id)
        // Keep alerts on the same device when they were following the main output, like the Sound menu does.
        let alerts = CA.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        if direction == .output, CA.value(CA.system, alerts, fallback: AudioDeviceID(kAudioObjectUnknown)) == previous {
            CA.set(CA.system, alerts, value: id)
        }
    }

    // MARK: Volume

    static func volume(_ id: AudioDeviceID, _ direction: DeviceDirection) -> Double? {
        CA.optionalValue(id, volumeAddress(direction), as: Float32.self, zero: 0).map(Double.init)
    }

    static func canSetVolume(_ id: AudioDeviceID, _ direction: DeviceDirection) -> Bool {
        CA.isSettable(id, volumeAddress(direction))
    }

    static func setVolume(_ volume: Double, _ id: AudioDeviceID, _ direction: DeviceDirection) {
        CA.set(id, volumeAddress(direction), value: Float32(volume.clamped(to: 0...1)))
    }

    // MARK: Mute

    /// Mute controls on the main element, or per channel when the device has no main mute.
    private static func muteAddresses(_ id: AudioDeviceID, _ direction: DeviceDirection) -> [AudioObjectPropertyAddress] {
        let main = CA.address(kAudioDevicePropertyMute, scope: direction.scope)
        if CA.isSettable(id, main) { return [main] }
        return [1, 2].map { CA.address(kAudioDevicePropertyMute, scope: direction.scope, element: $0) }.filter { CA.isSettable(id, $0) }
    }

    static func canMute(_ id: AudioDeviceID, _ direction: DeviceDirection) -> Bool {
        !muteAddresses(id, direction).isEmpty
    }

    static func isMuted(_ id: AudioDeviceID, _ direction: DeviceDirection) -> Bool {
        let addresses = muteAddresses(id, direction)
        return !addresses.isEmpty && addresses.allSatisfy { CA.value(id, $0, fallback: UInt32(0)) != 0 }
    }

    static func setMuted(_ muted: Bool, _ id: AudioDeviceID, _ direction: DeviceDirection) {
        for address in muteAddresses(id, direction) { CA.set(id, address, value: UInt32(muted ? 1 : 0)) }
    }

    /// Properties whose changes mean the volume or mute state should be re-read.
    static func observedAddresses(_ direction: DeviceDirection) -> [AudioObjectPropertyAddress] {
        [volumeAddress(direction)] + [kAudioObjectPropertyElementMain, 1, 2].flatMap { element in
            [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].map {
                CA.address($0, scope: direction.scope, element: element)
            }
        }
    }

    private static func defaultAddress(_ direction: DeviceDirection) -> AudioObjectPropertyAddress {
        CA.address(direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func volumeAddress(_ direction: DeviceDirection) -> AudioObjectPropertyAddress {
        CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope)
    }

    // MARK: Icons

    private static func symbol(transport: UInt32, name: String, direction: DeviceDirection) -> String {
        let lowercased = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return isLaptop ? "laptopcomputer" : direction == .input ? "mic" : "desktopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lowercased.contains("airpods max") { return "airpods.max" }
            if lowercased.contains("airpods pro") { return "airpods.pro" }
            if lowercased.contains("airpods") { return "airpods" }
            if lowercased.contains("beats") { return "beats.headphones" }
            return lowercased.contains("speaker") ? "hifispeaker" : "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            return lowercased.contains("tv") ? "tv" : "display"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return "waveform"
        default:
            if direction == .input { return "mic" }
            return ["headphone", "headset", "耳機", "ヘッドホン"].contains(where: lowercased.contains) ? "headphones" : "hifispeaker"
        }
    }

    private static let isLaptop: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
}

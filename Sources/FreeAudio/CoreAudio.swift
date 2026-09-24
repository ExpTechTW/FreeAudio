import CoreAudio
import Foundation

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return object != kAudioObjectUnknown && AudioObjectHasProperty(object, &address)
    }

    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, fallback: T) -> T {
        optionalValue(object, address, as: T.self, zero: fallback) ?? fallback
    }

    static func optionalValue<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as: T.Type, zero: T) -> T? {
        var address = address
        var result = zero
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? result : nil
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, value: T) -> OSStatus {
        var address = address
        return withUnsafeBytes(of: value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32($0.count), $0.baseAddress!)
        }
    }

    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as: T.Type) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { buffer, count in
            var actualSize = size
            count = AudioObjectGetPropertyData(object, &address, 0, nil, &actualSize, buffer.baseAddress!) == noErr
                ? Int(actualSize) / MemoryLayout<T>.stride : 0
        }
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard withUnsafeMutablePointer(to: &result, {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }) == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    static func dictionary(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [String: Any]? {
        var address = address
        var result: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard has(object, address), withUnsafeMutablePointer(to: &result, {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }) == noErr, let result else { return nil }
        return result.takeRetainedValue() as? [String: Any]
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var result: DarwinBoolean = false
        return has(object, address) && AudioObjectIsPropertySettable(object, &address, &result) == noErr && result.boolValue
    }

    static func device(uid: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// Keeps a Core Audio property listener alive; removing it on `cancel()` or deinit.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var active: Bool

    init?(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping @MainActor () -> Void) {
        guard CA.has(object, address) else { return nil }
        self.object = object
        self.address = address
        block = { _, _ in MainActor.assumeIsolated { handler() } }
        active = AudioObjectAddPropertyListenerBlock(object, &self.address, .main, block) == noErr
        if !active { return nil }
    }

    func cancel() {
        guard active else { return }
        active = false
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }

    deinit { cancel() }
}

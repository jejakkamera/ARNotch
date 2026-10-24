import Foundation
import CoreAudio

/// All calls run on ConnectivityStore's serial utility queue. No capture session or microphone access.
enum ConnectivityAudio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func number<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, initial: T) -> T? {
        var property = property
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var pointer: UnsafeRawPointer?
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &pointer) == noErr,
              let pointer else { return nil }
        // Core Audio transfers ownership of CFString properties to the caller.
        return Unmanaged<CFString>.fromOpaque(pointer).takeRetainedValue() as String
    }

    private static func canWrite(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(object, &property)
            && AudioObjectIsPropertySettable(object, &property, &settable) == noErr && settable.boolValue
    }

    private static func channels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func volumeProperties(_ device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let main = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        if canWrite(device, main), number(device, main, initial: Float32(0)) != nil { return [main] }
        let count = channels(device, scope: kAudioObjectPropertyScopeOutput)
        guard count > 0, count < 65 else { return [] }
        let properties = (1...count).map {
            address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: UInt32($0))
        }
        // Never move only one side of a stereo headset.
        return properties.allSatisfy { canWrite(device, $0) && number(device, $0, initial: Float32(0)) != nil }
            ? properties : []
    }

    static func scan() -> [ConnectedAudio] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty else { return [] }
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        let current = number(system, address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioDeviceID(0))
        return devices.compactMap { device -> ConnectedAudio? in
            guard number(device, address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) == 1,
                  let uid = string(device, kAudioDevicePropertyDeviceUID),
                  let name = string(device, kAudioObjectPropertyName) else { return nil }
            let transport = number(device, address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
            guard transport != kAudioDeviceTransportTypeVirtual, transport != kAudioDeviceTransportTypeAggregate else { return nil }
            let output = channels(device, scope: kAudioObjectPropertyScopeOutput) > 0
            let input = channels(device, scope: kAudioObjectPropertyScopeInput) > 0
            guard output || input else { return nil }
            let controls = output ? volumeProperties(device) : []
            let levels = controls.compactMap { number(device, $0, initial: Float32(0)) }
            let volume: Double? = levels.isEmpty ? nil : Double(levels.reduce(0, +)) / Double(levels.count)
            let muteProperty = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            let mute: UInt32? = output ? number(device, muteProperty, initial: UInt32(0)) : nil
            return ConnectedAudio(deviceID: device, uid: uid, name: name, transport: transportName(transport),
                                  hasOutput: output, hasInput: input, isDefault: current == device,
                                  volume: volume.map { min(max($0, 0), 1) }, canSetVolume: !controls.isEmpty,
                                  isMuted: mute.map { $0 != 0 }, canMute: output && mute != nil && canWrite(device, muteProperty))
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            if $0.hasOutput != $1.hasOutput { return $0.hasOutput }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Check the UID again: an AudioDeviceID can be recycled after a disconnect.
    private static func isCurrent(_ device: ConnectedAudio) -> Bool {
        string(device.deviceID, kAudioDevicePropertyDeviceUID) == device.uid
            && number(device.deviceID, address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) == 1
    }

    private static func set<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, _ value: T) -> Bool {
        guard canWrite(object, property) else { return false }
        var property = property
        var value = value
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
        }
    }

    static func setVolume(_ volume: Double, on device: ConnectedAudio) -> Bool {
        guard volume.isFinite, isCurrent(device) else { return false }
        let properties = volumeProperties(device.deviceID)
        guard !properties.isEmpty else { return false }
        var succeeded = true
        for property in properties {
            if !set(device.deviceID, property, Float32(min(max(volume, 0), 1))) { succeeded = false }
        }
        return succeeded
    }

    static func setMuted(_ muted: Bool, on device: ConnectedAudio) -> Bool {
        guard isCurrent(device), device.hasOutput else { return false }
        return set(device.deviceID, address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput), UInt32(muted ? 1 : 0))
    }

    static func select(_ device: ConnectedAudio) -> Bool {
        guard isCurrent(device), device.hasOutput else { return false }
        return set(system, address(kAudioHardwarePropertyDefaultOutputDevice), device.deviceID)
    }

    private static func transportName(_ value: UInt32) -> String {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default: return "Audio device"
        }
    }
}

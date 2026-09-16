import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let audioObjectID: AudioObjectID
    let transportType: UInt32

    /// Bluetooth microphones appear, vanish and change format while the
    /// headset switches profiles, so they get different handling.
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum AudioInputDeviceManager {
    static func availableDevices() -> [AudioInputDevice] {
        allAudioDeviceIDs()
            .filter(hasInputStreams)
            .compactMap { audioObjectID in
                guard let uid = stringProperty(
                    kAudioDevicePropertyDeviceUID,
                    of: audioObjectID
                ), let name = stringProperty(
                    kAudioObjectPropertyName,
                    of: audioObjectID
                ) else {
                    return nil
                }

                return AudioInputDevice(
                    id: uid,
                    name: name,
                    audioObjectID: audioObjectID,
                    transportType: transportType(of: audioObjectID)
                )
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    static func device(for uid: String) -> AudioInputDevice? {
        availableDevices().first { $0.id == uid }
    }

    static func audioObjectID(forDeviceUID uid: String) -> AudioObjectID? {
        device(for: uid)?.audioObjectID
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        guard let audioObjectID = defaultInputDeviceID() else { return nil }
        return availableDevices().first { $0.audioObjectID == audioObjectID }
    }

    private static func defaultInputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var audioObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &audioObjectID
        )
        guard status == noErr, audioObjectID != kAudioObjectUnknown else { return nil }
        return audioObjectID
    }

    /// The microphone a recording should open: the saved device when it is
    /// connected, otherwise the current macOS default input.
    static func recordingDevice(preferredDeviceUID: String?) -> AudioInputDevice? {
        let devices = availableDevices()
        // A disconnected saved microphone falls back to the current macOS
        // default. If it reconnects, its persisted UID is used again.
        if let preferredDeviceUID,
           let preferred = devices.first(where: { $0.id == preferredDeviceUID }) {
            return preferred
        }
        guard let defaultID = defaultInputDeviceID() else { return nil }
        return devices.first { $0.audioObjectID == defaultID }
    }

    /// Whether the engine's input unit should be pinned to the device.
    ///
    /// Pinned to a wired microphone, the engine starts in tens of
    /// milliseconds instead of building an aggregate with the current output
    /// device, which costs about half a second. A Bluetooth headset that is
    /// already the system default is left unpinned: its microphone comes and
    /// goes while the headset switches profiles, and the engine's own
    /// default-device tracking follows that better than a fixed device ID.
    /// A Bluetooth headset the user chose over a different default still has
    /// to be pinned, or the recording would use the wrong microphone.
    static func shouldPin(_ device: AudioInputDevice, isSystemDefault: Bool) -> Bool {
        !(device.isBluetooth && isSystemDefault)
    }

    /// Selects the recording device on the engine's input unit and returns
    /// it, or nil when no input device exists.
    @discardableResult
    static func configure(
        _ inputNode: AVAudioInputNode,
        preferredDeviceUID: String?
    ) throws -> AudioInputDevice? {
        guard let device = recordingDevice(preferredDeviceUID: preferredDeviceUID) else {
            return nil
        }
        let isSystemDefault = defaultInputDeviceID() == device.audioObjectID
        guard shouldPin(device, isSystemDefault: isSystemDefault) else {
            return device
        }

        guard let audioUnit = inputNode.audioUnit else {
            throw LocalTranscriberError.audioInputConfigurationFailed(device.name)
        }

        var audioObjectID = device.audioObjectID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &audioObjectID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw LocalTranscriberError.audioInputConfigurationFailed(device.name)
        }
        return device
    }

    private static func transportType(of audioObjectID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            audioObjectID,
            &address,
            0,
            nil,
            &dataSize,
            &transportType
        )
        return status == noErr ? transportType : 0
    }

    private static func allAudioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var audioObjectIDs = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: count
        )
        let status = audioObjectIDs.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        return status == noErr ? audioObjectIDs : []
    }

    private static func hasInputStreams(_ audioObjectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            audioObjectID,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr && dataSize >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of audioObjectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            audioObjectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

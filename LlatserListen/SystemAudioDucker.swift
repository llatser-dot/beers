import AudioToolbox
import CoreAudio
import Foundation

/// Temporarily lowers the default output volume while push-to-talk is active,
/// then restores the previous level. This is what users mean by "Suppress Mac audio".
enum SystemAudioDucker {
    private static let lock = NSLock()
    private static var savedDeviceID: AudioDeviceID?
    private static var savedVolume: Float32?
    private static var savedMute: UInt32?
    private static var isDucked = false

    static func duckIfNeeded(enabled: Bool) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isDucked else { return }
        guard let deviceID = defaultOutputDeviceID() else {
            llog("SystemAudioDucker: could not find the default output device")
            return
        }

        savedDeviceID = deviceID
        savedMute = muteState(of: deviceID)
        savedVolume = volume(of: deviceID)

        // Prefer the hardware mute control. Some HDMI, AirPlay and aggregate
        // outputs do not expose it, so fall back to setting virtual volume to 0.
        let muted = setMute(true, on: deviceID)
        let silenced = muted || setVolume(0, on: deviceID)
        guard silenced else {
            clearSavedState()
            llog("SystemAudioDucker: output device does not expose mute or volume controls")
            return
        }
        isDucked = true
        llog("SystemAudioDucker: suppressed output using \(muted ? "mute" : "zero volume")")
    }

    static func restoreIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard isDucked, let deviceID = savedDeviceID else {
            isDucked = false
            clearSavedState()
            return
        }

        // Restore the exact device changed at capture start, even if the user
        // changes the default output while speaking.
        if let savedVolume {
            _ = setVolume(savedVolume, on: deviceID)
        }
        if let savedMute {
            _ = setMute(savedMute != 0, on: deviceID)
        }
        llog("SystemAudioDucker: restored output")
        isDucked = false
        clearSavedState()
    }

    private static func clearSavedState() {
        savedDeviceID = nil
        savedVolume = nil
        savedMute = nil
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func volume(of deviceID: AudioDeviceID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func setVolume(_ value: Float32, on deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume = max(0, min(1, value))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        return status == noErr
    }

    private static func muteState(of deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func setMute(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable = DarwinBoolean(false)
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }
}

import AudioToolbox
import CoreAudio
import Foundation

/// Temporarily lowers the default output volume while push-to-talk is active,
/// then restores the previous level. This is what users mean by "Suppress Mac audio".
enum SystemAudioDucker {
    private static let lock = NSLock()
    private static var savedVolume: Float32?
    private static var isDucked = false

    /// Fraction of the current volume to keep while ducked (0.12 ≈ quiet but audible).
    private static let duckFactor: Float32 = 0.12
    private static let absoluteFloor: Float32 = 0.02

    static func duckIfNeeded(enabled: Bool) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isDucked else { return }
        guard let deviceID = defaultOutputDeviceID(),
              let current = volume(of: deviceID) else {
            llog("SystemAudioDucker: could not read output volume")
            return
        }

        savedVolume = current
        let target = max(absoluteFloor, current * duckFactor)
        guard setVolume(target, on: deviceID) else {
            savedVolume = nil
            llog("SystemAudioDucker: failed to duck volume from \(String(format: "%.2f", current))")
            return
        }
        isDucked = true
        llog("SystemAudioDucker: ducked \(String(format: "%.2f", current)) → \(String(format: "%.2f", target))")
    }

    static func restoreIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard isDucked, let saved = savedVolume else {
            isDucked = false
            savedVolume = nil
            return
        }
        if let deviceID = defaultOutputDeviceID() {
            _ = setVolume(saved, on: deviceID)
            llog("SystemAudioDucker: restored volume to \(String(format: "%.2f", saved))")
        }
        isDucked = false
        savedVolume = nil
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
}

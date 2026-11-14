import CoreAudio
import Foundation

/// Which apps are using a microphone right now, from Core Audio's per-process
/// list (macOS 14.2+). App-agnostic: it sees Zoom, Teams, a browser tab on
/// Meet, Slack huddles, anything that opens audio input.
public enum MicUsage {
    /// Bundle IDs of processes currently capturing audio input, excluding
    /// figg. Processes without a bundle ID are reported by executable name.
    @available(macOS 14.2, *)
    public static func appsUsingInput() -> Set<String> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result = Set<String>()
        for process in processObjects() where isRunningInput(process) {
            let pid = pid(of: process)
            guard pid != ownPID else { continue }
            if let bundle = bundleID(of: process), !bundle.isEmpty {
                result.insert(bundle)
            } else if let name = processName(pid) {
                result.insert(name)
            }
        }
        return result
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    @available(macOS 14.2, *)
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    @available(macOS 14.2, *)
    private static func pid(of process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        return pid
    }

    @available(macOS 14.2, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

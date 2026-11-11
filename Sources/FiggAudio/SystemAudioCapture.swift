import AVFoundation
import CoreAudio
import Foundation

public enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case coreAudio(String, OSStatus)
    case unsupportedOS

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone is available."
        case let .coreAudio(step, status): return "System audio capture failed at \(step) (OSStatus \(status))."
        case .unsupportedOS: return "System audio capture needs macOS 14.2 or later."
        }
    }
}

/// Captures everything the Mac is playing (all processes except figg) using a
/// Core Audio process tap attached to a private aggregate device. No virtual
/// audio driver is needed and the user's output routing is untouched.
///
/// The first start triggers the "System Audio Recording" permission prompt.
/// If the user denies it, macOS delivers silence rather than an error.
@available(macOS 14.2, *)
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "figg.systemaudio", qos: .userInitiated)

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let ownPID = try Self.ownProcessObject()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownPID.map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "figg system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        var asbd = try Self.tapFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioCaptureError.coreAudio("read tap format", kAudioHardwareUnspecifiedError)
        }

        let debug = ProcessInfo.processInfo.environment["FIGG_AUDIO_DEBUG"] != nil
        if debug { print("DEBUG tap format: \(format)  asbd: \(asbd)") }
        var calls = 0
        try check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inData, _, _, _ in
            calls += 1
            let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inData, deallocator: nil)
            if debug, calls <= 3 || calls % 50 == 0 {
                let abl = inData.pointee
                print("DEBUG ioproc #\(calls) buffers=\(abl.mNumberBuffers) bytes=\(abl.mBuffers.mDataByteSize) frames=\(buffer?.frameLength ?? 0)")
            }
            guard let buffer else { return }
            onBuffer(buffer)
        })
        try check("start device", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if ProcessInfo.processInfo.environment["FIGG_AUDIO_DEBUG"] != nil { print("DEBUG stop") }
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            stop()
            throw AudioCaptureError.coreAudio(step, status)
        }
    }

    // MARK: Core Audio property helpers

    private static func ownProcessObject() throws -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        // figg has no audio process object until it plays sound; that is fine.
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw AudioCaptureError.coreAudio("default output device", status) }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw AudioCaptureError.coreAudio("output device UID", status) }
        return uid.takeRetainedValue() as String
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw AudioCaptureError.coreAudio("tap format", status) }
        return asbd
    }
}

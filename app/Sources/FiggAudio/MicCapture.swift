import AudioToolbox
import AVFoundation
import Foundation

/// Microphone input via AVAudioEngine.
final class MicCapture {
    private let engine = AVAudioEngine()

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Records from `device`, or the system default input when nil.
    /// Returns false when `device` could not be selected and the default is
    /// used instead: a mic that records beats none.
    @discardableResult
    func start(device: AudioDeviceID? = nil, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws -> Bool {
        let input = engine.inputNode
        var selected = device == nil
        if var device, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            selected = status == noErr
            if !selected { NSLog("figg recorder: could not pick microphone %u (%d); using the default", device, status) }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
        return selected
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

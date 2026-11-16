import AVFoundation

/// Converts buffers of any input format to 16 kHz mono Float32 samples.
/// Rebuilds its converter when the input format changes (a device switch).
final class MonoResampler {
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let outFormat = AudioChunk.format
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.downmix = true
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

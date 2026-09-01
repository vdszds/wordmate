import AVFoundation
import Foundation

enum AudioSampleLoader {
    static let sampleRate = 16_000.0

    static func loadMono16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard file.length > 0 else {
            throw LocalTranscriberError.emptyRecording
        }

        guard file.length <= AVAudioFramePosition(UInt32.max) else {
            throw LocalTranscriberError.recordingTooLong
        }

        let sourceFormat = file.processingFormat
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw LocalTranscriberError.audioConversionFailed
        }

        try file.read(into: sourceBuffer)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw LocalTranscriberError.audioConversionFailed
        }

        let ratio = sampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * ratio)) + 1_024
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetCapacity
        ) else {
            throw LocalTranscriberError.audioConversionFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .endOfStream
                return nil
            }

            suppliedInput = true
            outputStatus.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status == .haveData || status == .endOfStream,
              let channel = targetBuffer.floatChannelData?.pointee else {
            throw LocalTranscriberError.audioConversionFailed
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(targetBuffer.frameLength)))
    }
}

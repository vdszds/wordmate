import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// What the transcription screen shows about a file the user picked.
struct AudioFileSummary: Equatable, Sendable {
    let url: URL
    let name: String
    let format: String
    let duration: TimeInterval
    let byteCount: Int64
    let hasVideo: Bool
}

/// Decodes any media file macOS can read into Parakeet's 16 kHz mono input.
///
/// AVFoundation is tried first because it mixes every audio track, which keeps
/// the microphone of a screen recording that stores it separately from system
/// audio. AudioToolbox is the fallback for the older formats AVFoundation does
/// not open, such as `.snd` and `.sd2`.
enum AudioFileDecoder {
    /// `.audiovisualContent` covers most files; these extensions may not map to
    /// a type conforming to it on every supported macOS version.
    private static let additionalPickerExtensions = [
        "opus", "ogg", "oga", "flac", "amr", "awb", "ac3", "ec3", "eac3",
        "mp1", "mp2", "mpa", "m1a", "m2a", "m4b", "m4r", "caf", "au", "snd",
        "sd2", "aifc", "3gp", "3gpp", "3g2", "3gp2", "adts", "loas", "latm", "xhe",
    ]

    static let pickerContentTypes: [UTType] = [.audiovisualContent]
        + additionalPickerExtensions.compactMap { UTType(filenameExtension: $0) }

    static func summary(of url: URL) async throws -> AudioFileSummary {
        let asset = AVURLAsset(url: url)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []

        let duration: TimeInterval
        if !audioTracks.isEmpty,
           let assetDuration = try? await asset.load(.duration).seconds,
           assetDuration.isFinite,
           assetDuration > 0 {
            duration = assetDuration
        } else if let file = try? AVAudioFile(forReading: url) {
            duration = Double(file.length) / file.fileFormat.sampleRate
        } else if !videoTracks.isEmpty {
            throw LocalTranscriberError.noAudioTrack(url.lastPathComponent)
        } else {
            throw LocalTranscriberError.unsupportedAudioFile(url.lastPathComponent)
        }

        guard duration.isFinite, duration > 0 else {
            throw LocalTranscriberError.emptyRecording
        }

        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return AudioFileSummary(
            url: url,
            name: url.lastPathComponent,
            format: url.pathExtension.uppercased(),
            duration: duration,
            byteCount: Int64(byteCount),
            hasVideo: !videoTracks.isEmpty
        )
    }

    static func decodeMono16k(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [Float] {
        do {
            return try await decodeWithAssetReader(url, onProgress: onProgress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            do {
                return try decodeWithAudioFile(url, onProgress: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LocalTranscriberError.unsupportedAudioFile(url.lastPathComponent)
            }
        }
    }

    private static func decodeWithAssetReader(
        _ url: URL,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw LocalTranscriberError.noAudioTrack(url.lastPathComponent)
        }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioSampleLoader.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(output) else {
            throw LocalTranscriberError.audioConversionFailed
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? LocalTranscriberError.audioConversionFailed
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        var samples: [Float] = []
        if duration.isFinite, duration > 0 {
            samples.reserveCapacity(Int(duration * AudioSampleLoader.sampleRate) + 1_024)
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            let byteCount = CMBlockBufferGetDataLength(dataBuffer)
            let firstNewSample = samples.count
            samples.append(
                contentsOf: repeatElement(0, count: byteCount / MemoryLayout<Float>.size)
            )
            let status = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    dataBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: bytes.baseAddress!
                        .advanced(by: firstNewSample * MemoryLayout<Float>.size)
                )
            }
            guard status == kCMBlockBufferNoErr else {
                throw LocalTranscriberError.audioConversionFailed
            }

            if duration.isFinite, duration > 0 {
                let decodedSeconds = Double(samples.count) / AudioSampleLoader.sampleRate
                onProgress(min(1, decodedSeconds / duration))
            }
        }

        guard reader.status == .completed else {
            throw reader.error ?? LocalTranscriberError.audioConversionFailed
        }
        return samples
    }

    private static func decodeWithAudioFile(
        _ url: URL,
        onProgress: @Sendable (Double) -> Void
    ) throws -> [Float] {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard file.length > 0 else {
            throw LocalTranscriberError.emptyRecording
        }

        let sourceFormat = file.processingFormat
        let sourceFrameCapacity = AVAudioFrameCount(sourceFormat.sampleRate)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioSampleLoader.sampleRate,
            channels: 1,
            interleaved: false
        ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let sourceBuffer = AVAudioPCMBuffer(
                  pcmFormat: sourceFormat,
                  frameCapacity: sourceFrameCapacity
              ),
              let targetBuffer = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: AVAudioFrameCount(AudioSampleLoader.sampleRate)
              ) else {
            throw LocalTranscriberError.audioConversionFailed
        }
        // Without this the converter keeps only the first channel, which loses
        // one side of a stereo call recording.
        converter.downmix = true

        var samples: [Float] = []
        var readError: Error?
        var reachedEnd = false

        while true {
            try Task.checkCancellation()

            targetBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: targetBuffer,
                error: &conversionError
            ) { requestedFrames, inputStatus in
                guard !reachedEnd else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(
                        into: sourceBuffer,
                        frameCount: min(requestedFrames, sourceFrameCapacity)
                    )
                } catch {
                    // Some decoders throw instead of reading zero frames at
                    // the end of the file, so only an early stop is an error.
                    if file.framePosition < file.length {
                        readError = error
                    }
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard sourceBuffer.frameLength > 0 else {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return sourceBuffer
            }

            if let readError {
                throw readError
            }
            if let conversionError {
                throw conversionError
            }
            guard status != .error,
                  let channel = targetBuffer.floatChannelData?.pointee else {
                throw LocalTranscriberError.audioConversionFailed
            }

            samples.append(
                contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: Int(targetBuffer.frameLength)
                )
            )
            onProgress(min(1, Double(file.framePosition) / Double(file.length)))

            if status == .endOfStream {
                return samples
            }
        }
    }
}

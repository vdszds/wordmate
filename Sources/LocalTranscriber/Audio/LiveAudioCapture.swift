import AVFoundation
import FluidAudio
import Foundation

/// An owned, Sendable copy of a microphone buffer. AVAudioEngine reuses the
/// buffers delivered to its tap, so the live transcription pipeline must not
/// retain those buffers directly.
struct LiveAudioChunk: Sendable {
    let sampleRate: Double
    let channels: [[Float]]

    init?(copying buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)

        guard format.commonFormat == .pcmFormatFloat32,
              frameCount > 0,
              channelCount > 0,
              let source = buffer.floatChannelData else {
            return nil
        }

        sampleRate = format.sampleRate

        if format.isInterleaved {
            let interleaved = source[0]
            channels = (0..<channelCount).map { channelIndex in
                (0..<frameCount).map { frameIndex in
                    interleaved[frameIndex * channelCount + channelIndex]
                }
            }
        } else {
            channels = (0..<channelCount).map { channelIndex in
                Array(
                    UnsafeBufferPointer(
                        start: source[channelIndex],
                        count: frameCount
                    )
                )
            }
        }
    }

    init(mono16kSamples samples: [Float]) {
        sampleRate = AudioSampleLoader.sampleRate
        channels = [samples]
    }

    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let firstChannel = channels.first,
              !firstChannel.isEmpty,
              channels.allSatisfy({ $0.count == firstChannel.count }),
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: AVAudioChannelCount(channels.count),
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(firstChannel.count)
              ),
              let destination = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(firstChannel.count)
        for (channelIndex, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { source in
                guard let sourceAddress = source.baseAddress else { return }
                destination[channelIndex].update(
                    from: sourceAddress,
                    count: samples.count
                )
            }
        }
        return buffer
    }
}

/// Retains the microphone stream in its native format and converts the whole
/// recording to 16 kHz mono only when Parakeet needs a cumulative snapshot.
/// Resampling an entire continuous buffer avoids the rounding seams created by
/// independently converting every small audio callback.
struct LiveAudioAccumulator: Sendable {
    private(set) var sampleRate: Double?
    private(set) var channels: [[Float]] = []

    var duration: TimeInterval {
        guard let sampleRate,
              sampleRate > 0,
              let frameCount = channels.first?.count else { return 0 }
        return Double(frameCount) / sampleRate
    }

    mutating func append(_ chunk: LiveAudioChunk) throws {
        guard chunk.sampleRate > 0,
              !chunk.channels.isEmpty,
              let frameCount = chunk.channels.first?.count,
              frameCount > 0,
              chunk.channels.allSatisfy({ $0.count == frameCount }) else {
            throw LocalTranscriberError.audioConversionFailed
        }

        if let sampleRate {
            guard abs(sampleRate - chunk.sampleRate) < 0.5,
                  channels.count == chunk.channels.count else {
                throw LocalTranscriberError.audioConversionFailed
            }
        } else {
            sampleRate = chunk.sampleRate
            channels = Array(repeating: [], count: chunk.channels.count)
        }

        for index in chunk.channels.indices {
            channels[index].append(contentsOf: chunk.channels[index])
        }
    }

    func mono16kSamples() throws -> [Float] {
        guard let sampleRate,
              !channels.isEmpty,
              let frameCount = channels.first?.count,
              frameCount > 0 else {
            throw LocalTranscriberError.emptyRecording
        }

        let mono: [Float]
        if channels.count == 1 {
            mono = channels[0]
        } else {
            let scale = Float(1) / Float(channels.count)
            var mixed = Array(repeating: Float.zero, count: frameCount)
            for channel in channels {
                for index in channel.indices {
                    mixed[index] += channel[index] * scale
                }
            }
            mono = mixed
        }

        return try AudioConverter(
            sampleRate: AudioSampleLoader.sampleRate
        ).resample(mono, from: sampleRate)
    }
}

/// Bridges AVAudioEngine's synchronous real-time callback into one ordered
/// AsyncStream. The continuation is thread-safe; the lock only makes finishing
/// explicit and prevents late microphone callbacks from being queued.
final class LiveAudioCapture: @unchecked Sendable {
    let stream: AsyncStream<LiveAudioChunk>

    private let continuation: AsyncStream<LiveAudioChunk>.Continuation
    private let stateLock = NSLock()
    private var isFinished = false

    init() {
        var capturedContinuation: AsyncStream<LiveAudioChunk>.Continuation?
        stream = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let chunk = LiveAudioChunk(copying: buffer) else { return }

        stateLock.lock()
        let shouldYield = !isFinished
        stateLock.unlock()

        if shouldYield {
            continuation.yield(chunk)
        }
    }

    func finish() {
        stateLock.lock()
        guard !isFinished else {
            stateLock.unlock()
            return
        }
        isFinished = true
        stateLock.unlock()
        continuation.finish()
    }
}

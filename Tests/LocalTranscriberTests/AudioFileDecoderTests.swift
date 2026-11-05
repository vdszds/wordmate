import AVFoundation
import UniformTypeIdentifiers
import XCTest
@testable import LocalTranscriber

/// Fixtures are synthesized at run time; the public source export rejects
/// audio files in the repository.
final class AudioFileDecoderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioFileDecoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testDecodesFormatsToMono16k() async throws {
        let formats: [(name: String, settings: [String: Any])] = [
            ("tone.wav", pcmSettings),
            ("tone.aiff", pcmSettings.merging([AVLinearPCMIsBigEndianKey: true]) { $1 }),
            ("tone.caf", pcmSettings),
            // AVFoundation does not open .snd, so this covers the fallback path.
            ("tone.snd", pcmSettings.merging([AVLinearPCMIsBigEndianKey: true]) { $1 }),
            ("aac.m4a", compressedSettings(kAudioFormatMPEG4AAC)),
            ("alac.m4a", compressedSettings(kAudioFormatAppleLossless)),
            ("tone.flac", compressedSettings(kAudioFormatFLAC)),
        ]

        for format in formats {
            let url = try writeTone(named: format.name, settings: format.settings, seconds: 2)
            let samples = try await AudioFileDecoder.decodeMono16k(from: url)

            XCTAssertEqual(
                Double(samples.count) / AudioSampleLoader.sampleRate,
                2,
                accuracy: 0.1,
                format.name
            )
            XCTAssertGreaterThan(Self.peak(of: samples), 0.1, format.name)
        }
    }

    func testStereoFileWithSpeechOnOneSideIsNotSilent() async throws {
        let url = try writeTone(
            named: "right-only.wav",
            settings: pcmSettings,
            seconds: 1,
            silentLeftChannel: true
        )

        let samples = try await AudioFileDecoder.decodeMono16k(from: url)

        XCTAssertGreaterThan(Self.peak(of: samples), 0.05)
    }

    func testSummaryDescribesFile() async throws {
        let url = try writeTone(named: "memo.m4a", settings: compressedSettings(kAudioFormatMPEG4AAC), seconds: 3)

        let summary = try await AudioFileDecoder.summary(of: url)

        XCTAssertEqual(summary.name, "memo.m4a")
        XCTAssertEqual(summary.format, "M4A")
        XCTAssertEqual(summary.duration, 3, accuracy: 0.1)
        XCTAssertGreaterThan(summary.byteCount, 0)
        XCTAssertFalse(summary.hasVideo)
    }

    func testFileThatIsNotAudioIsRejectedByName() async throws {
        let url = directory.appendingPathComponent("notes.mp3")
        try Data("This is not audio.".utf8).write(to: url)

        await assertThrows(.unsupportedAudioFile("notes.mp3")) {
            _ = try await AudioFileDecoder.summary(of: url)
        }
        await assertThrows(.unsupportedAudioFile("notes.mp3")) {
            _ = try await AudioFileDecoder.decodeMono16k(from: url)
        }
    }

    func testMissingFileIsRejected() async throws {
        let url = directory.appendingPathComponent("gone.wav")

        await assertThrows(.unsupportedAudioFile("gone.wav")) {
            _ = try await AudioFileDecoder.summary(of: url)
        }
    }

    func testAudioFileWithNoFramesIsEmpty() async throws {
        let url = directory.appendingPathComponent("empty.wav")
        _ = try AVAudioFile(forWriting: url, settings: pcmSettings)

        await assertThrows(.emptyRecording) {
            _ = try await AudioFileDecoder.summary(of: url)
        }
    }

    func testDecodingStopsPartWayWhenCancelled() async throws {
        let url = try writeTone(named: "long.wav", settings: pcmSettings, seconds: 30)
        let task = Task {
            try await AudioFileDecoder.decodeMono16k(from: url) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testPickerAcceptsEveryAudiovisualFileAndCommonVoiceNoteFormats() {
        for fileExtension in ["mp3", "m4a", "wav", "flac", "ogg", "opus", "mp4", "mov", "aiff", "aac", "amr"] {
            let type = UTType(filenameExtension: fileExtension)
            XCTAssertTrue(
                AudioFileDecoder.pickerContentTypes.contains { allowed in
                    type?.conforms(to: allowed) == true
                },
                fileExtension
            )
        }
    }

    private let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    private func compressedSettings(_ format: AudioFormatID) -> [String: Any] {
        [
            AVFormatIDKey: format,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
        ]
    }

    private func writeTone(
        named name: String,
        settings: [String: Any],
        seconds: Double,
        silentLeftChannel: Bool = false
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        // The file closes when `file` goes out of scope at the end of the do.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = AVAudioFormat(
                standardFormatWithSampleRate: 44_100,
                channels: 2
            )!
            let frameCount = AVAudioFrameCount(seconds * 44_100)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            for frame in 0..<Int(frameCount) {
                let value = Float(sin(2 * Double.pi * 440 * Double(frame) / 44_100)) * 0.5
                buffer.floatChannelData![0][frame] = silentLeftChannel ? 0 : value
                buffer.floatChannelData![1][frame] = value
            }
            try file.write(from: buffer)
        }
        return url
    }

    private static func peak(of samples: [Float]) -> Float {
        samples.map(abs).max() ?? 0
    }

    private func assertThrows(
        _ expected: LocalTranscriberError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                expected.localizedDescription,
                file: file,
                line: line
            )
        }
    }
}

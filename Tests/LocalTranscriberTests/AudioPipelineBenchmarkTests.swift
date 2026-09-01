import Foundation
import XCTest
@testable import LocalTranscriber

final class AudioPipelineBenchmarkTests: XCTestCase {
    func testSuppliedAudioThroughProductionPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WORDMATE_RUN_AUDIO_BENCHMARK"] == "1" else {
            throw XCTSkip("Run explicitly with WORDMATE_RUN_AUDIO_BENCHMARK=1")
        }
        guard let audioPath = environment["WORDMATE_BENCHMARK_AUDIO"] else {
            XCTFail("WORDMATE_BENCHMARK_AUDIO must point to an audio file")
            return
        }
        let reference = try benchmarkReference(from: environment)

        let clock = ContinuousClock()
        let audioURL = URL(fileURLWithPath: audioPath)

        let loadingStarted = clock.now
        let loadedSamples = try AudioSampleLoader.loadMono16k(from: audioURL)
        let maximumAudioSeconds = Double(
            environment["WORDMATE_BENCHMARK_MAX_SECONDS"] ?? "0"
        ) ?? 0
        let samples: [Float]
        if maximumAudioSeconds > 0 {
            samples = Array(
                loadedSamples.prefix(
                    Int(maximumAudioSeconds * AudioSampleLoader.sampleRate)
                )
            )
        } else {
            samples = loadedSamples
        }
        let audioLoadingDuration = loadingStarted.duration(to: clock.now)
        let recordingDuration = Double(samples.count) / AudioSampleLoader.sampleRate

        let runner = ModelRunner()
        let transcriptionPreparationStarted = clock.now
        try await runner.prepare(.parakeet)
        let transcriptionPreparationDuration = transcriptionPreparationStarted.duration(to: clock.now)

        let transcriptionStarted = clock.now
        let rawTranscript = try await runner.transcribe(samples, using: .parakeet)
        let transcriptionDuration = transcriptionStarted.duration(to: clock.now)
        let cleanedTranscript = TranscriptCleaner.clean(rawTranscript)

        print("WORDMATE AUDIO BENCHMARK")
        print("AUDIO_SECONDS=\(format(recordingDuration))")
        print("AUDIO_LOAD_SECONDS=\(format(seconds(audioLoadingDuration)))")
        print("PARAKEET_PREPARE_SECONDS=\(format(seconds(transcriptionPreparationDuration)))")
        print("TRANSCRIPTION_SECONDS=\(format(seconds(transcriptionDuration)))")
        print("RAW_WER_PERCENT=\(format(wordErrorRate(cleanedTranscript, reference) * 100))")
        print("RAW_TRANSCRIPT_BEGIN")
        print(cleanedTranscript)
        print("RAW_TRANSCRIPT_END")

        XCTAssertFalse(cleanedTranscript.isEmpty)

        let processor = TranscriptPostProcessor()
        let requestedModel = environment["WORDMATE_BENCHMARK_POST_MODEL"]
        let models = PostProcessingModel.allCases.filter {
            requestedModel == nil || $0.rawValue == requestedModel || $0.displayName == requestedModel
        }
        XCTAssertFalse(models.isEmpty, "WORDMATE_BENCHMARK_POST_MODEL did not match a model")

        for model in models {
            let preparationStarted = clock.now
            try await processor.prepare(model)
            let preparationDuration = preparationStarted.duration(to: clock.now)

            let postProcessingStarted = clock.now
            let polished = try await processor.polish(cleanedTranscript, using: model)
            let postProcessingDuration = postProcessingStarted.duration(to: clock.now)
            let warmPipelineDuration = transcriptionDuration + postProcessingDuration
            let coldPipelineDuration = audioLoadingDuration
                + transcriptionPreparationDuration
                + transcriptionDuration
                + preparationDuration
                + postProcessingDuration

            print("MODEL=\(model.displayName)")
            print("POST_PREPARE_SECONDS=\(format(seconds(preparationDuration)))")
            print("POST_PROCESS_SECONDS=\(format(seconds(postProcessingDuration)))")
            print("WARM_TRANSCRIBE_TO_POLISH_SECONDS=\(format(seconds(warmPipelineDuration)))")
            print("COLD_FILE_TO_POLISH_SECONDS=\(format(seconds(coldPipelineDuration)))")
            print("POLISHED_WER_PERCENT=\(format(wordErrorRate(polished, reference) * 100))")
            print("POLISHED_TRANSCRIPT_BEGIN")
            print(polished)
            print("POLISHED_TRANSCRIPT_END")

            XCTAssertFalse(polished.isEmpty)
        }
    }

    private func benchmarkReference(from environment: [String: String]) throws -> String {
        if let referencePath = environment["WORDMATE_BENCHMARK_REFERENCE_FILE"] {
            return try String(
                contentsOfFile: referencePath,
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let reference = environment["WORDMATE_BENCHMARK_REFERENCE"] {
            return reference.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return defaultReference
    }

    private let defaultReference = """
        Lorem Ipsum is simply dummy text of the printing and typesetting industry. Lorem Ipsum has been the industry's standard dummy text ever since 1966, when designers at Letraset and James Mosley, the librarian at St Bride Printing Library in London, took a 1914 Cicero translation and scrambled it to make dummy text for Letraset's Body Type sheets. It has survived not only many decades, but also the leap into electronic typesetting, remaining essentially unchanged. It was popularised thanks to these sheets and more recently with desktop publishing software like Aldus PageMaker and Microsoft Word including versions of Lorem Ipsum. Where does it come from? Contrary to popular belief, Lorem Ipsum is not simply random text.
        """

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func wordErrorRate(_ actual: String, _ expected: String) -> Double {
        let actualWords = normalizedWords(actual)
        let expectedWords = normalizedWords(expected)
        guard !expectedWords.isEmpty else { return actualWords.isEmpty ? 0 : 1 }
        return Double(editDistance(actualWords, expectedWords)) / Double(expectedWords.count)
    }

    private func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
    }

    private func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsWord) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = lhsIndex + 1
            for (rhsIndex, rhsWord) in rhs.enumerated() {
                current[rhsIndex + 1] = min(
                    previous[rhsIndex + 1] + 1,
                    current[rhsIndex] + 1,
                    previous[rhsIndex] + (lhsWord == rhsWord ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

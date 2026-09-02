import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

protocol TranscriptPolishing: Sendable {
    func polish(
        _ transcript: String,
        using model: PostProcessingModel
    ) async throws -> String

    func polishStreamingSegment(
        _ transcript: String,
        precedingContext: String,
        followingContext: String,
        using model: PostProcessingModel
    ) async throws -> String
}

/// One language-model call made while polishing a transcript. Benchmarks read
/// these records to attribute post-release latency to the exact prompt stages
/// and retries that ran, instead of guessing from aggregate timings.
struct PostProcessingCallRecord: Sendable {
    enum Stage: String, Sendable {
        case streaming
        case standalone
        case fallbackChunk
        case recovery
    }

    enum Outcome: String, Sendable {
        case accepted
        case contextLeaked
        case projectionRejected
        case recoveryRejected
    }

    let stage: Stage
    let outcome: Outcome
    let sourceWordCount: Int
    let promptTokenCount: Int
    let reusedPromptTokenCount: Int
    let generatedTokenCount: Int
    let promptSeconds: Double
    let generationSeconds: Double
    let startedAt: ContinuousClock.Instant
    let finishedAt: ContinuousClock.Instant
    let source: String
    let output: String

    var totalSeconds: Double {
        let components = startedAt.duration(to: finishedAt).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

actor TranscriptPostProcessor {
    private enum PromptKind {
        case polish
        case recovery
    }

    private struct ModelResponse {
        let candidate: String
        let rawOutput: String
        let promptTokenCount: Int
        let reusedPromptTokenCount: Int
        let generatedTokenCount: Int
        let promptSeconds: Double
        let generationSeconds: Double
        let startedAt: ContinuousClock.Instant
        let finishedAt: ContinuousClock.Instant
    }

    private var modelContainer: ModelContainer?
    private var loadedModel: PostProcessingModel?
    private var loadingTask: Task<ModelContainer, Error>?
    private var loadingModel: PostProcessingModel?
    private var loadingOperationID: UUID?
    private let promptCache = PromptPrefixCache()
    private var callRecords: [PostProcessingCallRecord] = []

    nonisolated static func isModelDownloaded(_ model: PostProcessingModel) -> Bool {
        let configuration = remoteConfiguration(for: model)
        let directory = configuration.modelDirectory(hub: makeHub())
        let requiredFiles = [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
        ]

        let hasRequiredFiles = requiredFiles.allSatisfy { filename in
            let url = directory.appendingPathComponent(filename)
            return isNonemptyFile(at: url)
        }
        guard hasRequiredFiles,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return false }

        return files.contains { url in
            url.pathExtension == "safetensors" && isNonemptyFile(at: url)
        }
    }

    func prepare(
        _ model: PostProcessingModel,
        progressHandler: ModelProgressHandler? = nil
    ) async throws {
        if loadedModel == model, modelContainer != nil {
            progressHandler?(.init(fractionCompleted: 1, status: "Ready"))
            return
        }

        if loadingModel == model,
           let loadingTask,
           let loadingOperationID {
            progressHandler?(
                .init(fractionCompleted: 0.98, status: "Loading \(model.displayName)…")
            )
            try await finishLoading(
                loadingTask,
                model: model,
                operationID: loadingOperationID,
                progressHandler: progressHandler
            )
            return
        }

        loadingTask?.cancel()
        loadingTask = nil
        loadingModel = nil
        loadingOperationID = nil
        modelContainer = nil
        loadedModel = nil
        promptCache.clear()

        progressHandler?(
            .init(fractionCompleted: 0.01, status: "Checking \(model.displayName)…")
        )
        let hub = Self.makeHub()
        let configuration = Self.loadingConfiguration(for: model)
        let task = Task(priority: .userInitiated) {
            try await LLMModelFactory.shared.loadContainer(
                hub: hub,
                configuration: configuration
            ) { progress in
                let fraction = progress.fractionCompleted
                progressHandler?(
                    .init(
                        fractionCompleted: min(0.97, max(0.02, fraction * 0.97)),
                        status: fraction < 1
                            ? "Downloading \(model.displayName)…"
                            : "Loading \(model.displayName)…"
                    )
                )
            }
        }
        let operationID = UUID()
        loadingTask = task
        loadingModel = model
        loadingOperationID = operationID

        try await finishLoading(
            task,
            model: model,
            operationID: operationID,
            progressHandler: progressHandler
        )
    }

    /// Returns and clears every model call recorded since the previous drain.
    func drainCallRecords() -> [PostProcessingCallRecord] {
        defer { callRecords.removeAll() }
        return callRecords
    }

    func polish(
        _ transcript: String,
        using model: PostProcessingModel
    ) async throws -> String {
        try await prepare(model)
        guard loadedModel == model, let modelContainer else {
            throw LocalTranscriberError.modelCouldNotLoad(
                "\(model.displayName) is unavailable."
            )
        }

        var polishedChunks: [String] = []
        for chunk in TranscriptPolishPolicy.chunks(from: transcript) {
            try Task.checkCancellation()
            polishedChunks.append(
                try await polishChunk(
                    chunk,
                    modelContainer: modelContainer,
                    allowFallback: true
                )
            )
        }

        return polishedChunks.joined(separator: " ")
    }

    func polishStreamingSegment(
        _ transcript: String,
        precedingContext: String,
        followingContext: String,
        using model: PostProcessingModel
    ) async throws -> String {
        try await prepare(model)
        guard loadedModel == model, let modelContainer else {
            throw LocalTranscriberError.modelCouldNotLoad(
                "\(model.displayName) is unavailable."
            )
        }

        let response = try await respond(
            .polish,
            to: TranscriptPolishPolicy.streamingPrompt(
                for: transcript,
                precedingContext: precedingContext,
                followingContext: followingContext
            ),
            source: transcript,
            modelContainer: modelContainer
        )

        if TranscriptPolishPolicy.leaksStreamingContext(
            response.candidate,
            precedingContext: precedingContext,
            followingContext: followingContext
        ) {
            record(response, stage: .streaming, outcome: .contextLeaked, source: transcript)
        } else if let candidate = TranscriptPolishPolicy.conservativeProjection(
            of: response.candidate,
            for: transcript
        ) {
            record(response, stage: .streaming, outcome: .accepted, source: transcript)
            return candidate
        } else {
            record(response, stage: .streaming, outcome: .projectionRejected, source: transcript)
        }

        // Context-only prompting is intentionally conservative. If the small
        // model repeats either context halo or drifts from the target, retry the
        // owned segment through the established standalone path.
        return try await polishChunk(
            transcript,
            modelContainer: modelContainer,
            allowFallback: true
        )
    }

    private func polishChunk(
        _ chunk: String,
        modelContainer: ModelContainer,
        allowFallback: Bool
    ) async throws -> String {
        try Task.checkCancellation()

        let stage: PostProcessingCallRecord.Stage = allowFallback ? .standalone : .fallbackChunk
        let response = try await respond(
            .polish,
            to: TranscriptPolishPolicy.prompt(for: chunk),
            source: chunk,
            modelContainer: modelContainer
        )

        if let candidate = TranscriptPolishPolicy.conservativeProjection(
            of: response.candidate,
            for: chunk
        ) {
            record(response, stage: stage, outcome: .accepted, source: chunk)
            // The recovery prompt exists for echoes the primary pass left
            // behind. Running it unconditionally doubled the cost of every
            // fallback chunk without changing fluent output.
            if TranscriptPolishPolicy.containsImmediateRepeatedSpeech(candidate) {
                return try await runDisfluencyRecovery(
                    candidate,
                    modelContainer: modelContainer
                )
            }
            return candidate
        }
        record(response, stage: stage, outcome: .projectionRejected, source: chunk)

        guard allowFallback else {
            return try await runDisfluencyRecovery(
                chunk,
                modelContainer: modelContainer
            )
        }

        // Qwen 0.6B can occasionally summarize a dense passage instead of
        // editing it. Retry rejected output one sentence at a time, then apply
        // a deletion-only recovery prompt guarded by a near-verbatim coverage
        // check. This removes stutters without risking lost clauses.
        let fallbackChunks = TranscriptPolishPolicy.fallbackChunks(from: chunk)
        guard fallbackChunks.count > 1 else {
            return try await runDisfluencyRecovery(
                chunk,
                modelContainer: modelContainer
            )
        }

        var polishedFallbackChunks: [String] = []
        for fallbackChunk in fallbackChunks {
            let polished = try await polishChunk(
                fallbackChunk,
                modelContainer: modelContainer,
                allowFallback: false
            )
            // A chunk that starts or ends mid-sentence must not gain a
            // sentence boundary from the model; otherwise the joined text
            // reads "a treatise. on the theory of ethics".
            polishedFallbackChunks.append(
                TranscriptPolishPolicy.matchingSentenceBoundaries(
                    of: polished,
                    to: fallbackChunk
                )
            )
        }
        return polishedFallbackChunks.joined(separator: " ")
    }

    private func runDisfluencyRecovery(
        _ chunk: String,
        modelContainer: ModelContainer
    ) async throws -> String {
        let response = try await respond(
            .recovery,
            to: chunk,
            source: chunk,
            modelContainer: modelContainer
        )

        let candidate = TranscriptPolishPolicy.strippingEmphasisMarkup(
            from: response.candidate,
            absentFrom: chunk
        )
        if TranscriptPolishPolicy.isNearVerbatimRecovery(candidate, for: chunk) {
            record(response, stage: .recovery, outcome: .accepted, source: chunk)
            return candidate
        }
        record(response, stage: .recovery, outcome: .recoveryRejected, source: chunk)
        return chunk
    }

    private func respond(
        _ kind: PromptKind,
        to prompt: String,
        source: String,
        modelContainer: ModelContainer
    ) async throws -> ModelResponse {
        try Task.checkCancellation()
        let parameters = Self.generationParameters(transcript: source)
        let promptCache = self.promptCache
        let enableThinking: Bool
        switch kind {
        case .polish:
            enableThinking = TranscriptPolishPolicy.reasoningEnabled
        case .recovery:
            enableThinking = false
        }

        let startedAt = ContinuousClock.now
        let generation = try await modelContainer.perform { context in
            var messages: [Chat.Message]
            switch kind {
            case .polish:
                messages = [.system(TranscriptPolishPolicy.instructions)]
                messages.append(contentsOf: TranscriptPolishPolicy.fewShotHistory)
            case .recovery:
                messages = [.system(TranscriptPolishPolicy.recoveryInstructions)]
                messages.append(contentsOf: TranscriptPolishPolicy.recoveryHistory)
            }
            messages.append(.user(prompt))

            let input = try await context.processor.prepare(
                input: UserInput(
                    chat: messages,
                    additionalContext: ["enable_thinking": enableThinking]
                )
            )
            return try await Self.generate(
                promptTokens: input.text.tokens.asArray(Int.self),
                parameters: parameters,
                context: context,
                promptCache: promptCache
            )
        }
        let finishedAt = ContinuousClock.now

        return ModelResponse(
            candidate: TranscriptPolishPolicy.cleanModelOutput(generation.output),
            rawOutput: generation.output,
            promptTokenCount: generation.promptTokenCount,
            reusedPromptTokenCount: generation.reusedPromptTokenCount,
            generatedTokenCount: generation.generatedTokenCount,
            promptSeconds: generation.promptSeconds,
            generationSeconds: generation.generationSeconds,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private struct GenerationOutput {
        let output: String
        let promptTokenCount: Int
        let reusedPromptTokenCount: Int
        let generatedTokenCount: Int
        let promptSeconds: Double
        let generationSeconds: Double
    }

    /// Generates a completion while reusing the key/value cache of the longest
    /// prompt prefix shared with the previous call. Every polishing prompt
    /// starts with the same instructions and few-shot examples, so only the
    /// transcript-specific suffix is prefilled on each call.
    private static func generate(
        promptTokens: [Int],
        parameters: GenerateParameters,
        context: ModelContext,
        promptCache: PromptPrefixCache
    ) async throws -> GenerationOutput {
        let promptStarted = ContinuousClock.now
        let reused = promptCache.reuse(for: promptTokens)
        let cache = reused?.cache ?? context.model.newCache(parameters: parameters)
        let reusedTokenCount = reused?.reusedTokenCount ?? 0
        let remainingTokens = Array(promptTokens[reusedTokenCount...])

        let iterator = try TokenIterator(
            input: LMInput(text: .init(tokens: MLXArray(remainingTokens))),
            model: context.model,
            cache: cache,
            parameters: parameters
        )
        let promptSeconds = Self.seconds(promptStarted.duration(to: .now))

        let generationStarted = ContinuousClock.now
        let (stream, task) = MLXLMCommon.generateTask(
            promptTokenCount: remainingTokens.count,
            modelConfiguration: context.configuration,
            tokenizer: context.tokenizer,
            iterator: iterator
        )
        var output = ""
        var generatedTokenCount = 0
        for await item in stream {
            switch item {
            case let .chunk(chunk):
                output += chunk
            case let .info(info):
                generatedTokenCount = info.generationTokenCount
            case .toolCall:
                break
            }
        }
        await task.value
        let generationSeconds = Self.seconds(generationStarted.duration(to: .now))

        promptCache.store(cache, promptTokens: promptTokens)
        return GenerationOutput(
            output: output,
            promptTokenCount: promptTokens.count,
            reusedPromptTokenCount: reusedTokenCount,
            generatedTokenCount: generatedTokenCount,
            promptSeconds: promptSeconds,
            generationSeconds: generationSeconds
        )
    }

    private func record(
        _ response: ModelResponse,
        stage: PostProcessingCallRecord.Stage,
        outcome: PostProcessingCallRecord.Outcome,
        source: String
    ) {
        callRecords.append(
            PostProcessingCallRecord(
                stage: stage,
                outcome: outcome,
                sourceWordCount: source.split(whereSeparator: \.isWhitespace).count,
                promptTokenCount: response.promptTokenCount,
                reusedPromptTokenCount: response.reusedPromptTokenCount,
                generatedTokenCount: response.generatedTokenCount,
                promptSeconds: response.promptSeconds,
                generationSeconds: response.generationSeconds,
                startedAt: response.startedAt,
                finishedAt: response.finishedAt,
                source: source,
                output: response.candidate
            )
        )
        if callRecords.count > 512 {
            callRecords.removeFirst(callRecords.count - 512)
        }
    }

    func cancelPreparationAndUnload() {
        loadingTask?.cancel()
        loadingTask = nil
        loadingModel = nil
        loadingOperationID = nil
        modelContainer = nil
        loadedModel = nil
        promptCache.clear()
    }

    private func finishLoading(
        _ task: Task<ModelContainer, Error>,
        model: PostProcessingModel,
        operationID: UUID,
        progressHandler: ModelProgressHandler?
    ) async throws {
        let loadedContainer: ModelContainer
        do {
            loadedContainer = try await task.value
        } catch is CancellationError {
            // The load itself was cancelled: an unload or a different model.
            clearLoadingState(ifOperation: operationID)
            throw CancellationError()
        } catch {
            clearLoadingState(ifOperation: operationID)
            throw LocalTranscriberError.modelCouldNotLoad(
                "\(model.displayName) could not be prepared. \(error.localizedDescription)"
            )
        }

        // Install the finished model even if this particular caller was
        // cancelled while waiting. Other callers, and the next recording, still
        // need it; discarding a completed load only forces a reload later.
        if loadingOperationID == operationID, loadingModel == model {
            modelContainer = loadedContainer
            loadedModel = model
            clearLoadingState(ifOperation: operationID)
        }

        try Task.checkCancellation()
        guard loadedModel == model, modelContainer != nil else {
            throw CancellationError()
        }
        progressHandler?(.init(fractionCompleted: 1, status: "Ready"))
    }

    private func clearLoadingState(ifOperation operationID: UUID) {
        guard loadingOperationID == operationID else { return }
        loadingTask = nil
        loadingModel = nil
        loadingOperationID = nil
    }

    private nonisolated static func remoteConfiguration(
        for model: PostProcessingModel
    ) -> ModelConfiguration {
        LLMRegistry.qwen3_0_6b_4bit
    }

    /// Once the model files exist locally, load them from that directory.
    /// A Hub-backed configuration re-lists the repository and checks every
    /// file against the server on each load, which costs a network round trip
    /// per launch, fails behind a firewall, and contradicts offline operation.
    nonisolated static func loadingConfiguration(
        for model: PostProcessingModel
    ) -> ModelConfiguration {
        let remote = remoteConfiguration(for: model)
        guard isModelDownloaded(model) else { return remote }
        return ModelConfiguration(directory: remote.modelDirectory(hub: makeHub()))
    }

    private nonisolated static func generationParameters(
        transcript: String
    ) -> GenerateParameters {
        // No repetition penalty: the task is verbatim copying, and a penalty
        // discourages re-emitting exactly the repeated source words that a
        // faithful edit must keep ("content here, content here").
        return GenerateParameters(
            maxTokens: TranscriptPolishPolicy.maximumOutputTokens(for: transcript),
            temperature: 0,
            topP: 1
        )
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private nonisolated static func isNonemptyFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private nonisolated static func makeHub() -> HubApi {
        HubApi(downloadBase: modelCacheRoot)
    }

    private nonisolated static var modelCacheRoot: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("Wordmate", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("HuggingFace", isDirectory: true)
    }
}

extension TranscriptPostProcessor: TranscriptPolishing {}

/// Keeps the key/value cache of the most recent prompt so the next prompt can
/// skip prefilling the tokens it shares with it. Only ever touched inside
/// `ModelContainer.perform`, which serializes model access.
private final class PromptPrefixCache: @unchecked Sendable {
    private var cache: [KVCache] = []
    private var tokens: [Int] = []
    private let minimumReusableTokens = 16

    func reuse(for promptTokens: [Int]) -> (cache: [KVCache], reusedTokenCount: Int)? {
        guard !cache.isEmpty,
              cache.allSatisfy(\.isTrimmable),
              promptTokens.count > 1 else { return nil }

        // Leave at least one prompt token to process so the model produces
        // logits for the first generated token.
        let limit = min(tokens.count, promptTokens.count - 1)
        var shared = 0
        while shared < limit, tokens[shared] == promptTokens[shared] {
            shared += 1
        }
        guard shared >= minimumReusableTokens else { return nil }

        for layer in cache {
            let excess = layer.offset - shared
            guard excess >= 0 else {
                clear()
                return nil
            }
            if excess > 0 { layer.trim(excess) }
        }
        tokens = Array(tokens.prefix(shared))
        return (cache, shared)
    }

    func store(_ cache: [KVCache], promptTokens: [Int]) {
        // Generation appended the response tokens; keep only the prompt so a
        // later prompt can extend the shared prefix.
        for layer in cache {
            let excess = layer.offset - promptTokens.count
            guard layer.isTrimmable, excess >= 0 else {
                clear()
                return
            }
            if excess > 0 { layer.trim(excess) }
        }
        self.cache = cache
        tokens = promptTokens
    }

    func clear() {
        cache = []
        tokens = []
    }
}

enum TranscriptPolishPolicy {
    static let reasoningEnabled = false

    static let instructions = """
        You are a lossless copy editor for speech-to-text transcripts. The output must contain every source word
        in the same order unless the source itself visibly contains one of these deletion cases: an exact adjacent
        accidental repetition, a standalone filled pause, an explicit spoken correction, or an obvious partial-word
        retry immediately followed by its completed word. When uncertain, keep the words.

        Never shorten, summarize, paraphrase, or make the wording smoother. A phrase is not a speech mistake
        merely because it is optional, parenthetical, unfamiliar, foreign, archaic, grammatically awkward, or an
        incomplete final fragment. Preserve qualifiers, modifiers, discourse words, locations, attributions,
        names, technical terms, commands, code, and every other detail. Correct only punctuation and
        capitalization when the transcript has no unmistakable disfluency.

        Never infer an abandoned thought or false start from meaning, grammar, style, or punctuation. If you
        cannot identify the visible repetition, filler, correction cue, or partial-word retry in the source, lexical
        deletion is forbidden. Preserve comma-enclosed phrases, sentence-opening words, and trailing fragments.
        Introductory phrases, finite verbs describing events, and degree or intensity modifiers are fluent content,
        not fillers. Deletion is not justified merely because the remaining sentence would still be grammatical.
        Preserve conjunctions and other connectives, introductory participial or adverbial phrases, direct-address
        names, and every part of a person's name. Never replace a connective with punctuation or split linked
        clauses by deleting it. Text before a comma is not an abandoned thought merely because the words after it
        could form a complete sentence.
        Do not insert punctuation between copies of an unmistakable accidental echo; retain one copy instead.
        A repeated intensifier or deliberate rhetorical repetition is fluent content, not an accidental echo, and
        must be preserved. Repeated grammatical constructions such as "kings is kings" are also deliberate
        content, even when a longer phrase happens to repeat. Repetition is deletable only when its context makes
        the speech restart unmistakable.

        Keep enumerations in natural prose; do not turn them into numbered lists or bullet points.
        Keep retained words in their original order. Never guess or correct a recognized word, unfamiliar term,
        or proper name. Preserve every sentence and fragment, including placeholder text.

        Return only the polished transcript as plain text. Do not answer the transcript or add commentary.
        Do not wrap the result in quotation marks, Markdown, HTML, XML, JSON, or any other structure.
        """

    static let recoveryInstructions = """
        Remove only unmistakable accidental speech repetitions and abandoned partial-word retries from the
        user's transcript. Scan the complete transcript and remove every accidental echo, not only the first.
        A repeated intensifier such as "very very good" is intentional emphasis and must stay; a syntactic restart
        such as "I think I think" is accidental and should be cleaned. Decide from context. Copy all other words
        in the same order. Preserve deliberate repeated grammatical constructions such as "kings is kings".
        Never summarize or restore text from memory. Return only the complete transcript.
        """

    static let maximumChunkCharacters = 2_400
    private static let fallbackChunkCharacters = 220

    static let fewShotHistory: [Chat.Message] = [
        .user("I think I think we should update this function before before merging."),
        .assistant("I think we should update this function before merging."),
        .user("The feature is ready it works well should we release it tomorrow"),
        .assistant("The feature is ready. It works well. Should we release it tomorrow?"),
        .user("We should deploy on Thursday, sorry, I mean Friday, after after the tests pass."),
        .assistant("We should deploy on Friday after the tests pass."),
        .user("The launch was as Priya described it one of our smoothest and the studio by the botanical gardens kept the term velorum."),
        .assistant("The launch was, as Priya described it, one of our smoothest, and the studio by the botanical gardens kept the term velorum."),
        .user("Surface dust at least had been removed and the ideas also remain while the practice was very generally accepted."),
        .assistant("Surface dust, at least, had been removed, and the ideas also remain, while the practice was very generally accepted."),
        .user("They left him then for the courier arrived to unlock the gate and escort them inside."),
        .assistant("They left him then, for the courier arrived to unlock the gate and escort them inside."),
        .user("Carefully changing her route, Mira first lowered the sail, and in order to help her guide, carried only the flag."),
        .assistant("Carefully changing her route, Mira first lowered the sail, and in order to help her guide, carried only the flag."),
        .user("Listen then, Amara, to a story of Rowan, who told it to Elias."),
        .assistant("Listen then, Amara, to a story of Rowan, who told it to Elias."),
        .user("In a few hours the review would begin, and she was still choosing between waiting and publishing the report."),
        .assistant("In a few hours the review would begin, and she was still choosing between waiting and publishing the report."),
        .user("Robin Fairbrook saw that his doubts had been unfair, and he became ashamed of himself."),
        .assistant("Robin Fairbrook saw that his doubts had been unfair, and he became ashamed of himself."),
        .user("So saying, she meanwhile crossed the square. There"),
        .assistant("So saying, she, meanwhile, crossed the square. There"),
        .user("Listen then, Amara, and walk with Robin Fairbrook to the square. There"),
        .assistant("Listen then, Amara, and walk with Robin Fairbrook to the square. There"),
        .user("All I say is kings is kings and you got to make allowances."),
        .assistant("All I say is, kings is kings, and you got to make allowances."),
        .user("The report report has been has been ready since since Monday."),
        .assistant("The report has been ready since Monday."),
    ]

    static let recoveryHistory: [Chat.Message] = [
        .user("The result was very very good, exactly what we wanted."),
        .assistant("The result was very very good, exactly what we wanted."),
        .user("Northstar Northstar is a scheduling tool tool for retail teams."),
        .assistant("Northstar is a scheduling tool for retail teams."),
        .user("I think I think we should update this function before before merging."),
        .assistant("I think we should update this function before merging."),
        .user("All I say is, kings is kings, and you got to make allowances."),
        .assistant("All I say is, kings is kings, and you got to make allowances."),
    ]

    static func prompt(for transcript: String) -> String {
        return """
        Losslessly polish the transcript below. Keep every source word unless it is visibly an exact adjacent
        accidental repetition, a standalone filler, an explicit correction, or a partial-word retry. Do not infer
        deletions from meaning or grammar. Never delete fluent content to make the sentence shorter or smoother.
        If none of those visible cases occurs, change only punctuation and capitalization. When uncertain,
        preserve the text.
        A repeated span is not automatically accidental. Preserve deliberate emphasis such as "very very good".
        Clean a clear speech restart such as "I think I think we should" to "I think we should". Scan the entire
        transcript and remove every unmistakably accidental echo, not only the first. Never separate copies of an
        accidental echo with punctuation or introduce a sentence boundary where the removed copy stood.
        Keep all retained words in their original order; do not rewrite wording or guess recognition errors.
        Keep enumerations as prose and do not create lists.
        Do not omit any sentence or fragment, including unfamiliar or placeholder text. Return only the complete
        polished transcript. Before returning, compare the result word by word with the source and restore every
        source word that is not part of one of the visible deletion cases above.

        ----- BEGIN SPOKEN TRANSCRIPT -----
        \(transcript)
        ----- END SPOKEN TRANSCRIPT -----
        """
    }

    static func streamingPrompt(
        for transcript: String,
        precedingContext: String,
        followingContext: String
    ) -> String {
        let before = precedingContext.isEmpty ? "None" : precedingContext
        let after = followingContext.isEmpty ? "None" : followingContext

        return """
        Polish only the target segment below. The surrounding passages are context only: use them to
        understand sentence boundaries and self-corrections, but never include their words in your answer.
        Keep every target word unless it is visibly an exact adjacent accidental repetition, a standalone filler,
        an explicit correction, or a partial-word retry. Do not infer deletions from meaning or grammar. Never
        delete fluent content to make it shorter or smoother. If none of those visible cases occurs, change only
        punctuation and capitalization. Keep retained words in their original order; do not rewrite wording or
        guess recognition errors. A repeated span is not automatically accidental: preserve deliberate emphasis
        such as "very very good", but clean a clear restart such as "I think I think we should" to "I think we
        should". Scan the entire target and remove every unmistakably accidental echo, not only the first. Never
        separate copies with punctuation or introduce a sentence boundary where the removed copy stood.
        Preserve an incomplete final fragment. Return only the complete polished target
        segment as plain text. Before returning, compare it word by word with the target and restore every target
        word that is not part of one of the visible deletion cases above.

        PRECEDING CONTEXT — DO NOT RETURN
        \(before)

        TARGET SEGMENT — RETURN ONLY THIS
        \(transcript)

        FOLLOWING CONTEXT — DO NOT RETURN
        \(after)
        """
    }

    static func maximumOutputTokens(for transcript: String) -> Int {
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        return min(1_800, max(512, words * 3 + 384))
    }

    static func chunks(from transcript: String) -> [String] {
        chunks(from: transcript, maximumCharacters: maximumChunkCharacters)
    }

    /// Retries a rejected passage one sentence at a time. Only a sentence that
    /// is itself longer than the fallback window is split further, at clause
    /// boundaries where possible, so chunk seams rarely fall mid-sentence.
    static func fallbackChunks(from transcript: String) -> [String] {
        let sentences = StreamingTranscriptPolicy.sentenceSegments(in: transcript)
        guard sentences.count > 1 else {
            return chunks(from: transcript, maximumCharacters: fallbackChunkCharacters)
        }
        return sentences.flatMap { sentence in
            chunks(from: sentence, maximumCharacters: fallbackChunkCharacters)
        }
    }

    /// Removes a sentence boundary the model added at the seam of a chunk that
    /// does not start or end a sentence in the source, and restores the
    /// source's lowercase start when the chunk began mid-sentence.
    static func matchingSentenceBoundaries(
        of polished: String,
        to source: String
    ) -> String {
        var result = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        if !StreamingTranscriptPolicy.endsAtStrongBoundary(source) {
            var characters = Array(result)
            var closers: [Character] = []
            while let last = characters.last,
                  StreamingTranscriptPolicy.isClosingCharacter(last) {
                closers.insert(last, at: 0)
                characters.removeLast()
            }
            var removed = false
            while let last = characters.last,
                  StreamingTranscriptPolicy.isStrongTerminator(last) {
                characters.removeLast()
                removed = true
            }
            if removed {
                result = String(characters + closers)
            }
        }

        if let sourceFirst = source.first(where: { $0.isLetter || $0.isNumber }),
           sourceFirst.isLowercase,
           let resultIndex = result.firstIndex(where: { $0.isLetter || $0.isNumber }),
           result[resultIndex].isUppercase,
           result[resultIndex].lowercased() == String(sourceFirst) {
            result.replaceSubrange(
                resultIndex...resultIndex,
                with: result[resultIndex].lowercased()
            )
        }
        return result
    }

    static func chunks(
        from transcript: String,
        maximumCharacters: Int
    ) -> [String] {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumCharacters else {
            return normalized.isEmpty ? [] : [normalized]
        }

        var chunks: [String] = []
        var remainder = normalized[...]

        while remainder.count > maximumCharacters {
            let windowEnd = remainder.index(
                remainder.startIndex,
                offsetBy: maximumCharacters
            )
            let window = remainder[..<windowEnd]
            let splitOffset = preferredSplitOffset(in: window)
                ?? lastWhitespaceOffset(in: window)
                ?? maximumCharacters
            let splitIndex = remainder.index(
                remainder.startIndex,
                offsetBy: splitOffset
            )
            let chunk = remainder[..<splitIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            remainder = remainder[splitIndex...]
                .drop(while: \.isWhitespace)
        }

        let finalChunk = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalChunk.isEmpty {
            chunks.append(finalChunk)
        }
        return chunks
    }

    private static func preferredSplitOffset(in window: Substring) -> Int? {
        let characters = Array(window)

        // A blank line is the strongest semantic boundary. Prefer it even when
        // a later sentence happens to fit inside the same character window.
        if let paragraph = lastParagraphBoundary(in: characters) {
            return paragraph
        }
        if let sentence = lastPunctuationBoundary(
            in: characters,
            terminators: [".", "?", "!", "…", "。", "？", "！"]
        ) {
            return sentence
        }
        if let clause = lastPunctuationBoundary(
            in: characters,
            terminators: [";", ":", "；", "："]
        ) {
            return clause
        }
        return lastPunctuationBoundary(
            in: characters,
            terminators: [",", "，", "、"]
        )
    }

    private static func lastParagraphBoundary(in characters: [Character]) -> Int? {
        guard characters.count >= 2 else { return nil }

        var result: Int?
        var index = 0
        while index < characters.count {
            guard characters[index].isNewline else {
                index += 1
                continue
            }

            var cursor = index + 1
            while cursor < characters.count,
                  characters[cursor].isWhitespace,
                  !characters[cursor].isNewline {
                cursor += 1
            }

            if cursor < characters.count,
               characters[cursor].isNewline {
                cursor += 1
                while cursor < characters.count,
                      characters[cursor].isWhitespace {
                    cursor += 1
                }
                result = cursor
                index = cursor
            } else {
                index += 1
            }
        }
        return result
    }

    private static func lastPunctuationBoundary(
        in characters: [Character],
        terminators: Set<Character>
    ) -> Int? {
        let closingCharacters: Set<Character> = [
            "\"", "'", "”", "’", ")", "]", "}", "»", "›"
        ]
        var result: Int?

        for index in characters.indices where terminators.contains(characters[index]) {
            var cursor = index + 1
            while cursor < characters.count,
                  closingCharacters.contains(characters[cursor]) {
                cursor += 1
            }

            if cursor == characters.count || characters[cursor].isWhitespace {
                result = cursor
            }
        }
        return result
    }

    private static func lastWhitespaceOffset(in window: Substring) -> Int? {
        let characters = Array(window)
        guard let index = characters.lastIndex(where: \.isWhitespace),
              index > characters.startIndex else {
            return nil
        }
        return index
    }

    static func cleanModelOutput(_ output: String) -> String {
        var result = output.replacingOccurrences(
            of: "(?is)<think>.*?</think>",
            with: "",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.count >= 6,
           result.hasPrefix("```"),
           result.hasSuffix("```") {
            if let firstLineEnd = result.firstIndex(of: "\n") {
                result.removeSubrange(result.startIndex...firstLineEnd)
            } else {
                result.removeFirst(3)
            }
            result.removeLast(3)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        result = result.replacingOccurrences(
            of: "(?i)^(?:(cleaned|edited|polished)\\s+)?(transcript|text|output|result|response)\\s*:\\s*",
            with: "",
            options: .regularExpression
        )

        for _ in 0..<3 {
            let previous = result
            if let unwrapped = unwrapJSONContainer(result) {
                result = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let unwrapped = unwrapMarkupContainer(result) {
                result = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if result == previous { break }
        }

        if result.count >= 2,
           let first = result.first,
           let last = result.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            result.removeFirst()
            result.removeLast()
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isAcceptable(_ candidate: String, for source: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        guard !containsStructuredWrapper(candidate) else { return false }
        guard preservesNumericFacts(from: source, in: candidate) else { return false }
        guard candidate.count <= source.count * 2 + 120 else { return false }
        if source.count > 80, candidate.count < source.count / 5 {
            return false
        }

        let sourceWordList = words(in: source)
        let candidateWordList = words(in: candidate)
        if sourceWordList.count >= 5,
           candidateWordList.count * 2 < sourceWordList.count {
            return false
        }

        let sourceWords = Set(sourceWordList)
        let candidateWords = Set(candidateWordList)
        let overlap = sourceWords.intersection(candidateWords).count
        if sourceWords.count >= 8,
           Double(overlap) / Double(sourceWords.count) < 0.62 {
            return false
        }
        guard candidateWords.count >= 4 else { return true }
        return Double(overlap) / Double(candidateWords.count) >= 0.42
    }

    static func isNearVerbatimRecovery(_ candidate: String, for source: String) -> Bool {
        guard isAcceptable(candidate, for: source) else { return false }

        // Recovery is allowed to delete model-identified repetitions, but it
        // must never substitute or invent lexical content. Case and punctuation
        // are ignored by the word tokens, so those remain safe to improve.
        guard let deletedSourceIndices = orderedSubsetDeletionIndices(
            of: candidate,
            from: source
        ) else {
            return false
        }
        return deletionsAreWithinBudget(
            deletedSourceIndices,
            in: wordTokens(in: source),
            source: source,
            budget: .recovery
        )
    }

    static func containsImmediateRepeatedSpeech(_ text: String) -> Bool {
        repeatedSpeechWordCount(in: words(in: text)) > 0
    }

    static func isConservativeEditAcceptable(
        _ candidate: String,
        for source: String
    ) -> Bool {
        guard passesBasicSafety(candidate, for: source),
              !introducesPresentationMarkup(candidate, absentFrom: source) else {
            return false
        }

        // The editor may remove disfluencies, but all words it keeps must come
        // from the source in the original order. This turns prompt guidance
        // into a hard safety property and prevents a small model from guessing
        // names, "correcting" recognition errors, or paraphrasing a clause.
        guard let deletedSourceIndices = orderedSubsetDeletionIndices(
            of: candidate,
            from: source
        ) else {
            return false
        }
        return deletionsAreWithinBudget(
            deletedSourceIndices,
            in: wordTokens(in: source),
            source: source,
            budget: .conservative
        )
    }

    /// Preserves Qwen's punctuation and model-selected disfluency deletions,
    /// while restoring any source word it attempted to replace and removing
    /// words it attempted to invent. This is a safety projection, not a second
    /// cleanup algorithm: Qwen still decides what speech is accidental.
    static func conservativeProjection(
        of candidate: String,
        for source: String
    ) -> String? {
        let candidate = strippingEmphasisMarkup(from: candidate, absentFrom: source)
        guard passesBasicSafety(candidate, for: source),
              !introducesPresentationMarkup(candidate, absentFrom: source) else {
            return nil
        }

        let sourceTokens = wordTokens(in: source)
        let candidateTokens = wordTokens(in: candidate)
        guard !sourceTokens.isEmpty, !candidateTokens.isEmpty else { return nil }

        let steps = wordAlignment(
            source: sourceTokens.map(\.normalized),
            candidate: candidateTokens.map(\.normalized)
        )

        // Treat each uninterrupted edit region as one operation. If Qwen
        // substituted or inserted anything in that region, restore the whole
        // corresponding source phrase. Pure deletion regions remain model
        // decisions, which is how repeated speech and false starts are removed.
        var editRuns: [[WordAlignmentStep]] = []
        var currentRun: [WordAlignmentStep] = []
        for step in steps {
            if case .match = step {
                if !currentRun.isEmpty {
                    editRuns.append(currentRun)
                    currentRun = []
                }
            } else {
                currentRun.append(step)
            }
        }
        if !currentRun.isEmpty { editRuns.append(currentRun) }

        var modelDeletedSourceIndices = Set<Int>()
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        for run in editRuns {
            var sourceIndices: [Int] = []
            var candidateIndices: [Int] = []
            var containsNovelCandidateWords = false

            for step in run {
                switch step {
                case let .substitute(sourceIndex, candidateIndex):
                    sourceIndices.append(sourceIndex)
                    candidateIndices.append(candidateIndex)
                    containsNovelCandidateWords = true
                case let .deleteSource(sourceIndex):
                    sourceIndices.append(sourceIndex)
                case let .insertCandidate(candidateIndex):
                    candidateIndices.append(candidateIndex)
                    containsNovelCandidateWords = true
                case .match:
                    break
                }
            }

            guard containsNovelCandidateWords else {
                modelDeletedSourceIndices.formUnion(sourceIndices)
                continue
            }
            guard let firstCandidate = candidateIndices.min(),
                  let lastCandidate = candidateIndices.max() else {
                continue
            }

            let replacement: String
            if let firstSource = sourceIndices.min(),
               let lastSource = sourceIndices.max() {
                let sourceRange = sourceTokens[firstSource].range.lowerBound
                    ..< sourceTokens[lastSource].range.upperBound
                replacement = String(
                    source[sourceRange]
                )
            } else {
                replacement = ""
            }
            let candidateRange = candidateTokens[firstCandidate].range.lowerBound
                ..< candidateTokens[lastCandidate].range.upperBound
            edits.append(
                (candidateRange, replacement)
            )
        }

        // A fluent source with no immediate repeated span or partial-word
        // retry gets no lexical deletion budget. Qwen still decides whether a
        // repetition is accidental and may also remove a nearby false start.
        // This remains language-agnostic and prevents optional fluent words
        // from being silently treated as repairs.
        guard deletionsAreWithinBudget(
                  modelDeletedSourceIndices,
                  in: sourceTokens,
                  source: source,
                  budget: .conservative
              ) else {
            return nil
        }

        var projected = candidate
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            projected.replaceSubrange(edit.range, with: edit.replacement)
        }
        projected = TranscriptCleaner.clean(
            removingInsertedSentenceBreaks(from: projected, for: source)
        )

        guard isConservativeEditAcceptable(projected, for: source) else {
            return nil
        }
        return projected
    }

    static func isStreamingEditAcceptable(
        _ candidate: String,
        for source: String
    ) -> Bool {
        guard isConservativeEditAcceptable(candidate, for: source),
              !containsStreamingPromptScaffolding(candidate) else {
            return false
        }

        let sourceWords = words(in: source)
        let candidateWords = words(in: candidate)
        guard !sourceWords.isEmpty, !candidateWords.isEmpty else { return false }

        // A streaming edit owns only its source span. It may delete speech
        // mistakes, but it must not grow by copying a context halo or prompt.
        let insertionAllowance = max(3, sourceWords.count / 8)
        guard candidateWords.count <= sourceWords.count + insertionAllowance else {
            return false
        }

        let orderedOverlap = orderedWordOverlapLength(
            sourceWords,
            candidateWords
        )
        let candidateCoverage = Double(orderedOverlap)
            / Double(candidateWords.count)
        let sourceCoverage = Double(orderedOverlap)
            / Double(sourceWords.count)
        return candidateCoverage >= 0.80 && sourceCoverage >= 0.55
    }

    static func leaksStreamingContext(
        _ candidate: String,
        precedingContext: String,
        followingContext: String
    ) -> Bool {
        if containsStreamingPromptScaffolding(candidate) {
            return true
        }

        let candidateWords = words(in: candidate)
        guard !candidateWords.isEmpty else { return false }

        let precedingWords = words(in: precedingContext)
        let precedingFingerprint = Array(precedingWords.suffix(min(8, precedingWords.count)))
        if precedingFingerprint.count >= 4,
           candidateWords.starts(with: precedingFingerprint) {
            return true
        }

        let followingWords = words(in: followingContext)
        let followingFingerprint = Array(followingWords.prefix(min(8, followingWords.count)))
        if followingFingerprint.count >= 4,
           candidateWords.count >= followingFingerprint.count,
           Array(candidateWords.suffix(followingFingerprint.count)) == followingFingerprint {
            return true
        }

        return false
    }

    private static func containsStreamingPromptScaffolding(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("preceding context")
            || normalized.contains("following context")
            || normalized.contains("target segment")
            || normalized.contains("do not return")
            || normalized.contains("return only this")
    }

    private static func passesBasicSafety(
        _ candidate: String,
        for source: String
    ) -> Bool {
        guard !candidate.isEmpty,
              !containsStructuredWrapper(candidate),
              preservesNumericFacts(from: source, in: candidate),
              candidate.count <= source.count * 2 + 120 else {
            return false
        }
        return true
    }

    /// Small models like to wrap foreign or unfamiliar terms in Markdown
    /// emphasis. Because the safety projection compares words only, stripping
    /// the markers is safe when the source contains none of them, and avoids a
    /// retry that would otherwise reject an otherwise correct edit.
    static func strippingEmphasisMarkup(
        from candidate: String,
        absentFrom source: String
    ) -> String {
        var result = candidate
        if !source.contains("*"), result.contains("*") {
            result = result.replacingOccurrences(of: "*", with: "")
        }
        if !source.contains("_"), result.contains("_") {
            result = result.replacingOccurrences(
                of: #"(?<![\p{L}\p{N}])_([^_\n]+)_(?![\p{L}\p{N}])"#,
                with: "$1",
                options: .regularExpression
            )
        }
        return result
    }

    /// Removes a sentence terminator the model placed after a word that does
    /// not end a sentence in the source when the following word is lowercase.
    /// A 0.6B model sometimes replaces a deleted echo with a period, producing
    /// "dummy text. of the printing" from "dummy text text of the printing".
    static func removingInsertedSentenceBreaks(
        from candidate: String,
        for source: String
    ) -> String {
        let sourceTokens = wordTokens(in: source)
        let candidateTokens = wordTokens(in: candidate)
        guard !sourceTokens.isEmpty, !candidateTokens.isEmpty else { return candidate }

        var matchedSourceIndex: [Int: Int] = [:]
        for step in wordAlignment(
            source: sourceTokens.map(\.normalized),
            candidate: candidateTokens.map(\.normalized)
        ) {
            if case let .match(sourceIndex, candidateIndex) = step {
                matchedSourceIndex[candidateIndex] = sourceIndex
            }
        }

        var removals: [String.Index] = []
        for (candidateIndex, token) in candidateTokens.enumerated() {
            let terminatorIndex = token.range.upperBound
            guard terminatorIndex < candidate.endIndex,
                  StreamingTranscriptPolicy.isStrongTerminator(candidate[terminatorIndex]) else {
                continue
            }
            var cursor = candidate.index(after: terminatorIndex)
            guard cursor < candidate.endIndex, candidate[cursor].isWhitespace else { continue }
            while cursor < candidate.endIndex, candidate[cursor].isWhitespace {
                cursor = candidate.index(after: cursor)
            }
            guard cursor < candidate.endIndex, candidate[cursor].isLowercase else { continue }

            if let sourceIndex = matchedSourceIndex[candidateIndex],
               StreamingTranscriptPolicy.hasStrongBoundary(
                   after: sourceTokens[sourceIndex].range.upperBound,
                   in: source
               ) {
                continue
            }
            removals.append(terminatorIndex)
        }

        var result = candidate
        for index in removals.reversed() {
            result.remove(at: index)
        }
        return result
    }

    private static func introducesPresentationMarkup(
        _ candidate: String,
        absentFrom source: String
    ) -> Bool {
        let fixedMarkers = ["```", "**", "__", "~~"]
        if fixedMarkers.contains(where: {
            candidate.contains($0) && !source.contains($0)
        }) {
            return true
        }

        let pairedEmphasisPatterns = [
            #"(?s)\*[^*\n]+\*"#,
            #"(?s)_[^_\n]+_"#,
        ]
        return pairedEmphasisPatterns.contains { pattern in
            candidate.range(of: pattern, options: .regularExpression) != nil
                && source.range(of: pattern, options: .regularExpression) == nil
        }
    }

    private struct WordToken {
        let normalized: String
        let original: String
        let range: Range<String.Index>
    }

    private enum WordAlignmentStep {
        case match(source: Int, candidate: Int)
        case substitute(source: Int, candidate: Int)
        case deleteSource(Int)
        case insertCandidate(Int)
    }

    private static func wordTokens(in text: String) -> [WordToken] {
        var result: [WordToken] = []
        var start: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else if let wordStart = start {
                let range = wordStart..<index
                let original = String(text[range])
                result.append(
                    WordToken(
                        normalized: original.lowercased(),
                        original: original,
                        range: range
                    )
                )
                start = nil
            }
            index = text.index(after: index)
        }

        if let start {
            let range = start..<text.endIndex
            let original = String(text[range])
            result.append(
                WordToken(
                    normalized: original.lowercased(),
                    original: original,
                    range: range
                )
            )
        }
        return result
    }

    private static func wordAlignment(
        source: [String],
        candidate: [String]
    ) -> [WordAlignmentStep] {
        var distances = Array(
            repeating: Array(repeating: 0, count: candidate.count + 1),
            count: source.count + 1
        )
        for index in 0...source.count { distances[index][0] = index }
        for index in 0...candidate.count { distances[0][index] = index }

        if !source.isEmpty, !candidate.isEmpty {
            for sourceIndex in 1...source.count {
                for candidateIndex in 1...candidate.count {
                    let substitution = distances[sourceIndex - 1][candidateIndex - 1]
                        + (source[sourceIndex - 1] == candidate[candidateIndex - 1] ? 0 : 1)
                    distances[sourceIndex][candidateIndex] = min(
                        substitution,
                        distances[sourceIndex - 1][candidateIndex] + 1,
                        distances[sourceIndex][candidateIndex - 1] + 1
                    )
                }
            }
        }

        var steps: [WordAlignmentStep] = []
        var sourceIndex = source.count
        var candidateIndex = candidate.count
        while sourceIndex > 0 || candidateIndex > 0 {
            if sourceIndex > 0,
               candidateIndex > 0,
               source[sourceIndex - 1] == candidate[candidateIndex - 1],
               distances[sourceIndex][candidateIndex]
                    == distances[sourceIndex - 1][candidateIndex - 1] {
                steps.append(
                    .match(source: sourceIndex - 1, candidate: candidateIndex - 1)
                )
                sourceIndex -= 1
                candidateIndex -= 1
            } else if sourceIndex > 0,
                      candidateIndex > 0,
                      distances[sourceIndex][candidateIndex]
                        == distances[sourceIndex - 1][candidateIndex - 1] + 1 {
                steps.append(
                    .substitute(source: sourceIndex - 1, candidate: candidateIndex - 1)
                )
                sourceIndex -= 1
                candidateIndex -= 1
            } else if sourceIndex > 0,
                      distances[sourceIndex][candidateIndex]
                        == distances[sourceIndex - 1][candidateIndex] + 1 {
                steps.append(.deleteSource(sourceIndex - 1))
                sourceIndex -= 1
            } else {
                steps.append(.insertCandidate(candidateIndex - 1))
                candidateIndex -= 1
            }
        }
        return Array(steps.reversed())
    }

    private static func orderedWordOverlapLength(
        _ source: [String],
        _ candidate: [String]
    ) -> Int {
        var previous = Array(repeating: 0, count: candidate.count + 1)
        for sourceWord in source {
            var current = Array(repeating: 0, count: candidate.count + 1)
            for (index, candidateWord) in candidate.enumerated() {
                if sourceWord == candidateWord {
                    current[index + 1] = previous[index] + 1
                } else {
                    current[index + 1] = max(
                        previous[index + 1],
                        current[index]
                    )
                }
            }
            previous = current
        }
        return previous[candidate.count]
    }

    /// Returns the source word indices a candidate omits when every candidate
    /// word comes from the source in order, or nil when the candidate
    /// substitutes or invents a word.
    private static func orderedSubsetDeletionIndices(
        of candidate: String,
        from source: String
    ) -> Set<Int>? {
        let sourceWords = words(in: source)
        let candidateWords = words(in: candidate)
        guard !sourceWords.isEmpty, !candidateWords.isEmpty else { return nil }

        var deletions = Set<Int>()
        for step in wordAlignment(source: sourceWords, candidate: candidateWords) {
            switch step {
            case .match:
                break
            case let .deleteSource(sourceIndex):
                deletions.insert(sourceIndex)
            case .substitute, .insertCandidate:
                return nil
            }
        }
        return deletions
    }

    private enum DeletionBudget {
        case conservative
        case recovery
    }

    /// Lexical deletions are allowed only for visible speech mistakes: complete
    /// copies of immediately repeated speech, partial-word retries, and, once
    /// repeated speech proves the passage is disfluent, a small number of
    /// nearby false starts the model identified.
    private static func deletionsAreWithinBudget(
        _ deletedIndices: Set<Int>,
        in tokens: [WordToken],
        source: String,
        budget: DeletionBudget
    ) -> Bool {
        let words = tokens.map(\.normalized)
        guard deletionsRespectImmediateRepeatedSpeech(deletedIndices, in: words) else {
            return false
        }

        let repeatedSpeechAllowance = repeatedSpeechWordCount(in: words)
        let partialWordRetryAllowance = partialWordRetryDeletionCount(
            deletedIndices,
            in: tokens,
            source: source
        )
        let otherDisfluencyAllowance: Int
        switch budget {
        case .conservative:
            otherDisfluencyAllowance = repeatedSpeechAllowance > 0
                ? max(4, words.count / 16)
                : 0
        case .recovery:
            otherDisfluencyAllowance = repeatedSpeechAllowance > 0
                ? max(2, words.count / 20)
                : 0
        }
        return deletedIndices.count
            <= repeatedSpeechAllowance
            + partialWordRetryAllowance
            + otherDisfluencyAllowance
    }

    /// Counts deleted words that are a strict prefix of the next retained word,
    /// such as "s simply" or "typ typesetting": a speaker restarting a word.
    /// Tokens attached to the preceding word by an apostrophe or hyphen
    /// ("industry's standard", "re-read") are never treated as retries.
    private static func partialWordRetryDeletionCount(
        _ deletedIndices: Set<Int>,
        in tokens: [WordToken],
        source: String
    ) -> Int {
        var count = 0
        for index in deletedIndices.sorted() where index < tokens.count {
            guard !isAttachedToPrecedingWord(tokens[index], in: source) else { continue }

            var nextIndex = index + 1
            while nextIndex < tokens.count, deletedIndices.contains(nextIndex) {
                nextIndex += 1
            }
            guard nextIndex < tokens.count,
                  !isAttachedToPrecedingWord(tokens[nextIndex], in: source) else {
                continue
            }

            let fragment = tokens[index].normalized
            let completed = tokens[nextIndex].normalized
            if completed.count > fragment.count, completed.hasPrefix(fragment) {
                count += 1
            }
        }
        return count
    }

    private static func isAttachedToPrecedingWord(
        _ token: WordToken,
        in source: String
    ) -> Bool {
        guard token.range.lowerBound > source.startIndex else { return false }
        let joiners: Set<Character> = ["'", "’", "-", "‐", "‑", "–"]
        return joiners.contains(source[source.index(before: token.range.lowerBound)])
    }

    /// A model may remove a complete copy of an adjacent repeated phrase, but
    /// never only part of one. This is a language-agnostic safety check: Qwen
    /// still decides whether the repetition is accidental, while malformed
    /// edits such as deleting only "is" from "is kings is kings" are rejected.
    private static func deletionsRespectImmediateRepeatedSpeech(
        _ deletedIndices: Set<Int>,
        in words: [String]
    ) -> Bool {
        for copies in immediateRepeatedSpeechCopies(in: words) {
            for copy in [copies.first, copies.second] {
                let touched = copy.contains { deletedIndices.contains($0) }
                if touched && !copy.allSatisfy({ deletedIndices.contains($0) }) {
                    return false
                }
            }
        }
        return true
    }

    private static func immediateRepeatedSpeechCopies(
        in words: [String]
    ) -> [(first: Range<Int>, second: Range<Int>)] {
        guard words.count >= 2 else { return [] }

        var copies: [(first: Range<Int>, second: Range<Int>)] = []
        var index = 0
        while index < words.count - 1 {
            let maximumSpan = min(8, (words.count - index) / 2)
            var matchedSpan = 0

            if maximumSpan > 0 {
                for span in stride(from: maximumSpan, through: 1, by: -1) {
                    let first = words[index..<(index + span)]
                    let second = words[(index + span)..<(index + span * 2)]
                    if first.elementsEqual(second) {
                        matchedSpan = span
                        break
                    }
                }
            }

            if matchedSpan > 0 {
                copies.append(
                    (
                        first: index..<(index + matchedSpan),
                        second: (index + matchedSpan)..<(index + matchedSpan * 2)
                    )
                )
                index += matchedSpan * 2
            } else {
                index += 1
            }
        }
        return copies
    }

    /// Counts words contained in immediately repeated speech spans such as
    /// "has been has been". This does not edit text; it only gives the model's
    /// guarded recovery output an omission budget that works in any language.
    private static func repeatedSpeechWordCount(in words: [String]) -> Int {
        immediateRepeatedSpeechCopies(in: words).reduce(0) {
            $0 + $1.first.count
        }
    }

    private static func preservesNumericFacts(from source: String, in candidate: String) -> Bool {
        var remaining = numericFacts(in: candidate)
        for fact in numericFacts(in: source) {
            guard let index = remaining.firstIndex(of: fact) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    private static func numericFacts(in text: String) -> [String] {
        let pattern = #"\p{N}+(?:[.,]\p{N}+)*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range].filter(\.isNumber))
        }
    }

    private static func unwrapJSONContainer(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        guard let object = value as? [String: Any] else { return nil }
        for key in ["transcript", "text", "output", "result", "response"] {
            if let string = object[key] as? String {
                return string
            }
        }
        return nil
    }

    private static func unwrapMarkupContainer(_ text: String) -> String? {
        let pattern = #"(?is)^\s*<([A-Za-z][A-Za-z0-9:_-]*)(?:\s[^>]*)?>\s*(.*?)\s*</\1>\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              let contentRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return String(text[contentRange])
    }

    private static func containsStructuredWrapper(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            || trimmed.hasPrefix("```") {
            return true
        }

        return trimmed.range(
            of: #"(?is)</?[A-Za-z][^>]*>"#,
            options: .regularExpression
        ) != nil
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
    }
}

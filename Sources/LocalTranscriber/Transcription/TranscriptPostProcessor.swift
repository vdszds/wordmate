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

    /// Indices (into `StreamingTranscriptPolicy.sentenceSegments(in:)`) of the
    /// sentences that should start a new paragraph in a finished transcript.
    func paragraphStarts(
        in transcript: String,
        using model: PostProcessingModel
    ) async throws -> [Int]
}

extension TranscriptPolishing {
    func paragraphStarts(
        in transcript: String,
        using model: PostProcessingModel
    ) async throws -> [Int] {
        []
    }
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
        case paragraphs
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
        case paragraphs
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

        let trimmedCandidate = TranscriptPolishPolicy.trimmingLeakedContext(
            from: TranscriptPolishPolicy.trimmingToTarget(response.candidate, source: transcript),
            precedingContext: precedingContext,
            followingContext: followingContext
        )
        if TranscriptPolishPolicy.leaksStreamingContext(
            trimmedCandidate,
            precedingContext: precedingContext,
            followingContext: followingContext
        ) {
            record(response, stage: .streaming, outcome: .contextLeaked, source: transcript)
        } else if let candidate = TranscriptPolishPolicy.conservativeProjection(
            of: trimmedCandidate,
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

    func paragraphStarts(
        in transcript: String,
        using model: PostProcessingModel
    ) async throws -> [Int] {
        let sentences = StreamingTranscriptPolicy.sentenceSegments(in: transcript)
        guard TranscriptPolishPolicy.wantsParagraphs(sentences: sentences) else { return [] }
        try await prepare(model)
        guard loadedModel == model, let modelContainer else {
            throw LocalTranscriberError.modelCouldNotLoad(
                "\(model.displayName) is unavailable."
            )
        }
        let prompt = TranscriptPolishPolicy.paragraphPrompt(sentences: sentences)
        let response = try await respond(
            .paragraphs,
            to: prompt,
            source: prompt,
            modelContainer: modelContainer
        )
        record(response, stage: .paragraphs, outcome: .accepted, source: transcript)
        return TranscriptPolishPolicy.paragraphStarts(
            from: response.rawOutput,
            sentenceCount: sentences.count
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
        let parameters: GenerateParameters = {
            var parameters = Self.generationParameters(transcript: source)
            if case .paragraphs = kind {
                // "3, 7" is the whole answer; never let a small model ramble.
                parameters.maxTokens = 24
            }
            return parameters
        }()
        let promptCache = self.promptCache
        let enableThinking: Bool
        switch kind {
        case .polish:
            enableThinking = TranscriptPolishPolicy.reasoningEnabled
        case .recovery, .paragraphs:
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
            case .paragraphs:
                messages = [.system(TranscriptPolishPolicy.paragraphInstructions)]
                messages.append(contentsOf: TranscriptPolishPolicy.paragraphHistory)
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
        // Benchmark hook: lets the test suite compare another Hub model
        // through the production pipeline without changing the app's model.
        if let override = ProcessInfo.processInfo.environment["WORDMATE_POST_PROCESSING_MODEL_ID"],
           !override.isEmpty {
            return ModelConfiguration(id: override)
        }
        return LLMRegistry.qwen3_0_6b_4bit
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

/// Benchmark-only prompt overrides. Each hook reads a file named by an
/// environment variable; when the variable is unset the production prompt
/// below is used unchanged. This lets the prompt-iteration benchmark try
/// variants without editing the app.
private enum PromptOverride {
    static func text(_ variable: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty,
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A JSON array of {"user": ..., "assistant": ...} pairs.
    static func examples(_ variable: String) -> [Chat.Message]? {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty,
              let data = FileManager.default.contents(atPath: path),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return nil
        }
        return pairs.flatMap { pair -> [Chat.Message] in
            guard let user = pair["user"], let assistant = pair["assistant"] else { return [] }
            return [.user(user), .assistant(assistant)]
        }
    }
}

enum TranscriptPolishPolicy {
    static let reasoningEnabled = false

    static let instructions = PromptOverride.text("WORDMATE_POLISH_INSTRUCTIONS_FILE") ?? """
        You turn raw speech-to-text dictation into clean written text, the way a careful assistant edits a
        voice note before it goes into an email or a document. The speaker's words are the only source of
        content: keep their meaning, their wording and their order.

        Remove what is speech rather than content:
        - Filled pauses and filler words that carry no meaning: "um", "uh", "like", "you know", "I mean",
          "yeah", "basically", "kind of", "sort of", "right", "okay". "like" is a filler when it hedges or
          approximates ("I told him like ten times", "it's like almost done"), not when it compares ("like a
          person") or is the verb.
        - Stutters and echoes: "I think I think we" becomes "I think we"; "we placed we before we placed the
          order" becomes "before we placed the order".
        - Partial words: "sched schedule" becomes "schedule".
        - False starts, where the speaker abandons a phrase and starts again: "I agree we should give
          examples I think we but with this prompt the model does nothing" becomes "I agree we should give
          examples. But with this prompt the model does nothing."
        - Spoken self-corrections: "on Thursday, sorry, Friday" becomes "on Friday".
        - Connectives that only string spoken sentences together ("and", "so", "but", "because") at the start
          of a sentence that stands on its own without them.

        Write it properly:
        - Split run-on speech into sentences. Add periods, question marks, commas and quotation marks around
          quoted speech. Capitalize the first word of each sentence and proper nouns, and fix stray capital
          letters inside a sentence.
        - Keep every content word exactly as recognized: names, technical terms, unfamiliar or foreign words,
          numbers and units. Never replace, reorder, summarize or paraphrase content, never add words, and
          never guess what an unclear word was meant to be.
        - Keep deliberate repetition such as "very very good" or "kings is kings", and keep placeholder or
          quoted text as spoken.
        - An unfinished final fragment stays as it is.

        Return only the edited text as plain prose: no lists, no Markdown, no quotation marks around the
        whole text, no commentary.
        """

    static let recoveryInstructions = PromptOverride.text("WORDMATE_RECOVERY_INSTRUCTIONS_FILE") ?? """
        Remove only unmistakable speech disfluencies from the user's transcript: accidental repetitions such
        as "I think I think", abandoned partial words, filler words such as "um", "like", "you know" and
        "I mean", and false starts. Scan the complete transcript and remove every such disfluency, not only
        the first. A repeated intensifier such as "very very good" is intentional emphasis and must stay, as
        are deliberate constructions such as "kings is kings". Copy all other words in the same order and
        fix only punctuation and capitalization. Never summarize or restore text from memory. Return only
        the complete transcript.
        """

    static let maximumChunkCharacters = 2_400
    private static let fallbackChunkCharacters = 220

    static let fewShotHistory: [Chat.Message] = PromptOverride.examples("WORDMATE_POLISH_EXAMPLES_FILE") ?? [
        .user("so um I'm just I'm just checking in to see if there have been any updates on our order and whether everything is still going according to plan"),
        .assistant("I'm just checking in to see if there have been any updates on our order and whether everything is still going according to plan."),
        .user("I told him like ten times that we will be away in September and like he said that he understood blah blah blah and now we get a notification that we need to collect the car on the sixteenth"),
        .assistant("I told him ten times that we will be away in September and he said that he understood, blah blah blah. Now we get a notification that we need to collect the car on the sixteenth."),
        .user("I agree we should give examples I think we but with this prompt the post-processing model essentially does almost nothing it only removes repeated words"),
        .assistant("I agree we should give examples. But with this prompt, the post-processing model essentially does almost nothing. It only removes repeated words."),
        .user("We should deploy on Thursday, sorry, I mean Friday, after after the tests pass."),
        .assistant("We should deploy on Friday after the tests pass."),
        .user("and you know we don't have insurance right so I mean how do we fill in the insurance agreement now"),
        .assistant("We don't have insurance, right? How do we fill in the insurance agreement now?"),
        .user("so yeah the marketing team said that like you can just basically use this template and then like select the distribution list once you send it out"),
        .assistant("The marketing team said that you can just use this template and then select the distribution list once you send it out."),
        .user("and he's now like not super responsive so like I don't know the status of the documents you know"),
        .assistant("He's now not super responsive. I don't know the status of the documents."),
        .user("then I gave him a call again and asked hey didn't we agree that Tesla will do it he said oh yeah yeah Tesla will do it which was a bit surprising"),
        .assistant("Then I gave him a call again and asked, \"Hey, didn't we agree that Tesla will do it?\" He said, \"Oh yeah, yeah, Tesla will do it,\" which was a bit surprising."),
        .user("did you see the report Doesn't it look like the numbers are off"),
        .assistant("Did you see the report? Doesn't it look like the numbers are off?"),
        .user("It can log into websites and click around like a person, and honestly I like that approach."),
        .assistant("It can log into websites and click around like a person, and honestly I like that approach."),
        .user("The result was very very good, exactly what we wanted, and the studio by the botanical gardens kept the term velorum."),
        .assistant("The result was very very good, exactly what we wanted, and the studio by the botanical gardens kept the term velorum."),
        .user("Listen then, Amara, to a story of Rowan, who told it to Elias."),
        .assistant("Listen then, Amara, to a story of Rowan, who told it to Elias."),
        .user("Surface dust at least had been removed and the ideas also remain while the practice was very generally accepted."),
        .assistant("Surface dust, at least, had been removed, and the ideas also remain, while the practice was very generally accepted."),
        .user("So saying, she meanwhile crossed the square. There"),
        .assistant("So saying, she, meanwhile, crossed the square. There"),
        .user("All I say is kings is kings and you got to make allowances."),
        .assistant("All I say is, kings is kings, and you got to make allowances."),
    ]

    static let recoveryHistory: [Chat.Message] = PromptOverride.examples("WORDMATE_RECOVERY_EXAMPLES_FILE") ?? [
        .user("The result was very very good, exactly what we wanted."),
        .assistant("The result was very very good, exactly what we wanted."),
        .user("Northstar Northstar is like a scheduling tool tool for retail teams you know."),
        .assistant("Northstar is a scheduling tool for retail teams."),
        .user("I think I think we should update this function before before merging."),
        .assistant("I think we should update this function before merging."),
        .user("All I say is, kings is kings, and you got to make allowances."),
        .assistant("All I say is, kings is kings, and you got to make allowances."),
    ]

    static func prompt(for transcript: String) -> String {
        if let template = PromptOverride.text("WORDMATE_POLISH_PROMPT_FILE") {
            return template.replacingOccurrences(of: "{{TRANSCRIPT}}", with: transcript)
        }
        return """
        Edit the dictated transcript below into clean written text. Remove filler words, stutters, echoes,
        partial words, false starts and spoken self-corrections, and drop connectives that only chain spoken
        sentences together. Fillers to remove: hedging "like", "you know", "I mean", "yeah", "basically",
        "kind of", "sort of", "right", and "so", "and", "but", "because" when they only open a spoken
        sentence. Keep every other word exactly as recognized and in order: do not rewrite,
        summarize, add words or guess recognition errors. Split it into proper sentences with punctuation and
        capitalization, put quotation marks around quoted speech, and keep numbers as recognized. Keep
        deliberate repetition and an unfinished final fragment. Return only the complete edited text as plain
        prose, without lists or commentary.

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

        if let template = PromptOverride.text("WORDMATE_STREAMING_PROMPT_FILE") {
            return template
                .replacingOccurrences(of: "{{BEFORE}}", with: before)
                .replacingOccurrences(of: "{{TARGET}}", with: transcript)
                .replacingOccurrences(of: "{{AFTER}}", with: after)
        }

        return """
        Edit only the target segment below into clean written text. The surrounding passages are context
        only: use them to see where sentences begin and end and what the speaker corrected, but never include
        their words in your answer.
        Remove filler words, stutters, echoes, partial words, false starts and spoken self-corrections from
        the target, and drop a connective that only chains it to the previous spoken sentence. Fillers to
        remove: hedging "like", "you know", "I mean", "yeah", "basically", "kind of", "sort of", "right",
        and "so", "and", "but", "because" when they only open a spoken sentence. Keep every other target
        word exactly as recognized and in order: do not rewrite, summarize, add words or guess recognition
        errors. Punctuate and capitalize it as it should read inside the full text, with
        quotation marks around quoted speech, and keep numbers as recognized. Keep deliberate repetition and
        an unfinished final fragment. Return only the complete edited target segment as plain text.

        PRECEDING CONTEXT — DO NOT RETURN
        \(before)

        TARGET SEGMENT — RETURN ONLY THIS
        \(transcript)

        FOLLOWING CONTEXT — DO NOT RETURN
        \(after)
        """
    }

    // MARK: Paragraphs

    static let paragraphInstructions = PromptOverride.text("WORDMATE_PARAGRAPH_INSTRUCTIONS_FILE") ?? """
        You decide where paragraph breaks belong in a dictated text, as in a well-written email or note. The
        text is given as numbered sentences. A new paragraph starts only where the speaker moves on to a
        clearly new point, topic, step, time or addressee. Paragraphs hold three to six sentences, so most
        texts need one to three breaks and short texts need none.
        Reply with only the numbers of the sentences that start a new paragraph, separated by commas, in
        increasing order, for example "4, 8". Reply "none" when the text should stay one paragraph.
        """

    static let paragraphHistory: [Chat.Message] = PromptOverride.examples("WORDMATE_PARAGRAPH_EXAMPLES_FILE") ?? [
        .user("[1] Hi Dana, quick update on the launch. [2] The website copy is final and legal signed off yesterday. [3] The pricing page still needs the new tiers, which Sam is adding today. [4] On the event side, we have 40 confirmed attendees and the venue is booked until 9 pm. [5] Catering is confirmed for 50. [6] One open question is whether we record the talks. [7] I'd rather not, because two speakers asked for it to stay internal. [8] Let me know if you disagree. [9] Thanks, Robin."),
        .assistant("4, 6, 9"),
        .user("[1] The parser rejects any header longer than 512 bytes. [2] That limit comes from the original spec and most clients stay well below it. [3] We could raise it, but the proxy in front of us has the same limit. [4] So raising ours alone would not change anything."),
        .assistant("none"),
    ]

    /// Minimum size before a paragraph pass is worth a model call.
    static let minimumParagraphSentences = 8
    static let minimumParagraphWords = 120
    static let minimumSentencesPerParagraph = 3
    /// Paragraphs are placed from the speaker's pauses (`ParagraphPlanner`).
    /// Asking the model instead is an experiment that small models failed.
    static let modelParagraphsEnabled = ProcessInfo.processInfo.environment["WORDMATE_MODEL_PARAGRAPHS"] == "1"

    static func wantsParagraphs(sentences: [String]) -> Bool {
        guard sentences.count >= minimumParagraphSentences else { return false }
        let words = sentences.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        return words >= minimumParagraphWords
    }

    static func paragraphPrompt(sentences: [String]) -> String {
        sentences.enumerated()
            .map { "[\($0.offset + 1)] \($0.element)" }
            .joined(separator: " ")
    }

    /// Parses "3, 7" (or "[3] [7]", "3 and 7", "none") into zero-based sentence
    /// indices, keeping paragraphs at least two sentences long.
    static func paragraphStarts(from output: String, sentenceCount: Int) -> [Int] {
        let cleaned = cleanModelOutput(output)
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#) else { return [] }
        let numbers = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            .compactMap { Range($0.range, in: cleaned) }
            .compactMap { Int(cleaned[$0]) }
        // A model that lists most sentences has not understood the task.
        let distinct = Set(numbers)
        guard !distinct.isEmpty, distinct.count <= max(3, sentenceCount / 3) else { return [] }
        var starts: [Int] = []
        var previousStart = 0
        for number in distinct.sorted() {
            let index = number - 1
            guard index >= minimumSentencesPerParagraph,
                  index < sentenceCount,
                  index - previousStart >= minimumSentencesPerParagraph,
                  sentenceCount - index >= 2 else { continue }
            starts.append(index)
            previousStart = index
        }
        return starts
    }

    static func applyingParagraphBreaks(to transcript: String, startingAt starts: [Int]) -> String {
        guard !starts.isEmpty else { return transcript }
        let sentences = StreamingTranscriptPolicy.sentenceSegments(in: transcript)
        let startSet = Set(starts)
        var result = ""
        for (index, sentence) in sentences.enumerated() {
            if index > 0 {
                result += startSet.contains(index) ? "\n\n" : " "
            }
            result += sentence
        }
        return result
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
              preservesNumericFacts(from: source, in: candidate),
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

        // Substituted words were restored above, so a missing numeral here
        // means the model dropped it rather than spelled it out.
        guard preservesNumericFacts(from: source, in: projected),
              isConservativeEditAcceptable(projected, for: source) else {
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

    /// Small models often answer with the target plus the sentence that
    /// follows it, or start by repeating the end of the preceding context.
    /// When the copied halo sits cleanly at either edge, cut it off instead of
    /// rejecting an otherwise good edit.
    static func trimmingLeakedContext(
        from candidate: String,
        precedingContext: String,
        followingContext: String
    ) -> String {
        var result = trimmingToTarget(candidate, source: nil)
        let followingWords = words(in: followingContext)
        let followingFingerprint = Array(followingWords.prefix(min(8, followingWords.count)))
        if followingFingerprint.count >= 4 {
            let tokens = wordTokens(in: result)
            let normalized = tokens.map(\.normalized)
            if normalized.count > followingFingerprint.count,
               let start = normalized.indices.reversed().first(where: { index in
                   normalized[index...].starts(with: followingFingerprint)
               }),
               start >= 2 {
                result = String(result[..<tokens[start].range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let precedingWords = words(in: precedingContext)
        let precedingFingerprint = Array(precedingWords.suffix(min(8, precedingWords.count)))
        if precedingFingerprint.count >= 4 {
            let tokens = wordTokens(in: result)
            let normalized = tokens.map(\.normalized)
            if normalized.count > precedingFingerprint.count,
               normalized.starts(with: precedingFingerprint) {
                let cut = tokens[precedingFingerprint.count].range.lowerBound
                result = String(result[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    /// When the answer is much longer than the target and the target's first
    /// words appear well inside it, the model prefixed context; when the
    /// target's last words appear well before the end, it appended context.
    static func trimmingToTarget(_ candidate: String, source: String?) -> String {
        guard let source else { return candidate }
        let sourceWords = words(in: source)
        guard sourceWords.count >= 4 else { return candidate }
        var result = candidate
        var tokens = wordTokens(in: result)
        var normalized = tokens.map(\.normalized)
        guard normalized.count > sourceWords.count + 3 else { return candidate }

        let head = Array(sourceWords.prefix(4))
        if let start = normalized.indices.first(where: { normalized[$0...].starts(with: head) }),
           start >= 3 {
            result = String(result[tokens[start].range.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            tokens = wordTokens(in: result)
            normalized = tokens.map(\.normalized)
        }
        let tail = Array(sourceWords.suffix(4))
        if normalized.count > sourceWords.count + 3,
           let end = normalized.indices.reversed().first(where: { index in
               index + tail.count <= normalized.count && normalized[index..<(index + tail.count)].elementsEqual(tail)
           }),
           normalized.count - (end + tail.count) >= 3 {
            let cut = tokens[end + tail.count - 1].range.upperBound
            var trimmed = String(result[..<cut])
            // Keep the terminator that followed the last target word.
            if cut < result.endIndex, StreamingTranscriptPolicy.isStrongTerminator(result[cut]) {
                trimmed.append(result[cut])
            }
            result = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
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

    /// Handles a sentence terminator the model placed after a word that does
    /// not end a sentence in the source when the following word is lowercase.
    /// Between two adjacent source words that is a genuine sentence split the
    /// model forgot to capitalize, so the next word is capitalized. Next to a
    /// deletion it is a period standing in for removed speech ("dummy text.
    /// of the printing" from "dummy text text of the printing") and is removed.
    static func removingInsertedSentenceBreaks(
        from candidate: String,
        for source: String
    ) -> String {
        let sourceTokens = wordTokens(in: source)
        let candidateTokens = wordTokens(in: candidate)
        guard !sourceTokens.isEmpty, !candidateTokens.isEmpty else { return candidate }

        var matchedSourceIndex: [Int: Int] = [:]
        var matchedSourceIndices = Set<Int>()
        for step in wordAlignment(
            source: sourceTokens.map(\.normalized),
            candidate: candidateTokens.map(\.normalized)
        ) {
            if case let .match(sourceIndex, candidateIndex) = step {
                matchedSourceIndex[candidateIndex] = sourceIndex
                matchedSourceIndices.insert(sourceIndex)
            }
        }

        enum Fix {
            case remove(String.Index)
            case capitalize(String.Index)
        }
        var fixes: [(position: String.Index, fix: Fix)] = []
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

            guard let sourceIndex = matchedSourceIndex[candidateIndex] else {
                fixes.append((terminatorIndex, .remove(terminatorIndex)))
                continue
            }
            if StreamingTranscriptPolicy.hasStrongBoundary(
                after: sourceTokens[sourceIndex].range.upperBound,
                in: source
            ) {
                continue
            }
            let previousDeleted = sourceIndex > 0 && !matchedSourceIndices.contains(sourceIndex - 1)
            let nextDeleted = sourceIndex + 1 < sourceTokens.count
                && !matchedSourceIndices.contains(sourceIndex + 1)
            if !previousDeleted, !nextDeleted,
               let nextSourceIndex = matchedSourceIndex[candidateIndex + 1],
               nextSourceIndex == sourceIndex + 1 {
                fixes.append((cursor, .capitalize(cursor)))
            } else {
                fixes.append((terminatorIndex, .remove(terminatorIndex)))
            }
        }

        var result = candidate
        for entry in fixes.sorted(by: { $0.position > $1.position }) {
            switch entry.fix {
            case let .remove(index):
                result.remove(at: index)
            case let .capitalize(index):
                let uppercased = String(result[index]).uppercased()
                result.replaceSubrange(index...index, with: uppercased)
            }
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
    /// Words a speaker uses to keep talking rather than to say something. The
    /// model may delete them (up to a share of the segment) without drawing on
    /// the small budget reserved for false starts and self-corrections.
    static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "hmm", "mm", "mhm", "ah", "oh", "er", "erm",
        "like", "yeah", "yes", "basically", "actually",
        "right", "okay", "ok", "well", "anyway", "literally", "honestly", "obviously", "essentially",
    ]

    /// Connectives that only chain spoken sentences ("…on the 28th, and he
    /// mentioned…"). They are fillers only before a pronoun-like
    /// continuation; "Mr. and Mrs." or "bread and butter" are content.
    static let connectiveWords: Set<String> = ["and", "but", "or", "so", "because", "then"]
    static let connectiveContinuations: Set<String> = [
        "i", "we", "you", "he", "she", "they", "it", "this", "that", "there", "then", "now", "so",
        "like", "yeah", "um", "uh", "also", "just", "basically", "actually", "what", "when", "where",
        "how", "why", "if", "my", "our", "your", "his", "her", "their", "its",
    ]

    /// Word tokens split at apostrophes, so "I don't know" is ["i", "don", "t", "know"].
    static let fillerPhrases: [[String]] = [
        ["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"], ["i", "guess"],
        ["you", "see"], ["or", "so"], ["or", "something"], ["or", "whatever"],
        ["and", "stuff"], ["and", "so", "on"], ["i", "don", "t", "know"], ["it", "s", "like"],
        ["blah", "blah", "blah"],
    ]

    /// Words that begin a clause after a false start ("I think we | but with
    /// this prompt"). Case-insensitive; a capitalized word also qualifies.
    static let clauseStarters: Set<String> = [
        "i", "we", "you", "he", "she", "they", "it", "this", "that", "there", "these", "those",
        "what", "when", "where", "why", "how", "who", "which", "and", "but", "so", "because",
        "then", "or", "if", "let", "my", "our", "your", "now", "okay", "well",
    ]

    /// Words that mark a spoken self-correction inside a deleted run.
    static let correctionCues: Set<String> = [
        "sorry", "mean", "no", "actually", "rather", "correction", "scratch", "wait",
    ]

    /// Counts deleted words that are fillers or parts of filler phrases.
    private static func fillerDeletionCount(_ deletedIndices: Set<Int>, in tokens: [WordToken]) -> Int {
        let words = tokens.map(\.normalized)
        let sorted = deletedIndices.sorted().filter { $0 < words.count }
        var count = 0
        var runStart = 0
        while runStart < sorted.count {
            var runEnd = runStart
            while runEnd + 1 < sorted.count, sorted[runEnd + 1] == sorted[runEnd] + 1 {
                runEnd += 1
            }
            var position = sorted[runStart]
            let end = sorted[runEnd]
            while position <= end {
                var matchedPhrase = 0
                for phrase in fillerPhrases where position + phrase.count - 1 <= end {
                    if words[position..<(position + phrase.count)].elementsEqual(phrase) {
                        matchedPhrase = phrase.count
                        break
                    }
                }
                if matchedPhrase > 0 {
                    count += matchedPhrase
                    position += matchedPhrase
                    continue
                }
                if fillerWords.contains(words[position]) {
                    count += 1
                } else if connectiveWords.contains(words[position]),
                          position + 1 < tokens.count,
                          connectiveContinuations.contains(words[position + 1]),
                          words[position + 1] == "i" || tokens[position + 1].original.first?.isUppercase != true {
                    count += 1
                }
                position += 1
            }
            runStart = runEnd + 1
        }
        return count
    }

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

        // Fillers may go freely, but never most of a segment: a model that
        // "cleans" half the words has stopped editing and started summarizing.
        let fillerAllowance = min(
            fillerDeletionCount(deletedIndices, in: tokens),
            max(4, words.count * 2 / 5)
        )
        let repeatedSpeechAllowance = repeatedSpeechWordCount(in: words)
        let partialWordRetryAllowance = partialWordRetryDeletionCount(
            deletedIndices,
            in: tokens,
            source: source
        )
        // A false start is a run of words the speaker abandoned. A single
        // content word on its own ("would", "very", "the") is never a false
        // start; dropping it is paraphrase, however fluent the result reads.
        guard !deletesLoneContentWords(deletedIndices, in: tokens, source: source) else {
            return false
        }
        // False starts, restarts and spoken corrections are short. This budget
        // is deliberately small so optional fluent words cannot be dropped at
        // scale, while a "the model I think we but with this" abandonment can.
        let otherDisfluencyAllowance: Int
        switch budget {
        case .conservative:
            otherDisfluencyAllowance = max(3, words.count / 8)
        case .recovery:
            otherDisfluencyAllowance = max(2, words.count / 12)
        }
        return deletedIndices.count
            <= fillerAllowance
            + repeatedSpeechAllowance
            + partialWordRetryAllowance
            + otherDisfluencyAllowance
    }

    /// Whether any deleted run consists of exactly one word that is neither a
    /// filler, part of a filler phrase, a copy of immediately repeated speech,
    /// nor a partial-word retry.
    private static func deletesLoneContentWords(
        _ deletedIndices: Set<Int>,
        in tokens: [WordToken],
        source: String
    ) -> Bool {
        let words = tokens.map(\.normalized)
        var protected = Set<Int>()
        for copies in immediateRepeatedSpeechCopies(in: words) {
            protected.formUnion(copies.first)
            protected.formUnion(copies.second)
        }
        // A deleted word that repeats the nearest retained word on either side
        // is a restart interrupted by a filler ("before, um, before").
        for index in deletedIndices where index < words.count {
            var next = index + 1
            while next < words.count, deletedIndices.contains(next) { next += 1 }
            var previous = index - 1
            while previous >= 0, deletedIndices.contains(previous) { previous -= 1 }
            if (next < words.count && words[next] == words[index])
                || (previous >= 0 && words[previous] == words[index]) {
                protected.insert(index)
            }
        }
        let sorted = deletedIndices.sorted().filter { $0 < words.count }
        var runStart = 0
        while runStart < sorted.count {
            var runEnd = runStart
            while runEnd + 1 < sorted.count, sorted[runEnd + 1] == sorted[runEnd] + 1 {
                runEnd += 1
            }
            let run = Set(sorted[runStart...runEnd])
            let fillers = fillerDeletionCount(run, in: tokens)
            let retries = partialWordRetryDeletionCount(run, in: tokens, source: source)
            let echoes = run.filter { protected.contains($0) }.count
            let contentWords = run.count - min(run.count, fillers + retries + echoes)
            if contentWords == 1, run.count - fillers == 1 {
                return true
            }
            let first = sorted[runStart]
            let last = sorted[runEnd]
            if contentWords > 0 {
                // A false start is abandoned speech that the speaker restarts,
                // so the words after it begin a clause. A run followed by the
                // end of the text or by an ordinary continuation ("by Cicero
                // written in", "the program at the time.") is content.
                let next = last + 1
                guard next < tokens.count else { return true }
                let nextWord = words[next]
                let nextCapitalized = tokens[next].original.first?.isUppercase == true
                guard clauseStarters.contains(nextWord) || nextCapitalized else { return true }
                // And it begins like speech that was restarted: with a
                // pronoun, a filler, or a fresh sentence, never with "to it"
                // or "by Cicero" lifted out of a fluent phrase.
                let firstWord = words[first]
                let firstCapitalized = tokens[first].original.first?.isUppercase == true
                guard clauseStarters.contains(firstWord) || fillerWords.contains(firstWord)
                    || connectiveWords.contains(firstWord) || firstCapitalized else { return true }
                // Names are never false starts. A capitalized word inside the
                // run that does not start a sentence is a name or a term,
                // unless the speaker corrected it ("Thursday, sorry, Friday").
                let isCorrection = run.contains { correctionCues.contains(words[$0]) }
                for index in sorted[runStart...runEnd]
                where index > 0 && !protected.contains(index) && !isCorrection {
                    let token = tokens[index]
                    guard token.original.first?.isUppercase == true,
                          token.normalized != "i",
                          !fillerWords.contains(token.normalized) else { continue }
                    let startsSentence = StreamingTranscriptPolicy.hasStrongBoundary(
                        after: tokens[index - 1].range.upperBound,
                        in: source
                    )
                    if !startsSentence { return true }
                }
            }
            // A whole sentence is never a false start: a run that begins at a
            // sentence start and ends at a strong boundary drops content.
            let startsSentence = first == 0
                || StreamingTranscriptPolicy.hasStrongBoundary(
                    after: tokens[first - 1].range.upperBound,
                    in: source
                )
            let endsSentence = StreamingTranscriptPolicy.hasStrongBoundary(
                after: tokens[last].range.upperBound,
                in: source
            )
            if contentWords > 0, startsSentence, endsSentence {
                return true
            }
            runStart = runEnd + 1
        }
        return false
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

    /// Every distinct numeral in the source must survive and the candidate may
    /// not introduce new ones. Counting occurrences instead would reject the
    /// removal of a stuttered "24 24 hours".
    private static func preservesNumericFacts(from source: String, in candidate: String) -> Bool {
        // New numerals (a numbered list the model wrote out) are judged by the
        // word-level projection, not here.
        Set(numericFacts(in: source)).isSubset(of: Set(numericFacts(in: candidate)))
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

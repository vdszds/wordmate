import Combine
import Foundation

/// The single source of truth for whether the post-processing model is
/// loaded. The launch warm-up drives it; the Welcome screen only observes it,
/// so reopening a window never starts a load of its own.
@MainActor
final class PostProcessingReadiness: ObservableObject {
    enum State: Equatable {
        case notPrepared
        case preparing(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notPrepared

    private let processor: TranscriptPostProcessor
    private let model: PostProcessingModel
    private var task: Task<Void, Never>?
    private var operationID: UUID?

    init(processor: TranscriptPostProcessor, model: PostProcessingModel) {
        self.processor = processor
        self.model = model
    }

    /// Loads the model unless it is already loaded. A call made while a load
    /// is running joins that load. `prerequisite`, when given, finishes first;
    /// the launch warm-up uses it to load Parakeet before Qwen instead of
    /// competing with it.
    @discardableResult
    func prepare(after prerequisite: Task<Void, Never>? = nil) async -> Bool {
        if state == .ready { return true }
        if let task {
            await task.value
            return state == .ready
        }

        let operationID = UUID()
        self.operationID = operationID
        state = .preparing(0)

        let processor = self.processor
        let model = self.model
        let task = Task { [weak self] in
            await prerequisite?.value
            do {
                try await processor.prepare(model) { update in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.operationID == operationID,
                              update.fractionCompleted < 1 else { return }
                        self.state = .preparing(update.fractionCompleted)
                    }
                }
                guard let self, self.operationID == operationID else { return }
                self.state = .ready
            } catch is CancellationError {
                guard let self, self.operationID == operationID else { return }
                self.state = .notPrepared
            } catch {
                guard let self, self.operationID == operationID else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.state = .failed(message)
            }
            guard let self, self.operationID == operationID else { return }
            self.task = nil
        }
        self.task = task
        await task.value
        return state == .ready
    }

    /// Releases the model, for example when the user turns cleanup off.
    func unload() {
        operationID = nil
        task?.cancel()
        task = nil
        state = .notPrepared
        let processor = self.processor
        Task {
            await processor.cancelPreparationAndUnload()
        }
    }
}

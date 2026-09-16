import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var postProcessingEnabled: Bool
    @Published private(set) var postProcessingIsPreparing = false
    @Published private(set) var postProcessingProgress = 0.0
    @Published private(set) var postProcessingError: String?

    private let preferences: AppPreferences
    private let readiness: PostProcessingReadiness
    private var readinessSubscription: AnyCancellable?

    init(
        preferences: AppPreferences,
        readiness: PostProcessingReadiness
    ) {
        self.preferences = preferences
        self.readiness = readiness
        postProcessingEnabled = preferences.postProcessingEnabled

        apply(readiness.state)
        readinessSubscription = readiness.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.apply(state)
            }
        if postProcessingEnabled {
            requestPreparation()
        }
    }

    /// Called whenever the window is shown again. The model stays loaded while
    /// the app runs in the background, so this only re-reads the current state.
    func refresh() {
        postProcessingEnabled = preferences.postProcessingEnabled
        if postProcessingEnabled {
            postProcessingError = nil
            requestPreparation()
        }
    }

    func setPostProcessingEnabled(_ enabled: Bool) {
        guard enabled != postProcessingEnabled else { return }

        postProcessingEnabled = enabled
        preferences.postProcessingEnabled = enabled
        postProcessingError = nil

        if enabled {
            requestPreparation()
        } else {
            readiness.unload()
        }
    }

    /// A no-op when the model is already loaded; otherwise joins the warm-up
    /// or starts the load the warm-up never ran.
    private func requestPreparation() {
        let readiness = self.readiness
        Task {
            await readiness.prepare()
        }
    }

    private func apply(_ state: PostProcessingReadiness.State) {
        switch state {
        case .notPrepared:
            postProcessingIsPreparing = false
            postProcessingProgress = 0
        case let .preparing(progress):
            postProcessingIsPreparing = true
            postProcessingProgress = progress
            postProcessingError = nil
        case .ready:
            postProcessingIsPreparing = false
            postProcessingProgress = 1
            postProcessingError = nil
        case .failed:
            postProcessingIsPreparing = false
            postProcessingProgress = 0
            if postProcessingEnabled {
                postProcessingEnabled = false
                preferences.postProcessingEnabled = false
                postProcessingError = "Post-processing couldn’t be prepared. Turn it on to try again."
            }
        }
    }
}

import Foundation

struct ModelPreparationUpdate: Equatable, Sendable {
    let fractionCompleted: Double
    let status: String

    init(fractionCompleted: Double, status: String) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.status = status
    }
}

typealias ModelProgressHandler = @Sendable (ModelPreparationUpdate) -> Void

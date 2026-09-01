import Foundation

enum PostProcessingModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case qwen3_0_6b = "qwen3-0.6b-4bit"

    var id: String { rawValue }

    var displayName: String { "Qwen3 0.6B" }

    var precision: String { "4-bit" }

    var downloadSize: String { "351 MB" }

    var menuDetail: String {
        "\(precision) · \(downloadSize)"
    }

    var isRecommended: Bool { true }

    var repositoryID: String { "mlx-community/Qwen3-0.6B-4bit" }
}

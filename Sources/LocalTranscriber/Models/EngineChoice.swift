import Foundation

enum EngineChoice: String, CaseIterable, Identifiable, Sendable {
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        "Parakeet TDT v3"
    }

    var detail: String {
        "Fast · 25 European languages · punctuation included"
    }
}

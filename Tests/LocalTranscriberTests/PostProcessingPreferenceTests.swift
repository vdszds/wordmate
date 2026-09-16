import XCTest
@testable import LocalTranscriber

@MainActor
final class PostProcessingPreferenceTests: XCTestCase {
    func testPostProcessingIsOptInAndPersists() {
        let suiteName = "PostProcessingPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.postProcessingEnabled)

        preferences.postProcessingEnabled = true

        let restoredPreferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(restoredPreferences.postProcessingEnabled)
    }

    func testEveryPostProcessingModelHasUniqueDownloadMetadata() {
        XCTAssertEqual(
            PostProcessingModel.allCases,
            [.qwen3_0_6b]
        )
        XCTAssertEqual(
            Set(PostProcessingModel.allCases.map(\.repositoryID)).count,
            PostProcessingModel.allCases.count
        )

        for model in PostProcessingModel.allCases {
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertFalse(model.precision.isEmpty)
            XCTAssertFalse(model.downloadSize.isEmpty)
            XCTAssertTrue(model.repositoryID.contains("/"))
        }
        XCTAssertTrue(PostProcessingModel.qwen3_0_6b.isRecommended)
    }

    func testDownloadedModelsLoadFromTheLocalDirectoryWithoutTheHub() {
        let configuration = TranscriptPostProcessor.loadingConfiguration(for: .qwen3_0_6b)
        if TranscriptPostProcessor.isModelDownloaded(.qwen3_0_6b) {
            guard case .directory = configuration.id else {
                return XCTFail("A downloaded model must load from its local directory")
            }
        } else {
            guard case .id = configuration.id else {
                return XCTFail("A missing model must be fetched from the Hub")
            }
        }
    }
}

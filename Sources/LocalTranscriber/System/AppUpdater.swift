import AppKit
import Combine
import Sparkle

/// Owns the Sparkle updater and turns its lifecycle into a published status
/// the menu bar and the Welcome screen can show. Sparkle's own windows still
/// handle the update prompt and installation; this class makes sure a click
/// on "Check for Updates…" always produces visible feedback, including when a
/// previous check left a prompt open somewhere off screen.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum Status: Equatable {
        case notConfigured
        case idle
        case checking
        case upToDate(Date)
        case updateAvailable(version: String)
        case installing(version: String)
        case failed(message: String, at: Date)
    }

    @Published private(set) var status: Status
    @Published private(set) var canCheck = false

    private var updaterController: SPUStandardUpdaterController!
    private var subscriptions: [AnyCancellable] = []
    private var hasStarted = false

    override init() {
        status = Self.isConfigured ? .idle : .notConfigured
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    /// "0.1.10 (12)" for the running app.
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return versionDescription(
            shortVersion: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String
        )
    }

    nonisolated static func versionDescription(shortVersion: String?, build: String?) -> String {
        switch (shortVersion, build) {
        case let (short?, build?) where !short.isEmpty && !build.isEmpty:
            return "\(short) (\(build))"
        case let (short?, _) where !short.isEmpty:
            return short
        case let (_, build?) where !build.isEmpty:
            return "build \(build)"
        default:
            return "unknown version"
        }
    }

    /// Starts Sparkle once, at launch, so the first click never races the
    /// updater's own start-up and gets dropped.
    func startIfConfigured() {
        guard Self.isConfigured, !hasStarted else { return }
        hasStarted = true
        updaterController.startUpdater()

        let updater = updaterController.updater
        canCheck = updater.canCheckForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheck = value
            }
            .store(in: &subscriptions)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard Self.isConfigured else {
            showConfigurationPlaceholder()
            return
        }
        startIfConfigured()
        NSApp.activate(ignoringOtherApps: true)

        let updater = updaterController.updater
        if updater.sessionInProgress {
            // A check is running or an update prompt is already open. Sparkle
            // ignores a second check, so bring the existing window forward
            // instead of letting the click vanish.
            if !surfaceUpdateWindows() {
                showSessionInProgressNotice()
            }
            return
        }

        status = .checking
        WordmateLog.dictation.info("Update check requested by the user")
        updaterController.checkForUpdates(sender)
    }

    // MARK: Presentation helpers

    nonisolated static func menuTitle(for status: Status) -> String {
        switch status {
        case .checking:
            return "Checking for Updates…"
        case let .updateAvailable(version):
            return "Update to \(version)…"
        case let .installing(version):
            return "Installing \(version)…"
        case .notConfigured, .idle, .upToDate, .failed:
            return "Check for Updates…"
        }
    }

    nonisolated static func menuItemIsEnabled(for status: Status) -> Bool {
        switch status {
        case .checking, .installing:
            return false
        case .notConfigured, .idle, .upToDate, .updateAvailable, .failed:
            return true
        }
    }

    nonisolated static func statusDescription(for status: Status, now: Date = Date()) -> String {
        switch status {
        case .notConfigured:
            return "Updates aren't configured for this build."
        case .idle:
            return "Updates haven't been checked yet."
        case .checking:
            return "Checking for updates…"
        case let .upToDate(date):
            return "Up to date · checked \(Self.relativeTime(date, now: now))"
        case let .updateAvailable(version):
            return "Version \(version) is available."
        case let .installing(version):
            return "Installing version \(version)…"
        case let .failed(message, date):
            return "Couldn't check \(Self.relativeTime(date, now: now)): \(message)"
        }
    }

    private nonisolated static func relativeTime(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        return "at \(date.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        WordmateLog.dictation.info("Update available: \(item.displayVersionString, privacy: .public)")
        status = .updateAvailable(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        WordmateLog.dictation.info("No update available")
        status = .upToDate(Date())
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) {
            status = .upToDate(Date())
            return
        }
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.installationCanceledError.rawValue) {
            return
        }
        WordmateLog.dictation.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        status = .failed(message: error.localizedDescription, at: Date())
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard status == .checking else { return }
        if let error {
            status = .failed(message: error.localizedDescription, at: Date())
        } else {
            status = .upToDate(Date())
        }
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .install:
            status = .installing(version: updateItem.displayVersionString)
        case .skip, .dismiss:
            status = .updateAvailable(version: updateItem.displayVersionString)
        @unknown default:
            break
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        status = .installing(version: item.displayVersionString)
    }

    // MARK: Windows and notices

    /// Brings Sparkle's own windows (update prompt, progress) to the front.
    /// Returns false when none is visible.
    private func surfaceUpdateWindows() -> Bool {
        let sparkleBundle = Bundle(for: SPUUpdater.self)
        let windows = NSApp.windows.filter { window in
            guard window.isVisible else { return false }
            if let controller = window.windowController,
               Bundle(for: type(of: controller)) == sparkleBundle {
                return true
            }
            if let contentController = window.contentViewController,
               Bundle(for: type(of: contentController)) == sparkleBundle {
                return true
            }
            return false
        }
        for window in windows {
            window.makeKeyAndOrderFront(nil)
        }
        return !windows.isEmpty
    }

    private func showSessionInProgressNotice() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "An update check is already in progress"
        alert.informativeText = Self.statusDescription(for: status)
            + " Wait a moment and try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return isConfigurationValid(
            feedString: info["SUFeedURL"] as? String,
            publicKey: info["SUPublicEDKey"] as? String,
            requiresSignedFeed: info["SURequireSignedFeed"] as? Bool ?? false,
            verifiesUpdateBeforeExtraction: info["SUVerifyUpdateBeforeExtraction"] as? Bool ?? false
        )
    }

    /// Sparkle refuses to start when a signed feed is required without also
    /// verifying updates before extraction. Treat that pairing as part of the
    /// configuration so the app shows its own message instead of Sparkle's
    /// generic "The updater failed to start" alert.
    nonisolated static func isConfigurationValid(
        feedString: String?,
        publicKey: String?,
        requiresSignedFeed: Bool = true,
        verifiesUpdateBeforeExtraction: Bool = true
    ) -> Bool {
        guard !requiresSignedFeed || verifiesUpdateBeforeExtraction else {
            return false
        }
        guard let feedString,
              let feedURL = URL(string: feedString),
              feedURL.scheme == "https",
              let host = feedURL.host,
              !host.isEmpty,
              !host.hasSuffix(".invalid"),
              feedURL.user == nil,
              feedURL.password == nil,
              let publicKey,
              !publicKey.hasPrefix("REPLACE_"),
              let decodedKey = Data(base64Encoded: publicKey),
              decodedKey.count == 32 else {
            return false
        }
        return true
    }

    private func showConfigurationPlaceholder() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Updates aren’t configured yet"
        alert.informativeText = "This build has no update feed. Download new versions from wordmate.sh."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

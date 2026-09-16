import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    private enum PermissionKind {
        case microphone
        case accessibility
    }

    var body: some View {
        VStack(spacing: 0) {
            setupHeader

            ZStack {
                activePage
                    .id(viewModel.step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(width: 660, height: 540)
        .background(WordmateTheme.canvas)
        .tint(WordmateTheme.primaryAction)
        .animation(
            .easeInOut(duration: 0.3),
            value: viewModel.step
        )
    }

    private var pageTransition: AnyTransition {
        let insertionEdge: Edge = viewModel.navigationDirection == .forward
            ? .trailing
            : .leading

        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.985))
        )
    }

    @ViewBuilder
    private var activePage: some View {
        switch viewModel.step {
        case .output:
            outputPage
        case .download:
            downloadPage
        case .microphone:
            permissionPage(
                kind: .microphone,
                symbol: "mic.fill",
                title: "Enable microphone",
                message: "Your voice is recorded and transcribed entirely on this Mac. Audio is never uploaded.",
                granted: viewModel.microphoneGranted,
                buttonTitle: SystemPermissions.microphone == .denied
                    ? "Open Microphone Settings"
                    : "Enable Microphone",
                request: viewModel.requestMicrophone
            )
        case .accessibility:
            permissionPage(
                kind: .accessibility,
                symbol: "keyboard.badge.ellipsis",
                title: "Enable Accessibility",
                message: "This lets Wordmate detect Fn gestures from any app and paste the finished transcript into the focused field.",
                granted: viewModel.accessibilityGranted,
                buttonTitle: viewModel.accessibilityButtonTitle,
                request: viewModel.requestAccessibility
            )
        case .ready:
            readyPage
        }
    }

    private var setupHeader: some View {
        stepIndicator
            .padding(.top, 17)
            .frame(height: 44, alignment: .top)
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingViewModel.Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(stepColor(step))
                    .frame(width: step == viewModel.step ? 24 : 7, height: 7)
            }
        }
        .animation(
            .easeInOut(duration: 0.24),
            value: viewModel.step
        )
        .accessibilityLabel(
            "Setup step \(viewModel.step.rawValue + 1) of \(OnboardingViewModel.Step.allCases.count)"
        )
    }

    private func stepColor(_ step: OnboardingViewModel.Step) -> Color {
        if step == viewModel.step {
            return WordmateTheme.primaryAction
        }
        if step.rawValue < viewModel.step.rawValue {
            return WordmateTheme.primaryAction.opacity(0.38)
        }
        return WordmateTheme.inactive
    }

    private func pageHero<Icon: View>(
        title: String,
        subtitle: String?,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(spacing: 0) {
            icon()
                .frame(width: 72, height: 72)

            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.35)
                .padding(.top, 16)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 455)
                    .frame(height: 40, alignment: .top)
                    .padding(.top, 7)
            }
        }
        .padding(.top, 10)
    }

    private func centeredPageContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var outputPage: some View {
        VStack(spacing: 0) {
            pageHero(
                title: "Choose your output",
                subtitle: "What should Wordmate paste after you finish speaking?"
            ) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 5)
            }

            centeredPageContent {
                VStack(spacing: 10) {
                    outputOption(
                        postProcessingEnabled: false,
                        symbol: "waveform",
                        title: "Raw transcription",
                        detail: "Paste the transcript as it was recognized."
                    )
                    outputOption(
                        postProcessingEnabled: true,
                        symbol: "wand.and.sparkles",
                        title: "Cleaner transcription",
                        detail: "Improve punctuation and remove filler words and repetitions."
                    )
                }
                .frame(maxWidth: 500)
            }

            bottomActions(
                primaryTitle: "Continue",
                primaryAction: viewModel.next,
                showsBack: false
            )
        }
        .padding(.horizontal, 54)
    }

    private func outputOption(
        postProcessingEnabled: Bool,
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        let isSelected = viewModel.postProcessingEnabled == postProcessingEnabled

        return Button {
            viewModel.setPostProcessingEnabled(postProcessingEnabled)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? WordmateTheme.primaryAction : .secondary)
                    .frame(width: 42, height: 42)
                    .background(
                        isSelected
                            ? WordmateTheme.primaryAction.opacity(0.12)
                            : WordmateTheme.control,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(
                        isSelected ? WordmateTheme.primaryAction : WordmateTheme.inactive
                    )
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(
                isSelected
                    ? WordmateTheme.primaryAction.opacity(0.08)
                    : WordmateTheme.surface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected
                            ? WordmateTheme.primaryAction.opacity(0.62)
                            : WordmateTheme.controlBorder,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var downloadPage: some View {
        VStack(spacing: 0) {
            pageHero(
                title: viewModel.canContinueFromDownload
                    ? "Downloads complete"
                    : "Getting Wordmate ready",
                subtitle: viewModel.canContinueFromDownload
                    ? nil
                    : "Speech recognition and text cleanup are installed together for fully offline use."
            ) {
                Image(systemName: viewModel.canContinueFromDownload ? "checkmark" : "arrow.down")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(
                        viewModel.canContinueFromDownload
                            ? WordmateTheme.success
                            : WordmateTheme.primaryAction
                    )
                    .frame(width: 72, height: 72)
                    .background(
                        viewModel.canContinueFromDownload
                            ? WordmateTheme.successFill
                            : WordmateTheme.primaryAction.opacity(0.1),
                        in: Circle()
                    )
            }

            centeredPageContent {
                VStack(spacing: 4) {
                    VStack(spacing: 10) {
                        downloadItem(
                            symbol: "waveform",
                            title: "Speech recognition",
                            status: viewModel.transcriptionStatus,
                            progress: viewModel.transcriptionProgress
                        )
                        downloadItem(
                            symbol: "wand.and.sparkles",
                            title: "Text cleanup",
                            status: viewModel.postProcessingStatus,
                            progress: viewModel.postProcessingProgress
                        )
                    }
                    .frame(maxWidth: 460)

                    ZStack {
                        if let error = viewModel.downloadError {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 460)
                        } else if viewModel.downloadState == .downloading {
                            Text("\(Int(viewModel.combinedDownloadProgress * 100))% complete")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                    .frame(height: 34)
                }
            }

            downloadActions
        }
        .padding(.horizontal, 54)
    }

    @ViewBuilder
    private var downloadActions: some View {
        switch viewModel.downloadState {
        case .ready:
            bottomActions(
                primaryTitle: "Continue",
                primaryAction: viewModel.next
            )
        case .failed:
            bottomActions(
                primaryTitle: "Try Again",
                primaryAction: viewModel.retryDownloads
            )
        case .idle, .downloading:
            bottomActions(
                primaryTitle: "Downloading…",
                primaryAction: {},
                showsProgress: true,
                disabled: true,
                showsBack: false
            )
        }
    }

    private func downloadItem(
        symbol: String,
        title: String,
        status: String,
        progress: Double
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: progress >= 1 ? "checkmark" : symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    progress >= 1 ? WordmateTheme.success : WordmateTheme.primaryAction
                )
                .frame(width: 36, height: 36)
                .background(
                    progress >= 1
                        ? WordmateTheme.successFill
                        : WordmateTheme.primaryAction.opacity(0.1),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text(status)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressView(value: progress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(
                        progress >= 1
                            ? WordmateTheme.success
                            : WordmateTheme.primaryAction
                    )
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 65)
        .wordmateSurface(cornerRadius: 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(status), \(Int(progress * 100)) percent")
    }

    private func permissionPage(
        kind: PermissionKind,
        symbol: String,
        title: String,
        message: String,
        granted: Bool,
        buttonTitle: String,
        request: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            pageHero(title: title, subtitle: message) {
                permissionGlyph(symbol: symbol, granted: granted)
            }

            centeredPageContent {
                switch kind {
                case .microphone:
                    microphoneTestPanel(granted: granted)
                case .accessibility:
                    accessibilityPanel
                }
            }

            bottomActions(
                primaryTitle: granted ? "Continue" : buttonTitle,
                primaryAction: granted ? viewModel.next : request
            )
        }
        .padding(.horizontal, 54)
    }

    private func permissionGlyph(symbol: String, granted: Bool) -> some View {
        Image(systemName: granted ? "checkmark" : symbol)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(
                granted ? WordmateTheme.success : WordmateTheme.primaryAction
            )
            .frame(width: 72, height: 72)
            .background(
                granted
                    ? WordmateTheme.successFill
                    : WordmateTheme.primaryAction.opacity(0.1),
                in: Circle()
            )
    }

    private func microphoneTestPanel(granted: Bool) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Microphone test")
                    .font(.system(size: 11.5, weight: .semibold))

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(granted ? WordmateTheme.success : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(granted ? "Live" : "Waiting for permission")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                LiveAudioWaveform(
                    level: viewModel.microphoneLevel,
                    orientation: .horizontal,
                    color: WordmateTheme.primaryAction.opacity(0.9),
                    barThickness: 3.5,
                    spacing: 5,
                    minimumExtent: 5
                )
                    .frame(width: 280, height: 42)
                    .opacity(granted ? 1 : 0)
            }
            .frame(height: 46)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(width: 390, height: 96)
        .wordmateSurface(cornerRadius: 14)
        .animation(.easeInOut(duration: 0.18), value: granted)
    }

    private var accessibilityPanel: some View {
        VStack(spacing: 9) {
            fnGestureGuide

            ZStack(alignment: .top) {
                if viewModel.showAccessibilityTroubleshooting {
                    VStack(spacing: 6) {
                        Text("macOS still reports this permission as disabled. Remove the old Wordmate entry, add this app again, then check once more.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)

                        Button("Open Accessibility Settings") {
                            viewModel.openAccessibilitySettings()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5, weight: .semibold))
                    }
                }
            }
            .frame(height: 55, alignment: .top)
        }
    }

    private var fnGestureGuide: some View {
        HStack(spacing: 10) {
            gestureCard(
                keycaps: 1,
                title: "Hold Fn",
                detail: "Release to paste"
            )
            gestureCard(
                keycaps: 2,
                title: "Double-tap Fn",
                detail: "Continuous recording"
            )
        }
        .frame(maxWidth: 460)
    }

    private func gestureCard(
        keycaps: Int,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(0..<keycaps, id: \.self) { _ in
                    FnKeycap()
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .wordmateSurface(cornerRadius: 13)
    }

    private var readyPage: some View {
        VStack(spacing: 0) {
            pageHero(
                title: "You’re ready",
                subtitle: "Hold Fn for push-to-talk, or double-tap for continuous recording."
            ) {
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(WordmateTheme.success)
                    .frame(width: 72, height: 72)
                    .background(WordmateTheme.successFill, in: Circle())
            }

            Spacer()

            bottomActions(
                primaryTitle: "Start Using Wordmate",
                primaryAction: viewModel.next
            )
        }
        .padding(.horizontal, 54)
    }

    private func bottomActions(
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        showsProgress: Bool = false,
        disabled: Bool = false,
        showsBack: Bool = true
    ) -> some View {
        VStack(spacing: 13) {
            primaryButton(
                primaryTitle,
                showsProgress: showsProgress,
                disabled: disabled,
                action: primaryAction
            )

            if showsBack {
                Button(action: viewModel.back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                        Text("Back")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            } else {
                Color.clear
                    .frame(height: 14)
            }
        }
        .padding(.bottom, 23)
    }

    private func primaryButton(
        _ title: String,
        showsProgress: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
            }
            .frame(width: 286, height: 38)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 11))
        .controlSize(.large)
        .tint(WordmateTheme.primaryAction)
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }
}

private struct FnKeycap: View {
    var body: some View {
        Text("fn")
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(width: 33, height: 28)
            .background(
                LinearGradient(
                    colors: [
                        WordmateTheme.surface,
                        WordmateTheme.control,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(WordmateTheme.controlBorder, lineWidth: 0.75)
            }
            .shadow(color: WordmateTheme.shadow.opacity(0.16), radius: 2, y: 1)
            .accessibilityLabel("Fn key")
    }
}

import AppKit
import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var statistics: UsageStatistics
    @ObservedObject var updater: AppUpdater
    @ObservedObject var fileTranscription: FileTranscriptionViewModel

    @State private var isShowingFileTranscription = false

    var body: some View {
        ZStack {
            if isShowingFileTranscription {
                FileTranscriptionView(viewModel: fileTranscription) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isShowingFileTranscription = false
                    }
                }
                .transition(.opacity)
            } else {
                welcome
                    .transition(.opacity)
            }
        }
        .frame(width: 600, height: 460)
        .background(WordmateTheme.canvas)
        .tint(WordmateTheme.primaryAction)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            postProcessingGroup
                .padding(.top, 20)

            fileTranscriptionRow
                .padding(.top, 12)

            activityGroup
                .padding(.top, 12)

            Spacer(minLength: 16)

            updateSummary
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTranscriptionRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isShowingFileTranscription = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WordmateTheme.primaryAction)
                    .frame(width: 38, height: 38)
                    .background(
                        WordmateTheme.primaryAction.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcribe audio")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(fileTranscriptionStatus)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 15)
            .frame(height: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .wordmateSurface(cornerRadius: 14)
    }

    private var fileTranscriptionStatus: String {
        switch fileTranscription.phase {
        case let .running(stage, progress):
            return "\(stage.title) \(Int(progress * 100))%"
        case .finished:
            return "Your transcript is ready."
        case .failed:
            return "The last file couldn’t be transcribed."
        case .empty, .ready:
            return "Turn an audio or video file into text, right here on your Mac."
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 7, y: 3)

            Text("Welcome")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.45)
        }
    }

    private var updateSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Version \(AppUpdater.versionDescription)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
            Text(AppUpdater.statusDescription(for: updater.status))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 4)
            Button(AppUpdater.menuTitle(for: updater.status)) {
                updater.checkForUpdates(nil)
            }
            .controlSize(.small)
            .disabled(!AppUpdater.menuItemIsEnabled(for: updater.status))
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var postProcessingGroup: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WordmateTheme.primaryAction)
                    .frame(width: 38, height: 38)
                    .background(
                        WordmateTheme.primaryAction.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Post-processing")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("Clean up punctuation, filler words, and repetitions before pasting.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle("Enable post-processing", isOn: postProcessingBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(WordmateTheme.primaryAction)
            }
            .padding(.horizontal, 15)
            .frame(height: 70)

            if viewModel.postProcessingIsPreparing || viewModel.postProcessingError != nil {
                postProcessingStatus
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        WordmateTheme.control,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .padding(.horizontal, 5)
                    .padding(.bottom, 5)
            }
        }
        .wordmateSurface(cornerRadius: 14)
        .animation(.easeInOut(duration: 0.18), value: viewModel.postProcessingIsPreparing)
        .animation(.easeInOut(duration: 0.18), value: viewModel.postProcessingError)
    }

    private var postProcessingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.postProcessingEnabled },
            set: { viewModel.setPostProcessingEnabled($0) }
        )
    }

    @ViewBuilder
    private var postProcessingStatus: some View {
        if viewModel.postProcessingIsPreparing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing post-processing…")
                    .lineLimit(1)
                Spacer()
                Text("\(Int(viewModel.postProcessingProgress * 100))%")
                    .monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        } else if let error = viewModel.postProcessingError {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activityGroup: some View {
        HStack(spacing: 10) {
            metric(
                value: statistics.totalWords.formatted(),
                label: "Words transcribed",
                symbol: "text.word.spacing"
            )

            metric(
                value: statistics.formattedRecordingDuration,
                label: "Recording time",
                symbol: "waveform"
            )
        }
        .frame(height: 82)
    }

    private func metric(value: String, label: String, symbol: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 25, weight: .semibold))
                .tracking(-0.35)
                .monospacedDigit()
                .contentTransition(.numericText())

            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(WordmateTheme.primaryAction)
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 82)
        .wordmateSurface(cornerRadius: 12)
    }
}

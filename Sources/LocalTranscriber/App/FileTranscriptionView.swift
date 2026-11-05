import AppKit
import SwiftUI

struct FileTranscriptionView: View {
    @ObservedObject var viewModel: FileTranscriptionViewModel
    let onBack: () -> Void

    @State private var isDropTargeted = false
    @State private var isChoosingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            fileArea
                .padding(.top, 14)

            actionBar
                .frame(height: 38)
                .padding(.top, 12)

            outputPanel
                .padding(.top, 12)
        }
        .padding(.horizontal, 32)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WordmateTheme.canvas)
        .contentShape(Rectangle())
        // The whole screen takes the drop, so a file only has to land on the
        // window, not on the drop zone itself.
        .dropDestination(for: URL.self) { urls, _ in
            guard !viewModel.isRunning,
                  let url = urls.first(where: \.isFileURL) else { return false }
            viewModel.select(url)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted && !viewModel.isRunning
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: AudioFileDecoder.pickerContentTypes
        ) { result in
            if case let .success(url) = result {
                viewModel.select(url)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.file)
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        WordmateTheme.control,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel("Back")

            Text("Transcribe audio")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.3)
        }
    }

    @ViewBuilder
    private var fileArea: some View {
        if let file = viewModel.file {
            fileCard(file)
        } else {
            dropZone
        }
    }

    private var dropZone: some View {
        Button {
            isChoosingFile = true
        } label: {
            VStack(spacing: 4) {
                if viewModel.isInspectingFile {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 24)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(WordmateTheme.primaryAction)
                        .frame(height: 24)
                }

                Text("Drop an audio or video file here")
                    .font(.system(size: 13, weight: .semibold))

                dropZoneCaption
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isInspectingFile)
        .background(
            isDropTargeted ? WordmateTheme.primaryAction.opacity(0.1) : WordmateTheme.surface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? WordmateTheme.primaryAction : WordmateTheme.controlBorder,
                    style: StrokeStyle(lineWidth: 1.25, dash: [5, 4])
                )
        }
    }

    @ViewBuilder
    private var dropZoneCaption: some View {
        if let error = viewModel.selectionError {
            selectionErrorText(error)
        } else {
            Text("or click to choose. MP3, M4A, WAV, FLAC, OGG, OPUS, MP4, MOV, and more.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private func selectionErrorText(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    private func fileCard(_ file: AudioFileSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.hasVideo ? "film" : "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WordmateTheme.primaryAction)
                .frame(width: 38, height: 38)
                .background(
                    WordmateTheme.primaryAction.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let error = viewModel.selectionError {
                    selectionErrorText(error)
                } else {
                    Text(Self.details(of: file))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button("Change…") {
                isChoosingFile = true
            }
            .controlSize(.small)
            .disabled(viewModel.isRunning || viewModel.isInspectingFile)
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(
            isDropTargeted ? WordmateTheme.primaryAction.opacity(0.1) : WordmateTheme.surface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? WordmateTheme.primaryAction : WordmateTheme.controlBorder,
                    style: isDropTargeted
                        ? StrokeStyle(lineWidth: 1.25, dash: [5, 4])
                        : StrokeStyle(lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        switch viewModel.phase {
        case .empty, .ready:
            HStack {
                Spacer()
                transcribeButton(title: "Transcribe")
                Spacer()
            }
        case let .running(stage, progress):
            progressBar(stage: stage, progress: progress)
        case .finished:
            finishedBar
        case .failed:
            HStack(spacing: 10) {
                Spacer()
                Button("Start over", action: viewModel.startOver)
                    .controlSize(.large)
                transcribeButton(title: "Try again")
                Spacer()
            }
        }
    }

    private func transcribeButton(title: String) -> some View {
        Button(action: viewModel.run) {
            Label(title, systemImage: "play.fill")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!viewModel.canRun)
        .keyboardShortcut(.defaultAction)
    }

    private func progressBar(
        stage: FileTranscriptionViewModel.Stage,
        progress: Double
    ) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 5) {
                HStack {
                    Text(stage.title)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(WordmateTheme.primaryAction)
            }

            if stage == .polishing {
                Button("Skip cleanup", action: viewModel.skipCleanup)
                    .help("Keep the text as it is now and stop cleaning it up.")
            } else {
                Button("Cancel", action: viewModel.cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var finishedBar: some View {
        HStack(spacing: 10) {
            Text(finishedSummary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button("Start over", action: viewModel.startOver)
                .controlSize(.large)

            Button(action: viewModel.copyTranscript) {
                Label(
                    viewModel.didCopyTranscript ? "Copied" : "Copy text",
                    systemImage: viewModel.didCopyTranscript ? "checkmark" : "doc.on.doc"
                )
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var finishedSummary: String {
        let count = viewModel.wordCount
        return "\(count.formatted()) \(count == 1 ? "word" : "words")"
    }

    private var outputPanel: some View {
        Group {
            if case let .failed(message) = viewModel.phase {
                placeholder(message, symbol: "exclamationmark.circle.fill")
            } else if viewModel.transcript.isEmpty {
                placeholder(
                    viewModel.isRunning
                        ? "Your transcript will appear here when it’s ready."
                        : "Your transcript will appear here.",
                    symbol: "text.alignleft"
                )
            } else {
                TranscriptTextView(
                    text: viewModel.transcript,
                    isDraft: viewModel.isRunning
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .wordmateSurface(cornerRadius: 12)
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    private static func details(of file: AudioFileSummary) -> String {
        var parts = [formattedDuration(file.duration)]
        if !file.format.isEmpty {
            parts.append(file.format)
        }
        if file.byteCount > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(1, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

/// AppKit's text view stays responsive with the hundreds of thousands of
/// characters a long recording produces, where a selectable SwiftUI `Text` does
/// not.
private struct TranscriptTextView: NSViewRepresentable {
    let text: String
    let isDraft: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 10, height: 12)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 3
            textView.defaultParagraphStyle = paragraphStyle
            textView.typingAttributes = [
                .font: NSFont.systemFont(ofSize: 13),
                .paragraphStyle: paragraphStyle,
            ]
            textView.font = .systemFont(ofSize: 13)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.scrollToBeginningOfDocument(nil)
        }
        textView.textColor = isDraft ? .secondaryLabelColor : .labelColor
    }
}

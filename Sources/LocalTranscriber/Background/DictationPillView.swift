import SwiftUI

struct DictationPillView: View {
    static let contentSize = CGSize(width: 42, height: 178)

    private static let renderInset: CGFloat = 8
    static let compactWidthScale: CGFloat = 0.9
    static let compactHeightScale: CGFloat = 0.64
    static let idleProtrusion: CGFloat = 5
    static let idleWidthScale = idleProtrusion / contentSize.width
    static let idleHeightScale = compactHeightScale / 2
    static let idleCornerScale: CGFloat = 0.24

    static let windowSize = CGSize(
        width: contentSize.width + renderInset,
        height: contentSize.height + (renderInset * 2)
    )

    @ObservedObject var controller: DictationController
    @State private var surfaceProgress: CGFloat = 1
    @State private var notchWidthScale: CGFloat = Self.idleWidthScale
    @State private var notchHeightScale: CGFloat = Self.idleHeightScale
    @State private var contentProgress: CGFloat = 0
    @State private var displayedPhase: DictationController.Phase = .idle
    @State private var animationToken = UUID()
    @State private var reconcileTask: Task<Void, Never>?

    private var hasActiveNotchContent: Bool {
        Self.hasActiveNotchContent(controller.phase)
    }

    static func hasActiveNotchContent(
        _ phase: DictationController.Phase
    ) -> Bool {
        switch phase {
        case .recording(.pushToTalk),
             .recording(.continuous),
             .processing,
             .failure:
            true

        case .idle,
             .recording(.gesturePending),
             .success:
            false
        }
    }

    static func heightScale(for phase: DictationController.Phase) -> CGFloat {
        switch phase {
        case .recording(.continuous), .processing(.continuous):
            1

        case .recording(.pushToTalk), .processing(.pushToTalk), .failure:
            compactHeightScale

        case .idle,
             .recording(.gesturePending),
             .processing(.gesturePending),
             .success:
            idleHeightScale
        }
    }

    static func widthScale(for phase: DictationController.Phase) -> CGFloat {
        switch phase {
        case .recording(.continuous), .processing(.continuous):
            1

        case .recording(.pushToTalk), .processing(.pushToTalk), .failure:
            compactWidthScale

        case .idle,
             .recording(.gesturePending),
             .processing(.gesturePending),
             .success:
            idleWidthScale
        }
    }

    static func cornerScale(forWidthScale widthScale: CGFloat) -> CGFloat {
        let expansion = max(
            0,
            min(
                1,
                (widthScale - idleWidthScale)
                    / (compactWidthScale - idleWidthScale)
            )
        )
        let easedExpansion = expansion
            * expansion
            * (3 - (2 * expansion))
        return idleCornerScale
            + ((1 - idleCornerScale) * easedExpansion)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            SideNotchSurface(
                progress: surfaceProgress,
                widthScale: notchWidthScale,
                heightScale: notchHeightScale
            ) {
                notchContent(for: displayedPhase)
                    .opacity(contentProgress)
                    .scaleEffect(
                        0.88 + (0.12 * contentProgress),
                        anchor: .trailing
                    )
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .padding(.leading, Self.renderInset)
        .padding(.vertical, Self.renderInset)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .allowsHitTesting(hasActiveNotchContent)
        .onAppear {
            displayedPhase = controller.phase
            notchWidthScale = Self.widthScale(for: controller.phase)
            notchHeightScale = Self.heightScale(for: controller.phase)
            surfaceProgress = 1
            contentProgress = hasActiveNotchContent ? 1 : 0
        }
        .onChange(of: controller.phase) { oldPhase, newPhase in
            updateAnimation(from: oldPhase, to: newPhase)
            scheduleReconcile()
        }
    }

    /// Every choreography below is a sequence of delayed steps that a newer
    /// phase change can cancel. Whatever happens in between, the view must
    /// end up showing the current phase; otherwise a start that fails within
    /// the reveal window leaves an expanded, empty notch behind.
    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            reconcile()
        }
    }

    private func reconcile() {
        let phase = controller.phase
        let showsContent = Self.hasActiveNotchContent(phase)
        withAnimation(.easeOut(duration: 0.12)) {
            displayedPhase = phase
            notchWidthScale = Self.widthScale(for: phase)
            notchHeightScale = Self.heightScale(for: phase)
            surfaceProgress = 1
            contentProgress = showsContent ? 1 : 0
        }
    }

    @ViewBuilder
    private func notchContent(for phase: DictationController.Phase) -> some View {
        switch phase {
        case .recording(.continuous):
            continuousRecordingContent
                .transition(.opacity.combined(with: .scale(scale: 0.9)))

        case .recording(.pushToTalk):
            LiveAudioWaveform(
                level: controller.audioLevel,
                orientation: .vertical,
                color: .white.opacity(0.92),
                barThickness: 2.3,
                spacing: 3.35,
                isWarmingUp: !controller.isMicrophoneLive
            )
            .frame(width: 34, height: 98)
            .offset(x: 3)
            .transition(.opacity)

        case .processing:
            NotchProcessingIndicator()
                .frame(width: 30, height: 40)
                .offset(x: 3)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))

        case let .failure(message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 30, height: 40)
                .offset(x: 3)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .accessibilityLabel("Dictation failed")
                .accessibilityValue(message)

        case .idle,
             .recording(.gesturePending),
             .success:
            Color.clear
        }
    }

    private func updateAnimation(
        from oldPhase: DictationController.Phase,
        to newPhase: DictationController.Phase
    ) {
        let wasVisible = Self.hasActiveNotchContent(oldPhase)
        let isVisible = Self.hasActiveNotchContent(newPhase)

        switch (wasVisible, isVisible) {
        case (false, true):
            animateAppearance(showing: newPhase)

        case (true, true):
            animationToken = UUID()
            withAnimation(
                .interpolatingSpring(
                    mass: 0.7,
                    stiffness: 210,
                    damping: 20,
                    initialVelocity: 0.2
                )
            ) {
                displayedPhase = newPhase
                notchWidthScale = Self.widthScale(for: newPhase)
                notchHeightScale = Self.heightScale(for: newPhase)
                surfaceProgress = 1
                contentProgress = 1
            }

        case (true, false):
            animateDisappearance(endingAt: newPhase)

        case (false, false):
            animationToken = UUID()
            displayedPhase = newPhase
            contentProgress = 0
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                surfaceProgress = 1
                notchWidthScale = Self.widthScale(for: newPhase)
                notchHeightScale = Self.heightScale(for: newPhase)
            }
        }
    }

    private func animateAppearance(showing phase: DictationController.Phase) {
        let token = UUID()
        animationToken = token
        displayedPhase = phase
        contentProgress = 0

        withAnimation(
            .interpolatingSpring(
                mass: 0.72,
                stiffness: 190,
                damping: 18,
                initialVelocity: 0.55
            )
        ) {
            surfaceProgress = 1.018
            notchWidthScale = Self.widthScale(for: phase)
            notchHeightScale = Self.heightScale(for: phase)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(68))
            guard animationToken == token else { return }

            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                contentProgress = 1
            }

            try? await Task.sleep(for: .milliseconds(110))
            guard animationToken == token else { return }

            withAnimation(.easeOut(duration: 0.12)) {
                surfaceProgress = 1
            }
        }
    }

    private func animateDisappearance(endingAt phase: DictationController.Phase) {
        let token = UUID()
        animationToken = token

        withAnimation(.easeOut(duration: 0.09)) {
            contentProgress = 0
        }

        // A restrained gather gives the surface a liquid sense of mass before
        // the screen edge pulls it into its persistent resting tab.
        withAnimation(.spring(response: 0.15, dampingFraction: 0.78)) {
            surfaceProgress = 1.018
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(52))
            guard animationToken == token else { return }

            withAnimation(
                .interpolatingSpring(
                    mass: 0.68,
                    stiffness: 260,
                    damping: 25,
                    initialVelocity: 0
                )
            ) {
                surfaceProgress = 1
                notchWidthScale = Self.widthScale(for: phase)
                notchHeightScale = Self.heightScale(for: phase)
            }

            try? await Task.sleep(for: .milliseconds(330))
            guard animationToken == token else { return }
            displayedPhase = phase
        }
    }

    private var continuousRecordingContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 5) {
                actionButton(
                    systemName: "checkmark",
                    foreground: .black,
                    background: .white,
                    accessibilityLabel: "Accept transcription"
                ) {
                    Task { await controller.accept() }
                }
                .disabled(!controller.isMicrophoneLive)

                actionButton(
                    systemName: "xmark",
                    foreground: .white,
                    background: .white.opacity(0.14),
                    accessibilityLabel: "Discard recording"
                ) {
                    controller.reject()
                }
            }
            .frame(height: 56)
            .offset(x: 3)
            // Until the microphone is live there is nothing to accept; the
            // buttons fade with the bars so the state reads as "not yet".
            .opacity(controller.isMicrophoneLive ? 1 : 0.24)
            .animation(.easeOut(duration: 0.42), value: controller.isMicrophoneLive)

            LiveAudioWaveform(
                level: controller.audioLevel,
                orientation: .vertical,
                color: .white.opacity(0.92),
                isWarmingUp: !controller.isMicrophoneLive
            )
            .frame(width: 34, height: 93.5)
            .offset(x: 3)
        }
        .padding(.top, 14)
        .padding(.bottom, 14.5)
        .accessibilityElement(children: .contain)
    }

    private func actionButton(
        systemName: String,
        foreground: Color,
        background: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(background)

                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(foreground)
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct NotchProcessingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var accessibilityLabel = "Transcribing"

    private let barCount = 7
    private let cycleDuration = 1.05

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: reduceMotion
            )
        ) { timeline in
            VStack(spacing: 3.2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let intensity = pulseIntensity(
                        at: index,
                        date: timeline.date
                    )

                    Capsule(style: .continuous)
                        .fill(Color.white)
                        .frame(
                            width: 5.5 + CGFloat(20 * intensity),
                            height: 2.2
                        )
                        .opacity(0.26 + (0.74 * intensity))
                        .shadow(
                            color: .white.opacity(0.22 * intensity),
                            radius: CGFloat(3 * intensity)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func pulseIntensity(at index: Int, date: Date) -> Double {
        if reduceMotion {
            let distance = abs(Double(index) - Double(barCount - 1) / 2)
            return exp(-0.5 * pow(distance / 1.05, 2))
        }

        let cycle = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration)
            / cycleDuration
        let position = (cycle * Double(barCount + 2)) - 1
        let distance = abs(Double(index) - position)
        return exp(-0.5 * pow(distance / 0.82, 2))
    }
}

private struct SideNotchSurface<Content: View>: View {
    let progress: CGFloat
    let widthScale: CGFloat
    let heightScale: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            SideNotchShape(
                progress: progress,
                widthScale: widthScale,
                heightScale: heightScale
            )
                .fill(Color.black)

            content
                .mask(
                    SideNotchShape(
                        progress: progress,
                        widthScale: widthScale,
                        heightScale: heightScale
                    )
                )
        }
        .frame(
            width: DictationPillView.contentSize.width,
            height: DictationPillView.contentSize.height
        )
    }
}

private struct SideNotchShape: Shape {
    var progress: CGFloat
    var widthScale: CGFloat
    var heightScale: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                progress,
                AnimatablePair(widthScale, heightScale)
            )
        }
        set {
            progress = newValue.first
            widthScale = newValue.second.first
            heightScale = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let liquidProgress = max(0, min(1.12, progress))
        guard liquidProgress > 0.001 else { return Path() }

        let settledProgress = min(1, liquidProgress)
        let heightProgress = pow(settledProgress, 0.72)
        let overshoot = max(0, liquidProgress - 1)
        let revealHeightScale = 0.04
            + (0.96 * heightProgress)
            + (0.16 * overshoot)
        let modeWidthScale = max(0.08, min(1.08, widthScale))
        let modeHeightScale = max(0.2, min(1.08, heightScale))
        let animatedWidth = rect.width * liquidProgress * modeWidthScale
        let animatedHeight = rect.height * modeHeightScale * revealHeightScale
        let notchRect = CGRect(
            x: rect.maxX - animatedWidth,
            y: rect.midY - (animatedHeight / 2),
            width: animatedWidth,
            height: animatedHeight
        )

        // Flatten the resting tab, then smoothly restore the fuller notch
        // curvature as the surface expands into an active recording state.
        let taperProgress = min(1, liquidProgress / 0.035)
        let cornerRetention = taperProgress
            * taperProgress
            * (3 - (2 * taperProgress))
        let cornerScale = DictationPillView.cornerScale(
            forWidthScale: modeWidthScale
        )
        let shoulderHorizontalDepth = min(
            6 * cornerScale,
            notchRect.width / 4
        )
        let shoulderVerticalDepth = 6 * cornerScale * cornerRetention
        let leadingHorizontalRadius = min(
            9 * cornerScale,
            max(0, notchRect.width - shoulderHorizontalDepth)
        )
        let leadingVerticalRadius = min(
            9 * cornerScale * cornerRetention,
            max(
                0,
                (notchRect.height - (shoulderVerticalDepth * 2)) / 2
            )
        )
        let bodyTop = notchRect.minY + shoulderVerticalDepth
        let bodyBottom = notchRect.maxY - shoulderVerticalDepth
        let horizontalCurve = leadingHorizontalRadius * 0.552_284_75
        let verticalCurve = leadingVerticalRadius * 0.552_284_75

        var path = Path()
        path.move(to: CGPoint(x: notchRect.maxX, y: notchRect.minY))
        path.addCurve(
            to: CGPoint(
                x: notchRect.maxX - shoulderHorizontalDepth,
                y: bodyTop
            ),
            control1: CGPoint(
                x: notchRect.maxX,
                y: notchRect.minY + (shoulderVerticalDepth * 0.78)
            ),
            control2: CGPoint(
                x: notchRect.maxX - (shoulderHorizontalDepth * 0.22),
                y: bodyTop
            )
        )
        path.addLine(
            to: CGPoint(
                x: notchRect.minX + leadingHorizontalRadius,
                y: bodyTop
            )
        )
        path.addCurve(
            to: CGPoint(
                x: notchRect.minX,
                y: bodyTop + leadingVerticalRadius
            ),
            control1: CGPoint(
                x: notchRect.minX + leadingHorizontalRadius - horizontalCurve,
                y: bodyTop
            ),
            control2: CGPoint(
                x: notchRect.minX,
                y: bodyTop + leadingVerticalRadius - verticalCurve
            )
        )
        path.addLine(
            to: CGPoint(
                x: notchRect.minX,
                y: bodyBottom - leadingVerticalRadius
            )
        )
        path.addCurve(
            to: CGPoint(
                x: notchRect.minX + leadingHorizontalRadius,
                y: bodyBottom
            ),
            control1: CGPoint(
                x: notchRect.minX,
                y: bodyBottom - leadingVerticalRadius + verticalCurve
            ),
            control2: CGPoint(
                x: notchRect.minX + leadingHorizontalRadius - horizontalCurve,
                y: bodyBottom
            )
        )
        path.addLine(
            to: CGPoint(
                x: notchRect.maxX - shoulderHorizontalDepth,
                y: bodyBottom
            )
        )
        path.addCurve(
            to: CGPoint(x: notchRect.maxX, y: notchRect.maxY),
            control1: CGPoint(
                x: notchRect.maxX - (shoulderHorizontalDepth * 0.22),
                y: bodyBottom
            ),
            control2: CGPoint(
                x: notchRect.maxX,
                y: notchRect.maxY - (shoulderVerticalDepth * 0.78)
            )
        )
        path.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.minY))
        path.closeSubpath()
        return path
    }
}

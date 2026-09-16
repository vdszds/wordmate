import SwiftUI

/// A present-volume meter shared by the recorder notch and setup. It uses one
/// symmetric profile rather than a scrolling history, so every bar responds to
/// what the microphone is hearing now.
///
/// While the microphone is still starting (`isWarmingUp`), the same bars
/// breathe with a soft crest travelling along them at low amplitude. When
/// audio arrives they simply begin following real levels, and the lengths
/// interpolate, so there is no loader to swap out and no visual seam.
struct LiveAudioWaveform: View {
    enum Orientation: Equatable {
        case horizontal
        case vertical
    }

    let level: Double
    var orientation: Orientation = .horizontal
    var color: Color = .primary
    var barThickness: CGFloat = 2.2
    var spacing: CGFloat = 2.45
    var minimumExtent: CGFloat = 3.5
    var isWarmingUp = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let barProfile: [CGFloat] = [
        0.22, 0.31, 0.27, 0.45, 0.39, 0.63, 0.55, 0.82, 1,
        0.82, 0.55, 0.63, 0.39, 0.45, 0.27, 0.31, 0.22,
    ]

    /// One full pass of the warm-up crest along the bars.
    static let warmupPeriod: TimeInterval = 1.4

    private let noiseGate = 0.055
    private let maximumResponsiveLevel = 0.68

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: !isWarmingUp || reduceMotion
            )
        ) { timeline in
            GeometryReader { proxy in
                if orientation == .vertical {
                    VStack(spacing: spacing) {
                        ForEach(Self.barProfile.indices, id: \.self) { index in
                            bar(
                                length: extent(
                                    at: index,
                                    available: proxy.size.width,
                                    date: timeline.date
                                )
                            )
                            .frame(height: barThickness)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: spacing) {
                        ForEach(Self.barProfile.indices, id: \.self) { index in
                            bar(
                                length: extent(
                                    at: index,
                                    available: proxy.size.height,
                                    date: timeline.date
                                )
                            )
                            .frame(width: barThickness)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .opacity(isWarmingUp ? 0.24 : 1)
        .animation(.linear(duration: 0.045), value: level)
        .animation(.easeOut(duration: 0.42), value: isWarmingUp)
        .accessibilityLabel(isWarmingUp ? "Microphone starting" : "Live microphone level")
    }

    private func bar(length: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(color)
            .frame(
                width: orientation == .vertical ? length : barThickness,
                height: orientation == .horizontal ? length : barThickness
            )
    }

    private func extent(at index: Int, available: CGFloat, date: Date) -> CGFloat {
        let usableExtent = max(minimumExtent, available)
        let response: CGFloat
        if isWarmingUp {
            let phase = reduceMotion
                ? 0
                : date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.warmupPeriod)
                    / Self.warmupPeriod
            response = Self.warmupResponse(
                at: index,
                phase: phase,
                animated: !reduceMotion
            )
        } else {
            response = responsiveResponse(at: index)
        }
        return minimumExtent + ((usableExtent - minimumExtent) * response)
    }

    /// The share of the available extent a bar takes while the microphone is
    /// starting: a faint breathing base shaped by the bar profile, plus a
    /// soft crest that travels along the bars once per period. Values stay
    /// well below a speaking level so the state cannot be mistaken for audio.
    static func warmupResponse(at index: Int, phase: Double, animated: Bool) -> CGFloat {
        let count = barProfile.count
        let profile = Double(barProfile[index])
        let breathing = animated ? 0.5 + (0.5 * sin(2 * .pi * phase)) : 0.5
        let base = (0.10 + (0.04 * breathing)) * (0.6 + (0.4 * profile))
        guard animated else { return CGFloat(base) }

        let position = Double(index) / Double(count - 1)
        let distance = abs(position - phase)
        let wrapped = min(distance, 1 - distance)
        let crest = exp(-0.5 * pow(wrapped / 0.16, 2))
        return CGFloat(base + (0.20 * crest))
    }

    private func responsiveResponse(at index: Int) -> CGFloat {
        let normalized = max(
            0,
            min(1, (level - noiseGate) / maximumResponsiveLevel)
        )
        let responsiveLevel = CGFloat(pow(normalized, 0.70))
        return responsiveLevel * Self.barProfile[index]
    }
}

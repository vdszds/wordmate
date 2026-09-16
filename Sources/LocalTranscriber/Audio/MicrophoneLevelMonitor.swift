import AVFoundation
import Foundation

@MainActor
final class MicrophoneLevelMonitor {
    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    func start(
        preferredDeviceUID: String? = nil,
        levelHandler: @escaping @Sendable (Double) -> Void
    ) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        try AudioInputDeviceManager.configure(
            input,
            preferredDeviceUID: preferredDeviceUID
        )
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
            guard let samples = buffer.floatChannelData?.pointee else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            var sumOfSquares: Float = 0
            for index in 0..<count {
                let sample = samples[index]
                sumOfSquares += sample * sample
            }

            let rms = sqrt(Double(sumOfSquares) / Double(count))
            let decibels = rms > 0 ? 20 * log10(rms) : -80
            levelHandler(AudioLevelNormalizer.normalize(decibels: decibels))
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        isRunning = false
    }
}

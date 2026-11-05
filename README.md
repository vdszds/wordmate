<p align="center">
  <img src="Assets/WordmateIcon.png" alt="Wordmate" width="96" height="96">
</p>

<h1 align="center">Wordmate</h1>

<p align="center">
  Free and open-source local voice typing for Mac.
</p>

<p align="center">
  <a href="https://wordmate.sh">Website</a> ·
  <a href="https://releases.wordmate.sh/desktop/macos/latest/Wordmate.dmg">Download</a>
</p>

---

Wordmate turns speech into text anywhere on macOS. Hold <kbd>Fn</kbd> for push-to-talk dictation or double-tap <kbd>Fn</kbd> for hands-free recording, then continue writing as the transcript appears in the app you were using.

Parakeet TDT v3 handles speech recognition on-device, with optional Qwen3 post-processing for punctuation, filler words, repetitions, and spoken formatting. Audio and transcripts stay on your Mac.

## Download

| Platform | Download |
| --- | --- |
| macOS 14+ (Apple silicon) | [Download `.dmg`](https://releases.wordmate.sh/desktop/macos/latest/Wordmate.dmg) |

## Features

- System-wide voice typing with automatic pasting
- Push-to-talk and hands-free recording from the Fn key
- Audio and video file transcription with drag and drop
- Local transcription in 25 European languages
- Optional on-device transcript cleanup
- Built-in and external microphone selection
- Menu-bar controls, live waveform, and local usage totals
- Signed in-app updates

## Quick start

```sh
git clone https://github.com/vdszds/wordmate.git
cd wordmate
zsh scripts/run-app.sh
```

Building Wordmate requires an Apple silicon Mac running macOS 14 or later and Xcode 16 or later. The speech and language models are downloaded during setup.

## Tech stack

Swift, SwiftUI, AppKit, Core ML, MLX Swift, FluidAudio, and Sparkle.

## Contributing

Contributions are welcome. Fork the repository, create a branch, and open a pull request.

## License

[MIT](LICENSE) — free for personal and commercial use.

## Acknowledgments

- [NVIDIA Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) for multilingual speech recognition
- [Qwen3](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit) for local transcript cleanup
- [FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device audio inference
- [MLX Swift](https://github.com/ml-explore/mlx-swift) for Apple silicon language-model inference
- [Sparkle](https://github.com/sparkle-project/Sparkle) for app updates

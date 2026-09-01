# Wordmate transcription pipeline

This repository contains the open-source, on-device transcription pipeline used by Wordmate for macOS. It includes:

- Parakeet speech recognition through FluidAudio and Core ML
- optional Qwen transcript cleanup through MLX Swift
- live audio accumulation, streaming transcript reconciliation, and conservative cleanup policies
- unit, acceptance, and opt-in benchmark tests for the pipeline

Audio and transcript processing run locally. The Wordmate application shell, interface, onboarding, system integration, branding, website, and release infrastructure are intentionally outside this repository.

## Requirements

- Apple silicon Mac
- macOS 14 or newer
- Xcode 16 or newer

## Test

```sh
swift test
```

Tests that download models or use external audio fixtures are skipped unless their documented `WORDMATE_RUN_*` environment variable is enabled.

## Source synchronization

This repository is generated from a strict allowlist in the private Wordmate workspace. Changes should be made in the primary workspace and exported as part of a desktop release, rather than edited independently here.

## License

See `LICENSE`.

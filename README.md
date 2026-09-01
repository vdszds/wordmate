# Wordmate transcription pipeline

This repository contains the on-device transcription pipeline used by [Wordmate](https://wordmate.sh) for macOS.

Parakeet turns microphone audio into text. Qwen can then clean up punctuation, capitalization, repeated words, and spoken corrections. On longer recordings, some of that cleanup happens while you are still speaking. On the test machine, the final text was ready about **0.4 seconds after Fn was released** for the median LibriSpeech recording.

Everything runs locally. Audio and transcripts do not leave the Mac.

This repository does not contain the Wordmate interface, onboarding, keyboard handling, branding, website, or release system.

## Models

| Step | Model | Runs with | What it does |
| --- | --- | --- | --- |
| Speech recognition | Parakeet TDT v3 | FluidAudio and Core ML | Turns 16 kHz mono audio into text |
| Optional text cleanup | Qwen3 0.6B, 4-bit (about 351 MB) | MLX Swift and Metal | Cleans the transcript without freely rewriting it |

Both models are downloaded once and then loaded from the Mac. Qwen is optional. If it is disabled, Wordmate returns the raw Parakeet transcript after a small rule-based cleanup.

## How it works

Here is the short version:

1. Wordmate keeps one continuous copy of the microphone audio.
2. Every 10 seconds, Parakeet checks everything recorded so far.
3. Sentences that look finished can be cleaned by Qwen while recording continues.
4. When Fn is released, Parakeet runs once more on the complete recording.
5. Wordmate safely reuses earlier Qwen work, cleans anything that changed, and returns the final text.

The final Parakeet transcript always wins over an earlier draft. If Wordmate is not sure that an early result is still valid, it processes that text again.

### Keeping the audio continuous

Apple's audio engine reuses microphone buffers. [`LiveAudioCapture`](Sources/LocalTranscriber/Audio/LiveAudioCapture.swift) copies each buffer before it can be reused.

[`LiveAudioAccumulator`](Sources/LocalTranscriber/Audio/LiveAudioCapture.swift) keeps the recording in its original microphone format. When Parakeet needs the audio, it converts the complete recording so far to mono 16 kHz.

This avoids tiny timing gaps caused by converting every microphone chunk separately. Those gaps can split a word at a chunk boundary and reduce recognition accuracy.

### Running Parakeet while recording

Parakeet TDT v3 is designed to work on a complete piece of audio. Splitting a recording into separate fixed windows caused word seams—for example, recognizing one word as `four` + `teen`.

[`ParakeetEngine`](Sources/LocalTranscriber/Transcription/ParakeetEngine.swift) therefore runs Parakeet on all audio recorded so far, once every 10 seconds. It does not join together unrelated 10-second transcripts.

A sentence can be sent to Qwen early when:

- it finishes before the newest sentence, so the newest sentence is still held back; or
- the same words appear in two Parakeet checks.

Even then, the last eight words are held back as an extra safety margin.

### Cleaning finished sentences early

[`StreamingTranscriptPolisher`](Sources/LocalTranscriber/Transcription/StreamingTranscriptPolisher.swift) gives Qwen one finished sentence at a time. Qwen can also see a short piece of text before and after the sentence to understand its context, but it is told not to return those surrounding words.

The microphone can keep collecting audio while Qwen does this work. For longer recordings, this means less work remains after Fn is released.

### Finishing after Fn is released

After release, Parakeet runs on the complete recording one final time. Wordmate compares that final transcript with the sentences cleaned earlier:

- If the words still match exactly, the earlier Qwen result is reused.
- If Parakeet changed part of the transcript, only that part is cleaned again.
- If a match is unclear, Wordmate cleans the full transcript again.
- If Qwen fails, Wordmate returns the Parakeet transcript instead of losing the recording.

This keeps the speed benefit of early cleanup without treating an unfinished transcript as final.

## What Qwen does

Qwen is used as a careful copy editor, not as a general-purpose writer.

| Qwen may | Qwen may not |
| --- | --- |
| Add punctuation and capitalization | Summarize or shorten the message |
| Remove a clearly accidental repeated phrase | Guess a different name, term, or recognized word |
| Remove a standalone filler | Reword a sentence to make it sound smoother |
| Apply an explicit spoken correction | Add lists, Markdown, commentary, or answers |
| Remove an obvious partial-word retry | Silently change a number |

For example:

```text
I think I think we should update this function before before merging.
→ I think we should update this function before merging.

The result was very very good, exactly what we wanted.
→ The result was very very good, exactly what we wanted.

The feature is ready it works well should we release it tomorrow
→ The feature is ready. It works well. Should we release it tomorrow?
```

The second example stays unchanged because repeated words can be intentional emphasis.

### Safety checks after Qwen

[`TranscriptPolishPolicy`](Sources/LocalTranscriber/Transcription/TranscriptPostProcessor.swift) checks Qwen's answer before it is accepted:

- Kept words must come from the original transcript and stay in the same order.
- Guessed or replaced words are changed back to the original words.
- Qwen cannot delete words from fluent text just to make it shorter.
- If Qwen removes a repeated phrase, it must remove one complete copy.
- Every number from the original transcript must remain unchanged.
- Added Markdown, JSON, XML, prompt instructions, or copied context is rejected.
- If an answer is unsafe, Wordmate retries a smaller part or uses the original text.

Qwen runs with `temperature = 0`, `topP = 1`, and thinking disabled. Before Qwen runs, a small rule-based cleaner removes standalone versions of `um` and `uh` and repairs the leftover spacing.

## Performance

The numbers below were produced on 1 September 2026 by the public [`LibriSpeechBenchmarkTests`](Tests/LocalTranscriberTests/LibriSpeechBenchmarkTests.swift). The test uses the same Parakeet, Qwen, early-cleanup, final-pass, and safety code as the production pipeline.

### Word error rate

Word error rate, or WER, measures wrong, missing, and extra words. Lower is better. It ignores punctuation and capitalization.

| LibriSpeech set | Recordings | Audio | Reference words | Parakeet WER | WER after Qwen | Recordings made better / unchanged / worse |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `test-clean` | 100 | 16.018 min | 2,527 | **1.979%** | **1.979%** | 0 / 100 / 0 |
| `test-other` | 50 | 7.956 min | 1,330 | **3.759%** | **3.759%** | 0 / 50 / 0 |

Qwen receives text, not audio, so it does not have its own speech-recognition WER. “WER after Qwen” is the score for the final pipeline output.

The unchanged scores are expected for these fluent audiobook recordings. Qwen can improve punctuation and capitalization, but WER does not count those changes. It is also deliberately prevented from guessing corrections to Parakeet's recognized words. Across all 150 recordings, Qwen added **zero word errors**.

### Time after releasing Fn

The next table measures what the user waits for after speaking. Model downloads and startup loading are not included.

| LibriSpeech set | Parakeet result | Extra Qwen and final checks | Final text | 90% finished within | 95% finished within | Slowest result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `test-clean` | 0.136 s median | 0.268 s median | **0.403 s median** | 0.486 s | 0.520 s | 0.561 s |
| `test-other` | 0.127 s median | 0.279 s median | **0.404 s median** | 0.547 s | 0.567 s | 0.596 s |

Each median is calculated separately, so the first two columns may not add up to the third exactly.

### A longer recording

A separate 92.031-second recording with audible stutters and a 156-word reference was also played through the pipeline in real time.

| Measurement | Result |
| --- | ---: |
| Parakeet WER | 6.410% |
| WER after Qwen | 6.410% |
| Fn release → Parakeet result | 0.591 s |
| Parakeet result → final text | 0.612 s |
| Fn release → final text | **1.203 s** |
| Early Qwen jobs completed before release | 5 of 5 |
| Qwen work completed while recording | 3.575 s |
| Words safely reused after release | 134 of 157 (85.4%) |
| Words that still needed cleanup | 23 |

Parakeet had already removed the audible stutters from its text, so Qwen correctly kept the words unchanged. Most remaining errors were sound-alike words, names, and numbers that Qwen could not safely guess.

Reusing the early Qwen results reduced the work after Parakeet from 0.986 seconds to 0.612 seconds—a **37.9% improvement**. Total time after Fn release fell from 1.590 seconds to 1.203 seconds—a **24.3% improvement**.

### Test machine

| Item | Value |
| --- | --- |
| Mac | Mac16,5 with Apple M4 Max |
| CPU and memory | 16 logical cores and 128 GiB |
| macOS | 15.7.2 (24G325) |
| Dataset | LibriSpeech SLR12 `test-clean` and `test-other` |
| Playback | Real time (1×) |
| Recording selection | Fixed seed `20260901`; recordings at least 5 seconds long |

The model files were already downloaded. Loading from disk took 0.105–0.106 seconds for Parakeet and 2.098–2.200 seconds for Qwen. Model loading and one warm-up recording were excluded from the timing tables.

These results describe this machine and these recordings. LibriSpeech is read audiobook English, not everyday dictation. Other Macs, microphones, accents, background noise, technical terms, and code-heavy speech can produce different results.

## Code guide

- [`Audio/`](Sources/LocalTranscriber/Audio) keeps and converts microphone audio.
- [`ParakeetEngine.swift`](Sources/LocalTranscriber/Transcription/ParakeetEngine.swift) loads Parakeet and creates early and final transcripts.
- [`StreamingTranscriptPolisher.swift`](Sources/LocalTranscriber/Transcription/StreamingTranscriptPolisher.swift) sends finished sentences to Qwen and safely reuses them.
- [`TranscriptPostProcessor.swift`](Sources/LocalTranscriber/Transcription/TranscriptPostProcessor.swift) runs Qwen and checks its output.
- [`Tests/`](Tests/LocalTranscriberTests) contains unit tests, model tests, and optional benchmarks.

## Requirements

- Apple silicon Mac
- macOS 14 or newer
- Xcode 16 or newer

## Running the tests

The normal test suite does not download models or external audio:

```sh
swift test
```

Run the Qwen acceptance examples with:

```sh
WORDMATE_RUN_MODEL_ACCEPTANCE=1 \
swift test --filter PostProcessingAcceptanceTests
```

To repeat the `test-clean` benchmark after downloading the official LibriSpeech data:

```sh
WORDMATE_RUN_LIBRISPEECH_BENCHMARK=1 \
WORDMATE_LIBRISPEECH_ROOT=/path/to/LibriSpeech/test-clean \
WORDMATE_LIBRISPEECH_SPLIT=test-clean \
WORDMATE_LIBRISPEECH_SAMPLE_COUNT=100 \
WORDMATE_LIBRISPEECH_MIN_SECONDS=5 \
WORDMATE_LIBRISPEECH_SEED=20260901 \
WORDMATE_LIBRISPEECH_REPLAY_SPEED=1 \
WORDMATE_LIBRISPEECH_REPORT=/tmp/wordmate-test-clean.md \
swift test --filter LibriSpeechBenchmarkTests
```

Use `test-other` and a sample count of `50` to repeat the second benchmark.

Tests that use real models and audio are optional because they can download hundreds of megabytes and take several minutes.

## Source synchronization

This repository is generated from a strict list of files in the private Wordmate workspace. Changes should be made in the main workspace and exported from there instead of being edited separately in this repository.

## License

The pipeline source is available under the [MIT License](LICENSE).

# Wordmate transcription pipeline

This repository contains the on-device transcription pipeline used by [Wordmate](https://wordmate.sh) for macOS.

Parakeet turns microphone audio into text. Qwen can then clean up punctuation, capitalization, repeated words, and spoken corrections. On longer recordings, most of that cleanup happens while you are still speaking. On the test machine, the final text was ready about **0.3 seconds after Fn was released** for the median LibriSpeech recording, and within about **0.7–1.7 seconds** for one-minute dictations with stutters.

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
2. Every 5 seconds, Parakeet checks everything recorded so far.
3. Sentences that ended a few words before the edge of that check are queued for Qwen, which cleans them on its own worker while recording continues.
4. When Fn is released, Parakeet runs once more on the complete recording.
5. Wordmate reuses every earlier Qwen result whose words and sentence boundaries still match, cleans only the text that is new or changed, and returns the final text.

The final Parakeet transcript always wins over an earlier draft. If Wordmate is not sure that an early result is still valid, it processes that text again.

### Keeping the audio continuous

Apple's audio engine reuses microphone buffers. [`LiveAudioCapture`](Sources/LocalTranscriber/Audio/LiveAudioCapture.swift) copies each buffer before it can be reused.

[`LiveAudioAccumulator`](Sources/LocalTranscriber/Audio/LiveAudioCapture.swift) keeps the recording in its original microphone format. When Parakeet needs the audio, it converts the complete recording so far to mono 16 kHz.

This avoids tiny timing gaps caused by converting every microphone chunk separately. Those gaps can split a word at a chunk boundary and reduce recognition accuracy.

### Running Parakeet while recording

Parakeet TDT v3 is designed to work on a complete piece of audio. Splitting a recording into separate fixed windows caused word seams—for example, recognizing one word as `four` + `teen`.

[`ParakeetEngine`](Sources/LocalTranscriber/Transcription/ParakeetEngine.swift) therefore runs Parakeet on all audio recorded so far, once every 5 seconds. It does not join together unrelated transcripts. Each checkpoint waits at least three times as long as the previous checkpoint took, so a long recording never spends most of its time re-transcribing audio.

A sentence is committed for early cleanup when it ends at least three words before the end of the checkpoint. A cut in the middle of a word can only corrupt the last words of a checkpoint, so a sentence boundary followed by several more words was heard in full. The newest sentence is therefore never held back for a whole extra checkpoint.

Each checkpoint is compared with the sentences already sent to Qwen. Only new sentences, or sentences whose words changed, are sent again, and always in transcript order. Early cleanup keeps going for the whole recording; a revised word no longer stops it.

### Cleaning finished sentences early

[`StreamingTranscriptPolisher`](Sources/LocalTranscriber/Transcription/StreamingTranscriptPolisher.swift) queues finished sentences and gives them to Qwen one at a time on a background worker. The audio loop never waits for the language model, so Qwen and Parakeet overlap. Qwen can see a short piece of text before and after each sentence to understand its context, but it is told not to return those surrounding words. A fragment shorter than four words, such as the text left after an abbreviation period, is cleaned together with the sentence that follows it.

For longer recordings, this means little work remains after Fn is released: on the one-minute benchmark recordings below, 79–91% of the words were already clean at release, and 50% on the stutter recording whose final sentence alone is 45 words long.

### Finishing after Fn is released

After release, Parakeet runs on the complete recording one final time. Only a Qwen call already in progress is awaited; queued sentences that never started are folded into the final pass, where neighbouring ones merge into a single call. Wordmate then compares the final transcript with the sentences cleaned earlier:

- If the words still match exactly, and the final transcript starts and ends a sentence at the same words, the earlier Qwen result is reused.
- If Parakeet changed part of the transcript, only that part is cleaned again, a few sentences at a time.
- If no earlier sentence can be matched, Wordmate cleans the full transcript again.
- If Qwen fails, Wordmate returns the Parakeet transcript instead of losing the recording.

The sentence-boundary check matters: an early checkpoint can end in the middle of a sentence and Parakeet will still add a period there. Without the check, that period would be pasted into the middle of the final sentence.

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
- Qwen cannot delete words from fluent text just to make it shorter. Deletions are allowed only for complete copies of immediately repeated speech, for a partial-word retry (a word that is a strict prefix of the next word, such as `s simply`), and, once repeated speech shows the passage is disfluent, for a few nearby false starts.
- If Qwen removes a repeated phrase, it must remove one complete copy.
- Every number from the original transcript must remain unchanged.
- Markdown emphasis around a word is stripped rather than rejected; JSON, XML, prompt instructions, or copied context are rejected.
- A sentence break that Qwen inserts before a lowercase word where the original had none is removed.
- If an answer is unsafe, Wordmate retries the same text without context, then one sentence at a time. A chunk that starts or ends mid-sentence can never gain a period at the seam, and a separate echo-removal prompt runs only when repeated speech is still present.

Qwen runs with `temperature = 0`, `topP = 1`, no repetition penalty, and thinking disabled. A repetition penalty was measured and left off: the task is verbatim copying, and a penalty discourages re-emitting the repeated source words a faithful edit must keep. Every prompt starts with the same instructions and examples, so the key/value cache of that shared prefix is kept between calls and only the transcript-specific part of each prompt is processed.

Before Qwen runs, a small rule-based cleaner removes standalone versions of `um` and `uh`, repairs the leftover spacing, and removes unmistakable partial-word retries. [`PartialWordRetryCleaner`](Sources/LocalTranscriber/Transcription/PartialWordRetryCleaner.swift) deletes a fragment only when it is a strict prefix of the next word, is not joined to it by an apostrophe or hyphen, and is not a word in the user's spelling language according to the macOS spell checker; in English, single letters other than `a` and `I` also count as fragments. Dictionary words such as `the` in `the theory` are never touched.

## Performance

The numbers below were produced on 2 September 2026 by the public benchmark tests. They use the same Parakeet, Qwen, early-cleanup, final-pass, and safety code as the production pipeline.

### Word error rate

Word error rate, or WER, measures wrong, missing, and extra words. Lower is better. It ignores punctuation and capitalization.

| LibriSpeech set | Recordings | Audio | Reference words | Parakeet WER | WER after Qwen | Recordings made better / unchanged / worse |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `test-clean` | 100 | 16.018 min | 2,527 | **1.979%** | **1.979%** | 0 / 100 / 0 |
| `test-other` | 50 | 7.956 min | 1,330 | **3.759%** | **3.759%** | 0 / 50 / 0 |

Qwen receives text, not audio, so it does not have its own speech-recognition WER. “WER after Qwen” is the score for the final pipeline output.

The unchanged scores are expected for these fluent audiobook recordings. Qwen can improve punctuation and capitalization, but WER does not count those changes. It is also deliberately prevented from guessing corrections to Parakeet's recognized words. Across all 150 recordings, Qwen added **zero word errors**.

### Time after releasing Fn

The next table measures what the user waits for after speaking. Model downloads and startup loading are not included. These runs use the release build, which is what the app ships.

| LibriSpeech set | Parakeet result | Extra Qwen and final checks | Final text | 90% finished within | 95% finished within | Slowest result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `test-clean` | 0.174 s median | 0.131 s median | **0.306 s median** | 0.367 s | 0.390 s | 0.427 s |
| `test-other` | 0.175 s median | 0.129 s median | **0.300 s median** | 0.411 s | 0.429 s | 0.479 s |

Each median is calculated separately, so the first two columns may not add up to the third exactly. Compared with the previous pipeline, the median time after release fell from 0.403 s to 0.306 s on `test-clean` and from 0.404 s to 0.300 s on `test-other`; the 95th percentile fell from 0.520 s to 0.390 s and from 0.567 s to 0.429 s.

### Longer dictations with stutters

LibriSpeech is fluent read speech, so it shows that Qwen is lossless but not what it fixes. For that, four one-minute recordings of a speaker reading placeholder text were played through the pipeline in real time using [`StreamingAudioPipelineBenchmarkTests`](Tests/LocalTranscriberTests/StreamingAudioPipelineBenchmarkTests.swift). Two of them contain heavy stutters: repeated words, repeated phrases, and restarted words.

| Recording | Audio | Reference words | Parakeet word errors | Word errors after Qwen | Parakeet WER | WER after Qwen |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Lorem Ipsum 1 | 63.7 s | 117 | 13 | 13 | 11.111% | 11.111% |
| Lorem Ipsum 2 (heavy stutter) | 71.3 s | 136 | 30 | 30 | 22.059% | 22.059% |
| Lorem Ipsum 3 | 55.9 s | 148 | 9 | 9 | 6.081% | 6.081% |
| Heavy stutter | 61.6 s | 73 | 23 | **12** | 31.507% | **16.438%** |
| **All four** | 252.5 s | 474 | 75 | **64** | 15.823% | **13.502%** |

On the recording built around stutters, Qwen removed eleven of Parakeet's 23 word errors: `Lorem Ipsum Ipsum is simply dummy text text`, `has been has been`, `ever since ever since`, `took took`, `translation translation`, `dummy text dummy text`, and `survived survived` all came out clean. It missed two: `designers designers` received a comma instead of a deletion, and the restarted name in `Bridge Brid St Bride` stayed. The other three recordings did not move, for two different reasons. Lorem Ipsum 1 and 3 are almost fluent, and their remaining errors are Parakeet recognition mistakes on names and Latin (`Saint Bridge` for St Bride, `Letra sets` for Letraset's, `loran ipsum`) that Qwen is deliberately forbidden to guess at. Lorem Ipsum 2 stutters mostly on the Latin itself (`Lorum Ipsum Lorum Ipsum dolorum Lorum Ipsum dolor sit amed`), which a 0.6B model does not recognize as a restart, and the rest of its errors are again names, sound-alike words, and numbers spoken as words.

The safety checks matter as much as the model here. An earlier version of the pipeline lost one copy of the intentional phrase `content here, content here` on Lorem Ipsum 3 and inserted stray periods into the stutter recording (`dummy text. of the printing`); both are fixed, and Qwen never made any of the four recordings worse.

The same runs measure what the user waits for after release. They were measured with the debug test bundle, where Qwen generates roughly half as fast as in the release app, so the absolute times are conservative.

| Recording | Words already clean at release | Fn release → final text, previous pipeline | Fn release → final text, now |
| --- | ---: | ---: | ---: |
| Lorem Ipsum 1 | 112 of 123 (91%) | 2.026 s | **0.702 s** |
| Lorem Ipsum 2 (heavy stutter) | 122 of 145 (84%) | 5.590 s | **1.698 s** |
| Lorem Ipsum 3 | 115 of 146 (79%) | 1.091 s | **0.891 s** |
| Heavy stutter | 45 of 90 (50%) | 1.744 s | **1.562 s** |

The previous pipeline cleaned sentences inside the audio loop, stopped early cleanup after the first revised word, and retried rejected answers in 220-character chunks; one 73-word tail needed eight serial Qwen calls after release. The current pipeline reuses every sentence that was already clean and usually needs one Qwen call for the tail. The remaining time is dominated by the final Parakeet pass, about 0.47 seconds per minute of audio on this machine; the stutter recording reuses only half its words because its final sentence alone is 45 words long.

A separate 92.031-second recording with audible stutters and a 156-word reference shows the other side of the same behaviour:

| Measurement | Result |
| --- | ---: |
| Parakeet WER | 6.410% |
| WER after Qwen | 6.410% |
| Fn release → Parakeet result | 0.588 s |
| Parakeet result → final text | 0.425 s |
| Fn release → final text | **1.013 s** |
| Words safely reused after release | 134 of 157 (85.4%) |
| Words that still needed cleanup | 23 |

Here Parakeet had already dropped the audible stutters from its own text, so there was nothing for Qwen to remove and it correctly left the words unchanged. The time after release fell from 1.203 s with the previous pipeline to 1.013 s. Whether Qwen changes the word error rate depends on whether the stutters survive speech recognition; the safety checks make sure it never gets worse either way.

### Test machine

| Item | Value |
| --- | --- |
| Mac | Mac16,5 with Apple M4 Max |
| CPU and memory | 16 logical cores and 128 GiB |
| macOS | 15.7.2 (24G325) |
| Dataset | LibriSpeech SLR12 `test-clean` and `test-other` |
| Playback | Real time (1×) |
| Recording selection | Fixed seed `20260901`; recordings at least 5 seconds long |

The model files were already downloaded. Model loading and one warm-up recording were excluded from the timing tables.

These results describe this machine and these recordings. LibriSpeech is read audiobook English, not everyday dictation. Other Macs, microphones, accents, background noise, technical terms, and code-heavy speech can produce different results.

## Code guide

- [`Audio/`](Sources/LocalTranscriber/Audio) keeps and converts microphone audio.
- [`ParakeetEngine.swift`](Sources/LocalTranscriber/Transcription/ParakeetEngine.swift) loads Parakeet, runs the cumulative checkpoints, decides which sentences are committed, and produces the final transcript.
- [`StreamingTranscriptPolisher.swift`](Sources/LocalTranscriber/Transcription/StreamingTranscriptPolisher.swift) queues committed sentences for Qwen, tracks which sentences were already sent, and reuses their results at release.
- [`TranscriptPostProcessor.swift`](Sources/LocalTranscriber/Transcription/TranscriptPostProcessor.swift) runs Qwen with the shared prompt cache, records every call for diagnostics, and checks each answer.
- [`TranscriptCleaner.swift`](Sources/LocalTranscriber/Transcription/TranscriptCleaner.swift) and [`PartialWordRetryCleaner.swift`](Sources/LocalTranscriber/Transcription/PartialWordRetryCleaner.swift) apply the rule-based cleanup before Qwen.
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
swift test -c release --filter LibriSpeechBenchmarkTests
```

Use `test-other` and a sample count of `50` to repeat the second benchmark. Release builds need MLX's `mlx.metallib` next to the test binary; the debug configuration works without that step.

To play your own recordings through the streaming pipeline in real time, write a JSON manifest with one entry per recording and a plain-text reference transcript:

```json
[
  {
    "name": "my-dictation",
    "audioPath": "/path/to/recording.m4a",
    "referencePath": "/path/to/reference.txt"
  }
]
```

```sh
WORDMATE_RUN_STREAMING_BENCHMARK=1 \
WORDMATE_STREAMING_BENCHMARK_MANIFEST=/path/to/manifest.json \
WORDMATE_STREAMING_REPLAY_SPEED=1 \
WORDMATE_BENCHMARK_PRINT_TRANSCRIPTS=1 \
swift test --filter StreamingAudioPipelineBenchmarkTests
```

The output lists, per recording, the word error rates, the time from Fn release to the raw and final transcripts, how many words were reused at release, every Qwen call with its stage, outcome, token counts and timing, and the cost of each Parakeet checkpoint.

Tests that use real models and audio are optional because they can download hundreds of megabytes and take several minutes.

## Source synchronization

This repository is generated from a strict list of files in the private Wordmate workspace. Changes should be made in the main workspace and exported from there instead of being edited separately in this repository.

## License

The pipeline source is available under the [MIT License](LICENSE).

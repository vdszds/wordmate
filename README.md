# Wordmate transcription pipeline

This repository contains the on-device transcription pipeline used by [Wordmate](https://wordmate.sh) for macOS.

Parakeet turns microphone audio into text. Qwen then turns that dictation into written text: punctuation, capitalization, filler words, stutters, false starts, and spoken corrections. Rules write spoken numbers as numerals and split long dictations into paragraphs. On longer recordings, most of the cleanup happens while you are still speaking. On the test machine, the final text was ready about **0.3 seconds after Fn was released** for the median LibriSpeech recording, and within about **0.7–1.7 seconds** for one-minute, difficult recordings with stutters.

Everything runs locally. Audio and transcripts do not leave the Mac.

This repository does not contain the Wordmate interface, onboarding, keyboard handling, branding, website, or release system.

## Models

| Step                  | Model                            | Runs with              | What it does                                                |
| --------------------- | -------------------------------- | ---------------------- | ----------------------------------------------------------- |
| Speech recognition    | Parakeet TDT v3                  | FluidAudio and Core ML | Turns 16 kHz mono audio into text                           |
| Optional text cleanup | Qwen3 0.6B, 4-bit (about 351 MB) | MLX Swift and Metal    | Turns the transcript into written text without rewriting it |

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

For longer recordings, this means little work remains after Fn is released: on the one-minute benchmark recordings below, 79–91% of the words were already clean at release.

### Finishing after Fn is released

After release, Parakeet runs on the complete recording one final time. Only a Qwen call already in progress is awaited; queued sentences that never started are folded into the final pass. Wordmate then compares the final transcript with the sentences cleaned earlier:

- If the words still match exactly, and the final transcript starts and ends a sentence at the same words, the earlier Qwen result is reused.
- If Parakeet changed part of the transcript, only that part is cleaned again, a few sentences at a time.
- If no earlier sentence can be matched, Wordmate cleans the full transcript again.
- If Qwen fails, Wordmate returns the Parakeet transcript instead of losing the recording.

The sentence-boundary check matters: an early checkpoint can end in the middle of a sentence and Parakeet will still add a period there. Without the check, that period would be pasted into the middle of the final sentence.

## What Qwen does

Qwen is prompted as an assistant that edits a voice note before it goes into an email or a document. It works on the words as recognized and never becomes a writer.

| Qwen may                                                                                      | Qwen may not                                                               |
| --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Add periods, commas, question marks, capitalization, and quotation marks around quoted speech | Summarize, shorten, or reword a sentence                                   |
| Remove filler words and verbal tics such as `um`, `like`, `you know`, `I mean`, `basically`   | Guess a different name, term, or recognized word                           |
| Remove stutters, echoes, and partial words                                                    | Delete a name, a lone content word, a whole sentence, or a trailing phrase |
| Remove a false start the speaker abandoned and then restarted                                 | Add lists, Markdown, commentary, or answers                                |
| Apply an explicit spoken correction                                                           | Change a number                                                            |
| Drop a connective that only chains spoken sentences together (`and`, `so`, `but`)             |                                                                            |

For example:

```text
so um I'm just I'm just checking in to see if there are any updates on the order
→ I'm just checking in to see if there are any updates on the order.

I agree we should add examples I think we but with this prompt the model does almost nothing
→ I agree we should add examples. But with this prompt, the model does almost nothing.

did you see the report Doesn't it look like the numbers are off
→ Did you see the report? Doesn't it look like the numbers are off?

The result was very very good, exactly what we wanted.
→ The result was very very good, exactly what we wanted.
```

The last example stays unchanged because repeated words can be intentional emphasis.

Two rule-based steps finish the text after Qwen. [`SpokenNumberFormatter`](Sources/LocalTranscriber/Transcription/SpokenNumberFormatter.swift) writes spoken numbers the way a person types them: `twenty four hours` becomes `24 hours`, `the twenty eighth` becomes `the 28th`, `nineteen sixty six` becomes `1966`, `zero percent` becomes `0%`, `one point five` becomes `1.5`, and a number read digit by digit becomes a digit string. Small numbers such as `one week` or `six million` stay as words. [`ParagraphPlanner`](Sources/LocalTranscriber/Transcription/ParagraphPlanner.swift) splits dictations of at least eight sentences and 120 words into paragraphs of about three sentences, avoiding a break before a sentence that continues the previous one (`He …`, `Then …`). Neither step can change a word, which is why numbers are not left to the model.

### Safety checks after Qwen

[`TranscriptPolishPolicy`](Sources/LocalTranscriber/Transcription/TranscriptPostProcessor.swift) checks Qwen's answer before it is accepted:

- Kept words must come from the original transcript and stay in the same order. Guessed or replaced words are changed back to the original words.
- Deletions are budgeted by kind. Filler words and phrases may go freely, but never more than about 40% of a segment. Complete copies of immediately repeated speech and partial-word retries (a fragment that is a strict prefix of the next word, such as `s simply`) may go. A small budget of about one word in eight covers false starts and spoken corrections, and only for runs of two or more words that are followed by the start of a clause and contain no name.
- A lone content word, a whole sentence, or a phrase at the end of the text can never be deleted, however fluent the shorter version reads.
- If Qwen removes a repeated phrase, it must remove one complete copy.
- Every number from the original transcript must remain.
- A sentence break that Qwen inserts between two adjacent original words is kept and the next word is capitalized; a period standing where deleted speech was is removed.
- Markdown emphasis around a word is stripped rather than rejected; JSON, XML, prompt instructions, or copied context are rejected. An answer that repeats the surrounding context around the segment is first trimmed to the segment.
- If an answer is unsafe, Wordmate retries the same text without context, then one sentence at a time. A chunk that starts or ends mid-sentence can never gain a period at the seam, and a separate echo-removal prompt runs only when repeated speech is still present.

Qwen runs with `temperature = 0`, `topP = 1`, no repetition penalty, and thinking disabled. A repetition penalty was measured and left off: the task is verbatim copying, and a penalty discourages re-emitting the repeated source words a faithful edit must keep. Every prompt starts with the same instructions and examples, so the key/value cache of that shared prefix is kept between calls and only the transcript-specific part of each prompt is processed.

Before Qwen runs, a small rule-based cleaner removes standalone versions of `um` and `uh`, removes the two fillers small models most often leave behind, repairs the leftover spacing, and removes unmistakable partial-word retries. [`DiscourseFillerCleaner`](Sources/LocalTranscriber/Transcription/DiscourseFillerCleaner.swift) deletes a hedging `like` (`he's now like not responsive`, `like I told him`) and a parenthetical `you know` when their neighbours identify them; comparisons (`like a person`), the verb (`I like`), the idiom `like I said`, and `you know the answer` stay. Measured against a human-edited reference, these two rules agree with the editor in about four of five cases, which the models did not reach on their own. [`PartialWordRetryCleaner`](Sources/LocalTranscriber/Transcription/PartialWordRetryCleaner.swift) deletes a fragment only when it is a strict prefix of the next word, is not joined to it by an apostrophe or hyphen, and is not a word in the user's spelling language according to the macOS spell checker; in English, single letters other than `a` and `I` also count as fragments. Dictionary words such as `the` in `the theory` are never touched.

## Performance

The numbers below were produced by the public benchmark tests. They use the same Parakeet, Qwen, cleanup, final-pass, and safety code as the production pipeline.

### Word error rate

Word error rate, or WER, measures wrong, missing, and extra words. Lower is better. It ignores punctuation and capitalization, and numbers are compared as numerals on both sides, so `twenty four` in a reference and `24` in the output count as the same word.

| LibriSpeech set | Recordings |      Audio | Reference words | Parakeet WER | WER after Qwen | Recordings made better / unchanged / worse |
| --------------- | ---------: | ---------: | --------------: | -----------: | -------------: | -----------------------------------------: |
| `test-clean`    |        100 | 16.018 min |           2,527 |   **2.018%** |     **2.018%** |                                0 / 100 / 0 |
| `test-other`    |         50 |  7.956 min |           1,329 |   **3.762%** |     **3.762%** |                                 0 / 50 / 0 |

Qwen receives text, not audio, so it does not have its own speech-recognition WER. “WER after Qwen” is the score for the final pipeline output.

The unchanged scores are expected for these fluent audiobook recordings. Qwen can improve punctuation and capitalization, but WER does not count those changes. It is deliberately prevented from guessing corrections to Parakeet's recognized words, and the safety checks stop it from dropping content: across all 150 recordings, Qwen added **zero word errors**.

### Time after releasing Fn

The next table measures what the user waits for after speaking. Model downloads and startup loading are not included. These runs use the release build, which is what the app ships.

| LibriSpeech set | Parakeet result | Extra Qwen and final checks |         Final text | 90% finished within | 95% finished within | Slowest result |
| --------------- | --------------: | --------------------------: | -----------------: | ------------------: | ------------------: | -------------: |
| `test-clean`    |  0.148 s median |              0.133 s median | **0.285 s median** |             0.367 s |             0.411 s |        0.474 s |
| `test-other`    |  0.143 s median |              0.129 s median | **0.277 s median** |             0.382 s |             0.440 s |        0.803 s |

Each median is calculated separately, so the first two columns may not add up to the third exactly.

### Real dictation compared with an edited reference

WER cannot see sentence breaks, stray capitals, `like` and `you know`, numbers written as words, or absence of paragraphs. To measure those, ten dictations were played through the pipeline in real time and compared with the ideal transcript used as the edited reference.

The score is the character error rate of the _formatted_ text after whitespace normalization, so casing, punctuation, numerals, and paragraph breaks all count. [`DictationSetBenchmarkTests`](Tests/LocalTranscriberTests/DictationSetBenchmarkTests.swift) also reports a content WER on lowercased, punctuation-free words, sentence-boundary, comma, and paragraph F1, casing agreement, and how many of the reference's numerals appear in the output. The prompt, the safety checks, and the rule-based steps were tuned against this set, and three cleanup models were compared on the same captured Parakeet output:

| Cleanup model                                    | Formatted error rate | Content WER | Sentence F1 | Fn release → final text, four recordings above |
| ------------------------------------------------ | -------------------: | ----------: | ----------: | ---------------------------------------------- |
| None (raw Parakeet after the rule-based cleanup) |                0.111 |       0.138 |           — | —                                              |
| Qwen3 0.6B, 4-bit (shipped)                      |            **0.093** |   **0.116** |       0.854 | 0.70 / 1.67 / 0.91 / 1.70 s                    |
| Qwen3 1.7B, 4-bit                                |                0.090 |       0.117 |       0.847 | 0.72 / 0.99 / 0.95 / 1.57 s                    |
| Qwen3.5 2B, 4-bit                                |                0.086 |       0.111 |       0.861 | 1.19 / 1.52 / 1.46 / 4.18 s                    |

What worked, for all three models:

- Numbers: dates, durations, percentages, decimals, and phone numbers read digit by digit come out as numerals (`the twenty eighth` → `the 28th`, `zero percent` → `0%`, `twenty four hours` → `24 hours`). On the recording built around dates and phone numbers the formatted error rate fell from 0.234 to 0.093.
- Stutters, echoes, and partial words are removed, and spoken self-corrections are applied.
- False starts are removed when the speaker abandons a phrase and restarts it, which the safety checks allow only for short runs that begin like speech and are followed by the start of a clause.
- Hedging `like` and parenthetical `you know` are removed by rules, because none of the models removed them reliably on their own.
- Quoted speech gets quotation marks, questions get question marks, and stray capitals inside a sentence are fixed.

What did not work, or only partly:

- Sentence-opening connectives (`and`, `so`, `because`, `but`) mostly stay. All three models are conservative here, and rule-based removal agreed with the reference in only 60–70% of cases, so it was left to the model.
- The reference rewrites grammar (`send` → `sent`, `we'll send` → `will be sent`) and turns spoken enumerations into numbered or bulleted lists. The pipeline does neither by design: it never replaces a recognized word, and it returns prose.
- Names the recognizer got wrong stay wrong, as intended.

The larger models edit a little more thoroughly, and the 2B model produced the best text on most recordings. The 0.6B model stays the default because it is the fastest and lightest (the 2B more than doubles that time on difficult recording) and because its output is now close enough that the remaining gap is small. Any MLX text model can be tried on the same benchmark with `WORDMATE_POST_PROCESSING_MODEL_ID`.

### Test machine

| Item           | Value                        |
| -------------- | ---------------------------- |
| Mac            | MacBook Apple M4 Max         |
| CPU and memory | 16 logical cores and 128 GiB |

## Code guide

- [`Audio/`](Sources/LocalTranscriber/Audio) keeps and converts microphone audio.
- [`ParakeetEngine.swift`](Sources/LocalTranscriber/Transcription/ParakeetEngine.swift) loads Parakeet, runs the cumulative checkpoints, decides which sentences are committed, and produces the final transcript.
- [`StreamingTranscriptPolisher.swift`](Sources/LocalTranscriber/Transcription/StreamingTranscriptPolisher.swift) queues committed sentences for Qwen, tracks which sentences were already sent, and reuses their results at release.
- [`TranscriptPostProcessor.swift`](Sources/LocalTranscriber/Transcription/TranscriptPostProcessor.swift) runs Qwen with the shared prompt cache, records every call for diagnostics, and checks each answer.
- [`TranscriptCleaner.swift`](Sources/LocalTranscriber/Transcription/TranscriptCleaner.swift), [`DiscourseFillerCleaner.swift`](Sources/LocalTranscriber/Transcription/DiscourseFillerCleaner.swift), and [`PartialWordRetryCleaner.swift`](Sources/LocalTranscriber/Transcription/PartialWordRetryCleaner.swift) apply the rule-based cleanup before Qwen.
- [`SpokenNumberFormatter.swift`](Sources/LocalTranscriber/Transcription/SpokenNumberFormatter.swift) and [`ParagraphPlanner.swift`](Sources/LocalTranscriber/Transcription/ParagraphPlanner.swift) write numerals and paragraphs after Qwen.
- [`Tests/`](Tests/LocalTranscriberTests) contains unit tests, model tests, and optional benchmarks.

## Requirements

- Apple silicon Mac
- macOS 14 or newer
- Xcode 16 or newer

## License

The pipeline source is available under the [MIT License](LICENSE).

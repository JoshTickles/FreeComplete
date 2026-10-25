# FreeComplete
_Note: Readme written by local AI model_
> **Pre-release:** FreeComplete is under active development and is not ready for general release. This repository is a development snapshot, not a stable release.
>
> Core autocomplete, power modes and local savings statistics are implemented. Current-build cross-app interaction, sleep/wake, clean-Mac installation and notarized distribution still need verification. Terminal support is optional and unverified. See [the release-polish plan](PLAN.md#current-release-polish-plan) for remaining gates.

FreeComplete is a free, on-device macOS writing assistant. It bundles a public Gemma 4 E2B **base-model i1-Q4_K_M** GGUF and runs it inside the app through a statically linked, pinned llama.cpp (Metal). Autocomplete uses raw token distributions and bounded ranked search, not chat replies. No Ollama process, account, cloud API or subscription is required.

FreeComplete's source is licensed under [Apache 2.0](LICENSE). Bundled dependencies retain their own licenses and notices.

## Build and run

Requires macOS 14+ on Apple Silicon, Swift 6.2, CMake, Apple command-line tools, and about 9 GB of free space during packaging. The build script downloads a hash-checked [public base-model GGUF](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF) and Apache-2.0 license to a build cache, fetches pinned llama.cpp source, builds its static libraries (libllama and ggml with the embedded Metal backend), stages them under `.build/llama` for SwiftPM, links them into the app, packages the model and notices, and signs the app. Signing uses `FREECOMPLETE_SIGN_IDENTITY` when set. Otherwise it uses a code-signing identity named `FreeComplete Local` if one is in your keychain. If neither exists, it uses an ad-hoc signature.

```sh
./scripts/build-app.sh
cp -cR dist/FreeComplete.app /Applications/   # first install only
open /Applications/FreeComplete.app
```

Install into `/Applications` so Spotlight lists it. `cp -c` makes an APFS clone that shares storage with `dist/`, so it uses no extra space. Once installed, each `build-app.sh` run refreshes the `/Applications` copy the same way.

The app is at `dist/FreeComplete.app` (about 3.4 GB). For distribution to other Macs, use an appropriate Developer ID signature and notarization. An ad-hoc signature changes on every build, so macOS drops the app's Accessibility approval and Keychain history access after each rebuild. A self-signed `FreeComplete Local` code-signing certificate gives a stable, certificate-based designated requirement for local use; local and ad-hoc signatures skip hardened runtime and Apple timestamping. After the first switch to a new signing identity, reset the old approval once (`tccutil reset Accessibility app.freecomplete`) and grant it again. The bundled model is Apache-2.0 licensed; third-party notices are in `Licenses/` and in the app's Resources. The model loads inside the app when completions start. There is no helper process, port or network listener.

The llama.cpp source cache is the exact pinned commit; the build rejects local changes to the library sources. The model cache is shared.

### Pre-release packaging

The default app version is `0.1.0`; the build number comes from the commit count. Set `FREECOMPLETE_VERSION` and `FREECOMPLETE_BUILD_NUMBER` explicitly for a release. Set `FREECOMPLETE_INSTALL=0` to build without replacing an installed copy.

```sh
FREECOMPLETE_INSTALL=0 ./scripts/build-app.sh
./scripts/package-release.sh local
```

This produces a versioned `-local-pre-release.zip` under `dist/` and prints its SHA-256. Local packaging does not establish Gatekeeper acceptance on another Mac. The script checks the bundled app license and refuses to overwrite an existing archive. Notarized packages omit `-local` from the name.

For notarized packaging, first build with your existing **Developer ID Application** identity in `FREECOMPLETE_SIGN_IDENTITY`. Then run `FREECOMPLETE_NOTARY_PROFILE=your-existing-profile ./scripts/package-release.sh notarize`. This explicitly uploads the app to Apple using an existing `notarytool` Keychain profile, requires an Accepted result, staples and validates the ticket, checks Gatekeeper, and archives the stapled app. The scripts do not create accounts, certificates or credentials. Test the resulting package on a clean Mac before publishing it. This path remains unverified without those credentials.


## Use

The app has a **FC** menu bar entry with Open, Pause/Resume and Quit actions, plus a Dock-accessible settings window with Home, Writing, Apps and Privacy tabs. The menu shows confirmed continuation accepts and inserted characters; selection replacements appear separately. Menu bar managers such as Ice may hide the FC item; click the Dock icon to reopen settings. Home has a **real model** test editor. The first generation loads the model and can take longer. For suggestions in other apps, grant FreeComplete Accessibility access in macOS System Settings using the explicit button in Home if it is not already granted. The app reads cursor context through Accessibility, skips secure text fields, and verifies focused target and text again before insertion. Some apps do not expose the necessary editable-text Accessibility attributes and will not show suggestions. Apps that expose only an entire AX value may require reading it to extract the bounded cursor window.

Continuations appear inline as gray text after the caret, in the field's font scaled to its line height. Only whole acceptance chunks that fit inside the field and screen are shown; a wrapped continuation must fit vertically too. Alternatives, synonyms and corrections use a labelled panel. Performance mode prepares the next continuation in advance. Battery Saver starts it only after acceptance. Rapid Tab/grave presses immediately after acceptance are held briefly for the expected continuation; an empty result, focus change or timeout releases that ownership. Ordinary Tab remains available when no suggestion or owned continuation exists.

Electron apps such as Slack, Ferdium, Discord and VS Code hide their text fields from Accessibility by default. When one of them comes to the front, FreeComplete sets Electron's documented `AXManualAccessibility` switch on it, which makes the app build its accessibility tree, and then reads the field again. Other apps ignore the attribute.

Opt-in screen context captures only the window that holds the focused field (never the menu bar, the desktop or other apps), cropped to the column around the field: the conversation or document you are replying to, not sidebars or the menu bar. It uses accurate OCR, removes the field's own text, chat timestamps, number-only and low-confidence fragments, rebuilds visual lines in reading order, and keeps the 1,200 characters nearest the caret. Recognition runs in the background (about 0.65 s on a test screen) and suggestions use the latest result, so they never wait for OCR. While the visible suggestion was built with screen text, the FC menu bar icon changes to an eye. The Home tab's **Screen context** section shows the source app, the capture age, and the exact text the model received.

- **Tab:** accept the next word (unless Option is held).
- **` (grave):** accept the entire suggestion.
- **Esc:** dismiss temporarily.
- **Control+Option+`:** request three alternative next words, then press **1–3** or Tab to insert one. All three fill the same slot: either new next words, or endings for the word being typed. Choices that start with brackets, quotes or markup are skipped.
- Select one word and press **Control+Option+S** for a contextual synonym. Select text and press **Control+Option+C** for a spelling/grammar correction. Tab or grave replaces the selection.

Settings include a global enable switch, maximum suggestion length, spacing, global instructions, per-app and per-website enable/learning/instructions, and optional screen OCR or clipboard context. Website rules use HTTP(S) document URLs exposed through Accessibility, including known enclosing frames; a parent-domain exclusion cannot be overridden by a subdomain. If a web field's outer URL cannot be established, configured suggestion and recording exclusions fail closed independently. Observed app and website names appear in settings only for this session; only rules you configure are saved. Screen OCR requires separate Screen Recording permission and captures the focused window's field column; it is suspended entirely while any website has an exclusion so another visible browser window cannot bypass it. Clipboard and screen text are used only when enabled, on this Mac, and not saved; concealed/transient clipboard items are skipped. macOS may ask before clipboard access. Writing history is off by default. With explicit opt-in, short samples from accepted completions are AES-GCM encrypted with a Keychain key; an additional off-by-default switch also records monitored writing after a pause or when leaving a field. Text under 40 characters is skipped. History is scoped by app and website, capped at 2,000 samples of at most 200 characters, and clearable from Privacy. Vocabulary influence can be turned off or adjusted, and app/website recording can be disabled independently.

Password managers (1Password, Bitwarden, Apple Passwords, Dashlane, LastPass, Keeper, Proton Pass, KeePassXC) and terminals (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, WezTerm) start with suggestions, learning and screen capture off. Enable one in the Apps tab to override the default.

Terminal support is not verified. FreeComplete requires readable Accessibility text and a reported caret position. It does not reconstruct the active input or guess the caret from screenshot text. Custom-drawn terminal panes without those values receive no suggestions. The experimental terminal OCR path was removed after a controlled image probe showed that it treated an entire OCR fragment, including text after the caret, as input before the caret.

### Power and savings

Home exposes **Automatic**, **Performance** and **Battery Saver**. Automatic selects Battery Saver on battery power or in macOS Low Power Mode, and Performance on AC power. An unavailable power-source reading selects Battery Saver with an explicit explanation. Performance preloads the model and prepares follow-on suggestions. Battery Saver uses a 120 ms typing debounce rather than 30 ms, skips speculative work, and unloads after 60 seconds without an active inference request. The next request reloads the model. All modes keep the same model and generation quality settings. These controls reduce configured background work; measured battery-life improvement is not yet established.

**Typing savings** shows Today, Last 7 Days (today plus six calendar days), and All Time. Counts include confirmed continuation accepts and inserted Unicode characters, including whitespace. Replacements have separate counts and do not contribute to the typing-time estimate. An insertion counts only when Accessibility reports the expected field, text and caret. Missing readback or an intervening edit can leave it uncounted. Displayed suggestions and rejected insertions do not count.

The estimate uses five characters per nominal word and an adjustable typing speed. It measures equivalent typing time, not net time saved; reading and decision time are excluded. The store contains daily aggregate counts, not writing or app identities. It keeps the time zone shown in Home from when tracking starts, including across travel. All days remain until a confirmed manual reset, which starts tracking in the current time zone. Old lifetime word counters are preserved separately, not converted into new metrics. Unreadable statistics are preserved and shown as unavailable until explicit reset. Optional writing history and diagnostic tracing remain separate from these aggregates. Diagnostic tracing is off by default and can include generated and accepted text; trace files use owner-only permissions.

### Suggestion quality

Autocomplete keeps bounded before-caret writing separate from prompt references. It reconstructs up to five eligible source-tail tokens without changing typed bytes, then ranks a frontier of at most nine sequences. A separate unmasked model likelihood penalizes improbable prefix reconstructions; post-prefix ranking sums retained log probabilities. A pending prefix uses a relative probability gate instead of the ordinary 0.05 gate. Alternatives come from distinct ranked next words; selected-text rewrites use separate raw tasks. Search retains up to twenty candidates per expansion and nine sequences in its frontier, and delivers only confirmed words.

Continuation uses a neutral, descriptive prompt: a short preface, labelled optional context (app, website, vocabulary, screen, clipboard, text after the cursor), the writer's preferences nearest the writing, then the raw writing last. It does not use chat-style instructions. With the public base model, instruction framing gave about a quarter of the probability to placeholder tokens such as `...` and `[`, so the generic “The next step for this project is” returned ` to...`. Search runs one generation round per allowed word (four by default), after any source-prefix reconstruction, and delivers only confirmed words. A suggestion must contain a letter or digit, and suggestions appear only when the caret is at the end of its line.

The prompt uses the last 2400 characters before the caret and the first 900 characters after it. Opt-in screen and clipboard references each use their first 1200 characters. These are deliberate context windows, not complete-document coverage. Selected correction text and user instructions are not shortened by these windows.
Focused app metadata uses the first 100 characters of the app name and 200 characters of the app identifier. Learned vocabulary uses up to 200 characters per strength level, with an 800-character ceiling.

Prefix-finishing tokens pay their entire original likelihood, including any new suffix. Pending and prefix-complete paths share a bounded beam, so tokenization and pruning can affect which completion survives. A malformed or missing likelihood rejects the whole prefix distribution. The bounded regeneration budget can also end before an alternate byte-tokenization finishes. These are explicit limits, not fallback scores or complete search coverage.
While generation is active, opening brackets or opening quotation marks do not confirm a finished word. A colon after a digit also remains unfinished because a time or ratio can continue. Whitespace and EOS still confirm literal punctuation; these boundaries do not filter citations or repair model meaning.
Fallbacks retain only confirmed text and use the evaluated branch's current score, not its earlier checkpoint score. Budget, suppression and terminal fallbacks therefore cannot revive a stale higher rank and violate the settled-result bound. Below-limit checkpoints do not compete immediately with their longer descendants.

Search branches are llama.cpp KV-cache sequences in one 8192-token unified context. Each round decodes every branch's new token in a single batch; a branch is created by copying its parent's sequence (cells are shared, not duplicated). The previous prompt stays cached, so a keystroke re-evaluates only the changed tail. Byte-prefix masks and unmasked full-vocabulary log probabilities are computed in-process from the logits. A 2026-10-26 production-source smoke returned four warm English continuations in 83–87 ms after a 3.80 s first request. These are model timings, not end-to-end UI latency or a general quality benchmark. Field reads, policy debounce, rendering and cold reload add latency.

Screen OCR, clipboard context and encrypted writing history remain off until you opt in. A fragment such as “The next step for this project is” supplies no project facts, so generic suggestions remain possible. Optional screen context and global/app/website instructions can supply relevant facts, but the current model can ignore explicit instructions or prefer conflicting reference text. Learning contributes frequent vocabulary terms, not a derived tone/style profile.

Corrections encode the complete selection as a JSON string, separate from prompt labels and stop markers. Independently authored editing pairs demonstrate minimal edits while preserving literal labels, repeated text, language, whitespace and Unicode spelling. The runtime accepts only a complete JSON-string replacement, preserves the selection's leading/trailing whitespace, and does not offer an unchanged source. The 8192-token context limit includes the full instructions, selected text and output reserve; oversized requests fail explicitly rather than silently deleting input. These checks prevent representation truncation, not model mistakes. Review a proposed correction before accepting it.

Real production diagnostics stop the tested year and compound chains and preserve `determinis` and `extraor` completion. Corrections preserve tested padding, repeated text, tabs, blank lines and decomposed Unicode, but do not reliably fix every error. Some literal-label/tabbed samples retain one agreement error; a French sample retains an adjective agreement error; Japanese past/future errors can remain unchanged. A longer repeated quoted-path selection makes the model repeat beyond the source and reach its output limit without a complete JSON string; FreeComplete rejects the result and preserves the selection. French continuation instructions are still ignored, Japanese continuations can end at an incomplete grammatical span, and alternatives remain weak. Suggestion quality still needs broader validation before release.

## Checks and limits

```sh
./scripts/test-prediction.sh
./scripts/test-release.sh
swift build -c release
```

The release checks exercise savings persistence, date and overflow boundaries, power-policy selection, confirmed insertion identity, acceptance deadline cancellation/replacement, and screen-context identity/freshness. They do not drive the macOS UI.

After building the native libraries, run the opt-in real-model lifecycle checks with a local copy of the pinned public model:

```sh
./scripts/test-inference.sh /path/to/model.gguf
```

These checks run generation, repeated stop, model reload, cancellation/recovery, cancelled-preload readiness, unload during model loading and idle release across request boundaries in separate processes with clean exits. They do not grant permissions, read user text fields or control another app. Idle/lifecycle unload retires the session and queues native cleanup without waiting on the UI actor. A new request cannot use a retired session. Final process termination still drains queued native work synchronously, so a long in-progress rewrite can delay quitting.

The test runner checks bounded multi-token source rewind, exact Unicode bytes, prefix/ordinary Float32 gate boundaries, production candidate decoding and validation, raw prefix consumption with surplus preservation, phase-aware ranking, stable byte-constraint grouping, indexed response mapping and rejection without partial mutation, aggregate context capacity and overflow, raw partial-word and multilingual word-boundary insertion, alternative identity/spacing, punctuation, correction JSON completeness and selection whitespace, synonym selection eligibility, website parsing, nested-frame exclusions, unknown-site fail-closed behavior, and absence of unconsented context. The built-in editor exercises bundled model generation without Accessibility. Actual cross-app observation/insertion and screen OCR require the corresponding macOS permissions and separate verification. [PLAN.md](PLAN.md) distinguishes earlier exercised UI behavior from current-build verification.

# Changelog

## [0.11.1] - 2026-09-13

### Fixed
- **Z-Image, FLUX.2, and Krea-2 models couldn't load**: every registered
  image model was loaded through mflux's FLUX.1-only pipeline
  (`Flux1`), which expects a second `text_encoder_2` (T5) folder none
  of those three families ship — surfacing as "No safetensors files
  found in .../text_encoder_2" (or similar) the first time anyone
  actually generated with one. `ImageServerScript`'s `build_pipeline()`
  now detects a registered model's real family from its folder name
  and routes to that family's own mflux class (`ZImage`, `Flux2Klein`,
  `Krea2`) instead. Verified for real against a downloaded Z-Image
  Turbo model — loaded and generated a real image; FLUX.2/Krea-2 were
  verified by reading the installed `mflux` package's own source, not
  a live download. Full writeup: `docs/image-model-loading.md`.

### Added
- **A real app icon**, Mac and iOS both: a commissioned image (gold
  anvil, circuit-branch flourish) baked into a proper `.icns`
  (`Resources/Anvil.icns`, referenced via `CFBundleIconFile`) for the
  Mac app, and a single 1024×1024 universal `AppIcon.appiconset` for
  AnvilIOS. Neither platform had a real icon before this.

## [0.11.0] - 2026-09-13

### Added
- **Editable conversation titles**: a thread's title now defaults to
  "Profile name · created date" (or "New Chat · date" with no profile)
  instead of the first message's text, stays in sync with the profile
  until you type your own title in Chat's header, and is locked in for
  good the moment you do.

### Changed
- **Chat's right-hand panel is leaner**: "New Thread", "Chat History…",
  and "Clear Conversation" are gone — the threads column and its own
  delete button already cover them. The standalone "Chat History…"
  window is removed entirely.
- **Temporary Chat moved to the composer**: the toggle now lives next
  to the message field (an icon button) instead of the sidebar, and is
  disabled the moment the thread has a first message — matching how a
  thread's Profile already locks at that point.
- **iPhone Sync and iCloud Sync moved to the global top bar**: both were
  chat-specific settings that were actually app-wide. Their icons now
  sit to the left of the app version (iPhone, then iCloud), each
  opening a popover with the same controls the Chat sidebar used to
  carry.
- **Popping a conversation out into its own window now actually
  detaches it**: the main window's conversation pane goes blank (only
  the threads column stays usable there) while the popout has the
  conversation plus its settings panel, always shown. Closing the
  popout window is what brings the main window's pane back.

## [0.10.0] - 2026-09-13

### Added
- **Threads column in Chat (Mac)**: a persistent left-hand list of every
  open conversation, for navigation — saved threads and in-session
  temporary ones alike (the latter drop off once the app quits, since
  they're never written to disk). Shows title, preview, and highlights
  the active thread; a "+" starts a new thread from the column itself,
  a trash icon deletes one in place. Toggle it with the new sidebar
  icon in Chat's header (on by default). The existing "Chat History…"
  popout window is unchanged for anyone who prefers a separate window.

## [0.9.0-ios-phase1] - 2026-09-11

### Added
- **iOS Phase 1**: the first real iOS milestone — scaffolded via
  XcodeGen, code-signed with a real Apple Development certificate,
  installed and launched on a physical iPhone (confirmed via
  `xcrun devicectl`). Deliberately doesn't share `AnvilCore` yet —
  its Requirements/Serving layers are built around `Foundation.Process`
  (a private Python venv, subprocess servers), unavailable on iOS. This
  phase's whole job was proving the Xcode/signing/device-install
  pipeline works end to end, which it now does.

## [0.8.2] - 2026-09-11

### Fixed
- **A download nearly 3× the size it needed to be**: repos that ship a
  redundant root-level copy of their weights (alongside the real
  pipeline subfolders `mflux` actually loads) no longer download that
  duplicate — confirmed real ~24GB→~16GB fix on `FLUX.2-klein-4B`.
  `ModelDownloader` skips a root-level weight file only when
  `model_index.json` confirms a real pipeline exists in the
  subfolders, never touching anything inside a component subfolder.

## [0.8.1] - 2026-09-11

### Fixed
- **`package-dmg.sh`**: asks `swift build --show-bin-path` for the
  release binary's location instead of guessing a path shape, so it
  stays correct across build-system backends (Xcode's native backend
  puts it somewhere different than the older `swiftbuild` one did).

## [0.8.0] - 2026-09-11

### Added
- **HF compatibility filter**: `ModelCompatibility` classifies a
  Hugging Face search result from its own file list — flags a flat
  single-file checkpoint with no pipeline structure as incompatible
  instead of letting it fail later at load time (the exact shape that
  broke on `FLUX.2-klein-4b-nvfp4`). "Compatible only" filter on by
  default in Models.
- **CivitAI search & download**: a source picker in Models switches
  between Hugging Face and CivitAI, sharing one download queue so the
  two sources never download simultaneously. CivitAI checkpoints
  register but can't load yet (no single-file loading path in
  `mflux`) — the UI says so plainly rather than implying it works.

### Fixed
- **Downloads disappearing from Models**: switching tabs mid-download
  and back used to lose the visible progress — `ModelManagerViewModel`
  was view-local and torn down on navigation, even though the download
  itself kept running regardless. Moved into `AppState`, shared like
  `ChatViewModel` already was.

## [0.7.4-real-sync-fixes] - 2026-09-13

### Fixed
- **Three real sync bugs, root-caused live**: `ChatViewModel` and
  `AnvilSyncServer` held separate `ChatThreadStore` instances (a reply
  saved on one side was invisible to the other); every `upsert`
  re-stamped `updatedAt` to "now" even on pure replication, letting a
  stale copy win a recency race against genuinely newer content; and
  LAN sync's merge couldn't tell "never existed on the other device"
  apart from "existed, then was deleted," so a delete kept getting
  resurrected a few seconds later. Fixed with a shared store instance,
  a timestamp-preserving upsert path for every sync/merge write, and
  real per-store deletion tombstones. 114/114 tests passing.

## [0.7.3-icloud-sync-fixes] - 2026-09-13

### Fixed
- **Assistant replies lost across relaunch**: `CloudSyncEngine` never
  persisted `CKSyncEngine`'s own sync state between launches, so a
  reply that hadn't finished uploading yet was silently dropped for
  good if the app quit first. Now persists
  `CKSyncEngine.State.Serialization` and reloads it on every `start()`.
- **Deletes never left the Mac**: `ChatViewModel.deleteThread` deleted
  locally but never told `CloudSyncEngine` — iOS's own delete already
  did; the Mac side was simply missing the call.

## [0.7.2-mac-icloud-working] - 2026-09-13

### Fixed
- **CloudKit entitlement denial**: a hand-signed `codesign
  --entitlements` build doesn't get `com.apple.application-identifier`
  auto-injected the way Xcode's own build system does, so `cloudd`
  rejected every CloudKit call outright ("Couldn't check iCloud
  account status" in the app's own UI). Added the entitlement
  explicitly.

## [0.7.1-mac-icloud-provisioning-fix] - 2026-09-12

### Fixed
- **Mac app couldn't launch at all** once the iCloud entitlement was
  added: a Developer-ID-signed app declaring the iCloud/CloudKit
  entitlement needs a matching embedded provisioning profile for
  AMFI/launchd to allow it to even spawn. Registered a real macOS App
  ID and downloaded/embedded its Developer ID provisioning profile.

## [0.7.0-ios-mac-chat-parity] - 2026-09-12

### Added
- **iOS: a Mac source governs Chat/Profiles/Memory together**: picking
  a Mac as the active source (`AnvilSyncClient`, talking to the Mac's
  `AnvilSyncServer`) now switches Chat, Profiles, and Memory together
  from one place, so all three tabs see the exact same thread/profile/
  memory state instead of drifting independently.

## [0.7.0] - 2026-09-11

### Added
- **Real download progress + a real queue**: parses tqdm's own
  `\r`-updating percentage instead of losing it to line-buffering; a
  second download started while one is in progress now queues instead
  of silently doing nothing.
- **Draw-Things-style image version history**: every generated image
  belongs to a lineage; regenerating from an already-selected image
  adds a new version to it instead of overwriting, with a
  version-history carousel in the detail view.
- **Prompt to Model tab**: describe an image idea once, get a tailored,
  editable prompt per registered image model, each with its own
  Generate button.

## [0.6.7-ios-bonjour-discovery] - 2026-09-12

### Fixed
- **iOS Mac discovery found nothing**: the blind subnet sweep (254
  hosts × 20 ports, ~5,000 simultaneous requests) was flooding
  `URLSession`'s own connection queue. Now finds the Mac via Bonjour
  (`_device-info._tcp`) first, falling back to a bounded-concurrency
  sweep only if that finds nothing.

## [0.6.7] - 2026-09-12

### Fixed
- **20KB Corrupted Download Fix**: `URLDownloader` now validates HTTP status codes `200...299`, rejecting 401/404 server error bodies from ever being written as model files.
- **Curated Verified Working Hub**: Replaced inaccessible Draw Things repo entries with verified working `mflux-community` models (FLUX.1 Schnell, FLUX.1 Dev, FLUX.2 Klein 4B/9B, Krea Turbo, Z-Image Turbo) with complete pipelines.
- **Standalone Model Error Handling**: Clear diagnostic message explaining missing pipeline components when trying to load raw single-file transformer weights without VAE/text encoders.

## [0.6.6] - 2026-09-12

### Fixed & Improved
- **Clean Draw Things Search Filtering**: Excludes unrunnable shards and loose raw safetensors fragments, filtering results strictly to 1-file runnable checkpoints (`.ckpt`, `.nnc`) and complete packages.
- **Search Clear Buttons**: Added "Clear" buttons to all search bars (Hugging Face, CivitAI, Draw Things) to quickly reset search fields and reveal registered models.
- **Standalone Image Checkpoint Loading**: Added automatic base model fallback resolution when loading standalone flat FLUX transformer checkpoints without local diffusers subfolders.

## [0.6.5] - 2026-09-12

### Added
- **Per-Quantization Model Variants in Draw Things**: FLUX.1 Schnell, FLUX.1 Dev, SDXL, and community repos now list each quantization (8-bit, 4-bit, 3-bit, 2-bit) separately with its exact file size and popularity.
- **Single-File Targeted Downloading**: Downloading a Draw Things model now fetches only the chosen quantization file instead of entire repositories.
- **Broad Multi-Query Search**: Searches official `drawthingsai` models and community checkpoints across Hugging Face matching user queries.

## [0.6.4] - 2026-09-12

### Added
- **Draw Things Official Catalog Search**: Integrated a dedicated 3rd search source in Model Manager to search and download official Draw Things community models (Flux 8-bit/4-bit/3-bit, SDXL, SD 1.5).
- **Draw Things Engine (`InferenceEngine.drawThings`)**: Support for `.ckpt` and `.nnc` image model quantizations.
- **Engine Override for Image Models**: Model gear popover allows overriding image engine between `Auto`, `mflux`, and `Draw Things (libnnc)`.

## [0.5.16] - 2026-09-12

### Added
- **Multi-Engine Runtime (`InferenceEngine`)**: Native support for GGUF models via `llama.cpp` (`llama-cpp-python` / `llama_cpp.server` with full Metal GPU acceleration) alongside native Apple Silicon MLX (`mlx_lm.server`).
- **Real-Time Compatibility Badges**: Model search now tags compatible Hugging Face & local models with clear green badges indicating the engine (`MLX`, `llama.cpp`, `mflux`) and red badges for incompatible formats.
- **Inference Engine Selector**: Model gear settings allow user override between `Auto`, `MLX`, and `llama.cpp`.
- **Fair Multi-Model KV Cache Partitioning**: ResidencyPlanner partitions the available memory budget fairly across all active text model instances.

## [0.5.15] - 2026-09-12

### Changed

- Added the current app version/build number to the top-right global navigation bar.
- Added `Created by Vinicius Cotrim` attribution to the main app header.

## [0.5.14] - 2026-09-12

### Fixed

- Fixed model switching in Chat and Code through the gateway for local/imported models.
- Registry IDs remain route selectors but are no longer forwarded to `mlx-lm` as Hugging Face repo IDs.

## [0.5.13] - 2026-09-12

### Added

- Reviewable automatic memory suggestions from the current bounded thread.
- Suggestions include category, confidence, and rationale.
- Accepting a suggestion stores it as an inferred memory scoped to the active Profile.
- Dismissing a suggestion leaves no persisted data.

## [0.5.12] - 2026-09-12

### Added

- Dedicated local Memory window linked from Chat.
- Auditable memory categories: fact, preference, date, number, and impression.
- Memory source labels: explicitly told by the user versus inferred.
- Optional confidence and Profile scope for each memory.
- Per-response memory provenance indicator showing memories used and created.
- Legacy memory and transcript files remain readable with safe defaults.

## [0.5.11] - 2026-09-12

### Improved

- Context budget is now configurable from Chat's sidebar (`512` to `128000` estimated tokens).
- Recent-turn retention is configurable from `2` to `100` messages.
- Chat header reports the estimated context size used by the latest request.
- Context settings persist locally and old settings files receive compatible defaults.

## [0.5.10] - 2026-09-12

### Added

- Offline durable memory store at `Application Support/Anvil/chats/memories.json`.
- Chat sidebar controls to add and delete durable facts/preferences.
- Bounded context builder preserving the first user turn and recent turns.
- Durable memories are injected as background facts alongside the Profile prompt.
- Image-tool follow-up requests use the same bounded context policy.

## [0.5.9] - 2026-09-12

### Fixed

- Code terminal tools now stop after 120 seconds instead of holding an agent round indefinitely.
- Chat and Code History rows now use explicit selectable buttons, fixing thread resume clicks that appeared to do nothing.
- Chat temporary threads remain accessible in memory for the entire Anvil session and can be switched without being persisted.
- Chat History remains usable while a temporary thread is active.

## [0.5.8] - 2026-09-12

### Fixed

- Code-agent reasoning deltas are now retained and rendered instead of being silently discarded.
- Code now reports whether it is thinking, writing, running tools, or waiting for approval.
- Empty assistant placeholders are removed after Code-agent failures.
- Cancellation and failure states are visible instead of looking like an idle low-memory process.

## [0.5.7] - 2026-09-12

### Added

- Configurable Chat composer quiet period, defaulting to 10 seconds.
- Enter now adds a message block when batching is enabled.
- New typing restarts the quiet-period timer; the Send button still sends immediately.
- `0` seconds disables batching and restores direct send behavior.
- Composer shows when it is waiting for more text.

## [0.5.6] - 2026-09-12

### Improved

- Added explicit chat generation phases for preparing, reasoning, response generation, image generation, cancellation, and failure.
- Prevented premature cut-off messaging while a reasoning response is still streaming.
- Improved error dismissal and removal of empty assistant placeholders after failures.
- Displayed the effective token budget in the Chat settings.
- Persisted the selected Profile name as the assistant identity in chat history.

## [0.5.5] - 2026-09-12

### Fixed

- Fixed `incomplete http request` when the gateway receives an HTTP header and body in separate TCP reads.

## [0.5.4] - 2026-09-12

### Fixed

- Prevented model routes from becoming ready before `/v1/models` responds.
- Added transient upstream retries in the local gateway.
- Chat errors now include the upstream response body, making Profile/template failures diagnosable.

## [0.5.3] - 2026-09-12

### Fixed

- Fixed an `EXC_BAD_ACCESS` crash while loading models when sampling child-process RSS.
- Added a regression test for the Darwin `proc_pid_rusage` buffer bridge.

## [0.5.2] - 2026-09-12

### Fixed

- Large text models are no longer rejected because of the full optional KV-cache budget.
- KV-cache capacity now adapts to the memory remaining after model weights are reserved (`2G`, `1G`, `512M`, or `256M`).
- Added a regression test covering a Qwen-sized model on a 24 GB Mac.

## [0.5.1] - 2026-09-12

### Added

- Local OpenAI-compatible gateway on `127.0.0.1:8000` with model-aware routing.
- Shared unified-memory residency planner for text and image sessions.
- Real RSS measurement for managed model processes.
- Prefix KV-cache configuration for `mlx-lm` with bounded cache size and bytes.
- Optional `conversation_id` propagation for chat and code-agent requests.
- Chat streaming cancellation and cached prompt-token telemetry.
- Local image responses without unnecessary base64 duplication.
- Startup log readiness signals with HTTP fallback.
- Gateway, residency, and wire-contract tests.

### Changed

- Internal text model servers use ports starting at `8100`; port `8000` is reserved for the gateway.
- Model reservations include runtime and KV-cache headroom.
- The watchdog checks for orphaned processes every 200 ms.

### Validation

- `swift test` passes on macOS arm64.
- Release artifact is signed with the configured Developer ID certificate.
- Notarization remains a separate credentialed Apple step.

### Known limitations

- End-to-end validation with a real downloaded `mlx-lm` runtime is still required on the target Mac.
- KV cache reuse is prefix-based through `mlx-lm`'s server cache; `conversation_id` is a routing and observability hint, not a Python-side session map.
- Voice, macOS-native `mlx-swift` runtime, and CivitAI single-file loading remain outside this release.

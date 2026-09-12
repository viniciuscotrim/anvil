# Changelog

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

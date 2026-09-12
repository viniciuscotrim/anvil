# Changelog

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

# Changelog

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

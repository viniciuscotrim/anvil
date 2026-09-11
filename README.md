# Anvil

A single native macOS app that replaces three separate pieces of a local-LLM
stack — **oMLX** (LLM serving), **Draw Things** (image generation), and a
standalone Flask image server — with one from-scratch app: download or import
models, run text + image + voice models concurrently, and chat by voice.
No terminal, no manual dependency setup, ever.

Full spec: [docs/build-brief.md](docs/build-brief.md).

## Status

Build is in progress, phase by phase, each gated on a real pass/fail check
before moving on (see the brief for exact gates).

- [x] **Phase 1 — Requirements Manager**: check/install framework, private
      `uv` + Python venv bootstrap, lazy per-choice dependency installs.
      Core logic + unit tests in place; full on-device gate (clean account,
      zero terminal windows, timed install) still to be run.
- [x] **Phase 2 — Model manager**: HF search (native REST call, no Python
      needed just to browse), download via `huggingface_hub.snapshot_download`,
      local import (register an existing folder without re-fetching it),
      all backed by one JSON model registry. Gate run for real on this Mac:
      cold download of `mlx-community/SmolLM2-135M-Instruct-8bit` +
      import of a separately-downloaded folder simulating an existing
      oMLX model directory, both landing in the printed registry (see
      `swift run Anvil -- --phase2-gate`).
- [~] **Phase 3 — LLM serving (in progress)**: `LLMServer` drives a real
      `mlx_lm.server` subprocess (the same `/v1/chat/completions` +
      `/v1/models` shape oMLX serves), `ChatClient` talks to it, and
      there's now an actual in-app chat window — pick a registered
      model, it loads, you talk to it. Verified for real on this Mac
      (`swift run Anvil -- --phase3-gate`): real model loaded, real
      `/v1/chat/completions` round trip, correct reply. **Not done yet**:
      the brief's actual gate — the Sofia persona proxy (:8003) getting
      a valid response through this backend with zero changes on its
      side, then retiring oMLX. That's a deliberate, separate step since
      it touches the live stack; not taken until asked for.
- [ ] Phase 4 — Image generation (Draw Things / flux_server.py replacement)
- [ ] Phase 5 — Concurrent multi-model residency
- [ ] Phase 6 — Voice chat

## Architecture

- Single SwiftUI macOS app (`Anvil` target), built with Swift Package Manager
  — no Xcode project file, everything is scriptable from the terminal.
- `AnvilCore` (library target): all non-UI logic — dependency bootstrap,
  Python/venv management, (soon) model registry and API server orchestration.
  Kept separate from the `Anvil` executable target so it's unit-testable
  without a UI.
- The app owns a private runtime under
  `~/Library/Application Support/Anvil/` — its own `uv` binary, Python venv,
  and downloaded models (`models/`, with `models/registry.json` as the
  single source of truth for what's registered). It never touches the
  system Python or Homebrew.
- Backend Python process (spawned by the app, never a visible terminal)
  serves an OpenAI-compatible API on port 8000 — a drop-in replacement for
  the existing persona proxies, no config changes on their side.
- Each phase gate is confirmed by an inspectable artifact, not just "it
  looked fine in the UI" — `Anvil -- --<phaseN>-gate` runs the phase's
  gate headlessly (no window) and prints the resulting state as JSON.
  `--phase2-gate` downloads one model cold and, if `ANVIL_GATE_IMPORT_PATH`
  is set, imports that folder too, then prints the model registry.

## Building

Requires only Xcode Command Line Tools (no full Xcode.app needed):

```bash
swift build
swift run Anvil
```

Tests need one extra flag on this toolchain (see note below):

```bash
swift test --build-system native -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

### Toolchain notes (Command Line Tools only, no Xcode.app)

Two real gaps to know about if you hit build errors, both worked around
already in the code/commands above — neither needs Xcode.app installed:

- **`@State` doesn't compile.** On this SDK, `@State`'s macro
  implementation ships only inside Xcode.app, not the Command Line Tools.
  `@StateObject` + a small `ObservableObject` (plain Combine, no macro)
  works fine and is what `BootstrapView` uses — keep using that pattern
  for view-local state instead of `@State`. `@Binding` and `@Observable`
  were confirmed to compile fine.
- **`swift test` needs `--build-system native` plus an explicit `-F` path.**
  The default `swiftbuild` build system doesn't pass swift-testing's macro
  plugin path into one of its build passes for this target, so `@Test`/
  `#expect` fail to resolve. The older native build system doesn't have
  that bug, but doesn't auto-discover `Testing.framework` either, hence
  the explicit `-F` flag above. `swift build`/`swift run` for the app
  itself are unaffected — only `swift test` needs this.

## Packaging a signed, notarized .dmg

```bash
scripts/package-dmg.sh              # build, bundle, sign the .app and the .dmg
scripts/notarize-dmg.sh dist/Anvil-<version>.dmg   # submit, wait, staple
```

`package-dmg.sh` needs the `Developer ID Application: Vinicius Luciano
Menezes Cotrim (U3H5DHZP65)` certificate in the login keychain (already
there on this Mac) — no credentials needed, it's a local signing
operation. `notarize-dmg.sh` needs a one-time keychain credential
profile only the account holder can create (Apple ID + app-specific
password, or an API key) — see the comment at the top of that script.
Once that profile exists, notarization is fully scriptable from then on.

## Repo conventions

- `main` is always buildable and testable (`swift build && swift test`).
- One commit (or a short series) per meaningful step within a phase; a
  tagged release once a phase's gate genuinely passes on this Mac.

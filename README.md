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
- [ ] Phase 2 — Model manager (HF download + local import)
- [ ] Phase 3 — LLM serving on port 8000 (oMLX replacement)
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
  `~/Library/Application Support/Anvil/` — its own `uv` binary and Python
  venv. It never touches the system Python or Homebrew.
- Backend Python process (spawned by the app, never a visible terminal)
  serves an OpenAI-compatible API on port 8000 — a drop-in replacement for
  the existing persona proxies, no config changes on their side.

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

## Repo conventions

- `main` is always buildable and testable (`swift build && swift test`).
- One commit (or a short series) per meaningful step within a phase; a
  tagged release once a phase's gate genuinely passes on this Mac.

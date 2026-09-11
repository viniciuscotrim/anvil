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
      `mlx_lm.server` subprocess per loaded model (the same
      `/v1/chat/completions` + `/v1/models` shape oMLX serves).
      `ModelSessionManager` tracks what's actually loaded into memory —
      Load/Unload per model from the Models tab, each on its own port
      (checked against real open ports, not just Anvil's own bookkeeping).
      Chat is its own app-level tab (not tied to how you navigated in),
      with a model picker among whatever's loaded, per-model history,
      text selection/copy, and Markdown export. A menu bar item
      (`MenuBarExtra`) lists loaded models and quits the app; quitting by
      any path (Cmd+Q, Dock, the menu bar) stops every loaded model's
      subprocess first via `NSApplicationDelegateAdaptor` — nothing gets
      left running in the background.
      Fixed two real bugs found testing against an actual imported model:
      sending a model's registry id as the chat request's `model` field
      made `mlx_lm.server` try to resolve it as a Hugging Face repo id
      and 404 (now always sends `"default_model"`, which maps back to
      whatever the server was actually launched with); a reasoning
      model's response can omit `content` entirely when cut off by
      `max_tokens` (now falls back to the `reasoning` field instead of
      throwing). Verified for real on this Mac against a locally-loaded
      model, not just `--phase3-gate` — including catching a live,
      real-world instance of the "orphaned background process" bug: the
      app had quit but its `mlx_lm.server` child was still running,
      still holding port 8000. That's exactly what the menu bar +
      `applicationShouldTerminate` cleanup now prevents.
      Chat is now properly persistent: `ChatThread`/`ChatThreadStore`
      save every conversation to `chats/threads.json`, and chat state
      moved from a view-local `@StateObject` to `AppState` (owned once,
      alongside `RequirementsManager`/`ModelSessionManager`) so
      navigating to Models and back no longer loses the conversation —
      that view-lifecycle mismatch was the actual root cause. A Chat
      History window (separate `WindowGroup`) lists/opens/deletes
      threads; a temporary-chat toggle (user-activated only) skips
      persistence entirely and blocks starting/switching threads while
      it's on. Messages record which model answered them, so switching
      the active model mid-thread only affects new messages. A
      collapsible side panel holds everything about the conversation
      (threads, temporary mode, hide-reasoning toggle, generation
      settings — max tokens/temperature/top-p/top-k/min-p, sent
      per-request) except the model picker and tok/s, which stay in the
      always-visible header per spec.
      Each loaded model now shows in Activity Monitor as "Anvil - <model
      name>" instead of a generic "Python" indistinguishable from every
      other loaded model (`NamedLauncher`). The venv's Python is a
      Homebrew framework build that unconditionally re-execs itself into
      a fixed binary (`Python.app/Contents/MacOS/Python`, needed for
      Metal/GPU access) — renaming the invocation alone doesn't survive
      that, and neither does `sys.executable` (it just echoes back
      whatever path it was invoked with, pre-re-exec) or
      `PYTHONEXECUTABLE` (the documented override, tried, didn't stop
      it). The actual fix: probe the real interpreter once with
      `proc_pidpath` — asking the *kernel* what a running process really
      is, not Python's own self-report — to find the true final binary,
      then symlink that under `venv/bin/Anvil - <name>` (inside `venv/bin/`
      so Python's own venv detection still finds `pyvenv.cfg`) and invoke
      the script through *that* launcher. Verified for real, end-to-end,
      through the actual app code path, holding the process open and
      checking `ps aux` mid-run — not just the launch line.
      Opening a model's server is now an explicit, per-model choice
      (`ServerAccess`), not an implicit side effect of loading: a
      gear icon next to each model opens a popover to pick the port
      (validated against a real bind before committing, not just
      Anvil's own bookkeeping — a taken port fails with a clear message
      instead of the raw Python traceback `mlx_lm.server` throws) and
      whether it's local-only (`127.0.0.1`, the default) or open to the
      network (`0.0.0.0` — what the persona proxies over Tailscale will
      need). Reachability verified for real over the LAN, not just
      loopback: bound a model to `0.0.0.0` on a chosen port and confirmed
      a real chat completion over the Mac's actual network IP from
      another process.
      **Not done yet**: the brief's actual gate — the Sofia persona
      proxy (:8003) getting a valid response through this backend with
      zero changes on its side, then retiring oMLX. That's a deliberate,
      separate step since it touches the live stack; not taken until
      asked for.
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

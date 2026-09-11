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
      **Not done, by explicit decision**: the brief's actual gate — the
      Sofia persona proxy (:8003) getting a valid response through this
      backend, then retiring oMLX — is out of scope for this project.
      Nothing external (no agent, no other app, no persona proxy) gets
      pointed at Anvil's server during this engagement; the mechanism is
      built and verified locally (real chat completions, real LAN
      reachability) but the live-stack handoff itself isn't happening
      here. Same policy applies going forward, including Phase 4's
      flux_server.py retirement.
- [~] **Phase 4 — Image generation (in progress)**: `mflux` ships no
      server of its own (only a generate-once-and-exit CLI), so
      `ImageServerScript` is genuinely Anvil's own `/v1/images/generations`
      endpoint — Python stdlib `http.server`, keeps the Flux pipeline
      resident across requests instead of reloading multi-gigabyte
      weights every call. `ImageServer`/`ImageSessionManager` mirror
      `LLMServer`/`ModelSessionManager`'s shape (kept separate rather
      than unified — different processes, different load times).
      Models now carry a `kind` (`.text`/`.image`), auto-detected from
      their file layout (diffusion pipelines split weights across
      `transformer/`/`vae/`/two text-encoder directories rather than one
      flat set of files) so the Models tab routes Load/Unload to the
      right session manager on its own. Standalone image generation is
      its own tab (model picker, prompt, a settings panel matching
      Chat's, a gallery of everything generated) — the Draw Things half
      of this phase. The brief's other half — `generate_image(prompt)`
      as a tool the chat model can call mid-conversation — is real,
      working tool-calling (`ChatTool`, `mlx_lm.server`'s own
      `tools`/`tool_calls` support), not a stub: verified with an actual
      4B text model asked to draw something, which on its own decided to
      call `generate_image` with a well-formed, elaborated prompt, got a
      real Flux-generated image back, and narrated it — the full round
      trip `ChatViewModel.send()` drives, exercised headlessly end to
      end via `--phase4-gate`. Generated images render inline in the
      chat bubble. That real run also caught the model fabricating a
      Markdown image link with a made-up URL in its narration (the
      image is attached directly, not by reference) — the tool result
      message now explicitly tells it the image is already shown and
      not to include one.
      **Not done yet**: the actual `flux_server.py`/port-8200 retirement
      — same policy as Phase 3, nothing external gets pointed at this
      during the project.
- [ ] Phase 5 — Concurrent multi-model residency
- [ ] Phase 6 — Voice chat

## Reliability and UX fixes (post-Phase-4 round)

All found by actually using the app, not review — same pattern as every
round before.

- **Guaranteed cleanup, even on a crash.** The real bug: a model
  server's `applicationShouldTerminate` cleanup never runs if Anvil is
  force-quit, crashes, or gets `kill -9`'d — exactly how a real 9GB
  orphaned process was found hours after its app had already died.
  `ProcessWatchdog` now spawns a tiny shell process alongside every
  loaded model that polls its own parent PID; the moment Anvil goes
  away for *any* reason, the OS reparents it to launchd (ppid becomes
  `1`), and it kills the server it's watching. Verified for real in the
  harshest case: launched a real model server through the actual app
  code path, `kill -9`'d the app (no cleanup code got to run at all,
  same as a real crash), and confirmed the watchdog killed the orphan
  within ~2s.
- **Real progress, not a spinner.** `mflux` exposes a proper in-loop
  callback (`flux.callbacks.register(...)`, `call_in_loop(t, ...,
  time_steps)`) — confirmed by hand before touching the server code.
  Wiring it in via `ThreadingHTTPServer` first broke generation outright
  ("There is no Stream(cpu, 0) in current thread" — MLX ties its compute
  stream to whichever thread loaded the model) — fixed by running the
  model load and every generation call through one dedicated worker
  thread (`ThreadPoolExecutor(max_workers=1)`) while the HTTP server's
  other threads stay free to answer `GET /v1/images/progress`. A new
  `CircularProgressView` (a real filling ring, not SwiftUI's
  `.circular` style, which stays an indeterminate spinner on macOS even
  with a value) shows it in both the Images tab and inline during a
  chat tool call.
- Chat's images are now interactive — `InteractiveImageView` (shared
  with the gallery): right-click to copy or reveal in Finder, or Save
  As… through a real save panel, not just a static picture.
- `ChatClient`'s request timeout was the default 60s, too short for a
  slow model or a tool-call round trip that includes real image
  generation in the middle — raised to 300s, matching `ImageClient`.
- Hugging Face search gained a Small/Medium/Large size filter, relative
  to *this Mac's* RAM (`ModelSizeClass`: ≤25% / ≤50% / above), from
  size estimates pulled in bulk via `expand=safetensors` (parameter
  counts × bytes-per-dtype) — one search call, not one lookup per
  result. A "search as I type" toggle debounce-searches after 3+
  characters instead of waiting for Return.

Killed the pre-existing 9GB orphan this round's investigation turned up
(a leftover from testing earlier in development, from before any of
this cleanup work existed).

## Profiles, per-model folders, and more real bugs (second reliability round)

Six more issues, all found by actually using the app — one of them
(the Activity Monitor name) turned out to invalidate the *mechanism*
the previous round shipped, not just a detail of it.

- **Activity Monitor really shows "Anvil - \<model\>" now.** The
  previous fix (a symlink into `venv/bin/` named after the model)
  never actually worked — proven with `ps -o ucomm=`, the same field
  Activity Monitor's Process Name column reads: macOS sets a process's
  kernel-level name from the *file `execve` actually resolves to*, not
  the symlink path used to reach it, so every model still showed up as
  plain "Python" no matter what the symlink was called. The real fix
  (`NamedLauncher`) is a genuine **copy** of the tiny (~33KB) interpreter
  stub instead of a symlink — there's no indirection left for the
  kernel to see through. Validated for real, twice: a standalone script
  test (`sys.prefix` still resolves to the venv, `mlx.core` still gets
  `Device(gpu, 0)`), then through the actual app code path via
  `swift run Anvil -- --phase3-gate` against a real local model, where
  `ps -o pid,ucomm` showed `Anvil - Qwen3.5-` for the live
  `mlx_lm.server` process (truncated at 16 characters — a hard kernel
  limit on process names, not something any app-level trick can widen).
- **A sent message could vanish if you switched tabs mid-reply.** Root
  cause: `ChatView`'s `.task { loadInitialState() }` reruns every time
  the tab is revisited (SwiftUI tears down and recreates the view on
  each tab switch), and it was unconditionally resetting the active
  thread to whatever was last saved on disk — discarding an in-flight,
  not-yet-persisted send if the reply was still coming back when you
  navigated away and back. Fixed in `ChatViewModel`: the thread is only
  ever picked once per app session after that; later calls just refresh
  the thread/profile lists. The user's own message is also now saved to
  disk immediately after being sent, not only after the full reply
  (tool calls included) comes back, so it survives even if something
  else goes wrong before the model answers.
- **Every chat message was triggering an image generation, image or
  not.** The `generate_image` tool's description was vague enough
  ("Generate an image from a text prompt...") that smaller local models
  called it on nearly every message, since it was simply the only tool
  on offer. Fixed with an explicit "only call this when the user
  actually asks for an image" instruction in both the tool's own
  description and a system-prompt-level reminder sent alongside it.
- **On-demand image models, with a real off switch.** Each image
  model's gear icon in Models now has a "keep loaded after generating in
  chat" toggle. Off: the model unloads right after delivering an image
  and reloads automatically the next time chat actually asks for one —
  slower per image, no memory held between requests. On (default):
  stays resident, same as before. The same panel sets that model's
  default resolution (512×512 to start, same as the Images tab).
- **Sequential images in one chat kept drifting off-character.**
  Asking for "the same character in different clothes" repeatedly
  changed skin tone, hair, eyes, and body type too, not just the
  clothing. `ChatViewModel` now remembers each thread's last
  `generate_image` call (prompt + seed) and carries both forward into
  the next one — same seed, and an explicit "keep the same appearance
  unless this clearly changes it" instruction ahead of the new request.
  The very first image in a thread falls back to the active profile's
  own description, if it has one. A best-effort consistency aid, not
  true image editing — nothing here does img2img.
- **Profiles ("Perfis").** A new tab: reusable system prompts (oMLX
  called these personas), each optionally the default for one
  registered model. Loading that model (or selecting it for a thread
  that's still empty) applies its default profile automatically. A
  thread shows which profile it's using but only lets you change it
  before the first message — switching mid-conversation would leave the
  system prompt inconsistent with everything already answered under the
  old one.
- **A destination folder for models.** Models → "Models Folder" points
  downloads at any folder you choose instead of Anvil's own Application
  Support directory, and doubles as an importer: pick a folder already
  full of models (an old oMLX directory, say) and its subfolders get
  scanned and registered immediately, no separate import step per model.
  "Rescan" re-checks the current folder for anything added since.
- **Chat pops out into its own window** — the button next to the
  sidebar toggle opens the same live conversation (same `ChatViewModel`,
  not a fork) in a separate window, so it can stay visible while using
  the rest of the app.
- **Max Tokens defaults to a generous budget, not a small fixed one.**
  The reported bug — a reply cut off before it answered, reasoning
  models especially — was the old fixed default (1024) being consumed
  entirely by thinking. Left blank, Chat now sends 8192 instead. That
  number is a real, deliberate choice, not a placeholder: a first
  attempt sent a literal 1,000,000 ("truly unlimited") and hit a genuine
  hang in testing — a local Qwen3.5 checkpoint never emitted its stop
  token for a trivial three-word prompt and just kept generating, CPU
  pegged, memory climbing, past three minutes with no way to cancel it
  from the UI. 8192 is large enough that no realistic reply gets cut
  short while keeping a model that fails to stop bounded to something
  recoverable. Type a number to set an explicit cap either direction.

## Hugging Face auth, download control, and a real folder-scan fix

- **Hugging Face token.** Models tab has a "Hugging Face Token" field —
  authenticates search and downloads, needed for private repos and
  gated ones you've been granted access to, and gets the authenticated
  (higher) rate limit either way. Stored in the macOS keychain
  (`HFTokenStore`), not `AppSettings`'s plain JSON file — this is a real
  credential, unlike everything else that settings file holds. Applied
  by setting `HF_TOKEN` in the download subprocess's environment
  (exactly what `huggingface_hub` already looks for — confirmed live:
  an unauthenticated test download printed huggingface_hub's own
  "set a HF_TOKEN" warning, proving it checks for that variable) and as
  an `Authorization: Bearer` header on search requests.
- **Pause and Stop a download.** Both cancel the in-flight
  `snapshot_download` process (`ProcessRunner` now supports cooperative
  `Task` cancellation — cancelling sends the child `SIGTERM`); they only
  differ in what happens to the partial directory after. Pause keeps
  it — Hugging Face's own resumable-download support picks up where it
  left off the next time that repo is downloaded again. Stop deletes
  it. Validated for real, deterministically (not dependent on network
  speed): cancelling a `ProcessRunner`-driven process mid-run threw
  `CancellationError` and left no orphaned process, in under 2 seconds
  for a script that would otherwise have run 30.
- **The models-folder scan only found models one level deep.** A real
  reported bug: pointing Anvil at an existing models folder found
  nothing, because real models folders are almost always laid out
  `<namespace>/<repo>/…` — exactly what `snapshot_download`/`git clone`
  produce — not flat. `ModelImporter.importFolder` now recurses
  (bounded depth, stops at the first directory that looks like a model
  so it never descends into a diffusion pipeline's own `transformer/`/
  `vae/` subfolders) instead of only checking immediate children.
  Verified against a real, previously-broken folder on this Mac: the
  fix found and registered all 8 real models nested two levels deep
  that the old one-level scan missed entirely.

## Moving/deleting registered models, and grouping them by family

Models registered from outside the current models folder (the ones
that made Anvil's own default folder still show entries after pointing
it elsewhere — expected, since changing the folder is forward-only, it
was never going to retroactively move anything) now have a real way to
consolidate or clear them out:

- **Move into the current folder** — a tray icon next to a model whose
  files live somewhere other than the current models folder physically
  moves them there (`FileManager.moveItem`, real bytes on disk, nothing
  re-downloaded) and updates the registry to match. The entry's `id` is
  deliberately left untouched by a move — even for an imported model,
  whose `id` embeds its original path — specifically so nothing that
  references it elsewhere (a loaded session, a profile's default-model
  binding) goes stale; only `localPath` changes.
- **Delete** — a trash icon moves a model's files to the Trash (not a
  permanent delete; recoverable there the same as any other Finder
  delete, which matters given these are often multi-gigabyte weights)
  and removes it from the registry, behind a confirmation dialog.
  Verified for real: `FileManager.trashItem` moved a test directory to
  `~/.Trash` and left nothing at the original path.
- Both are disabled while the model is currently loaded — unload it
  first.
- **Grouped by family.** "Registered models" is no longer one flat
  list — `ModelFamilyGrouping` buckets every size/quantization variant
  of the same underlying model together ("Qwen3.5" holding its 9B-bf16,
  9B-mxfp8, and 4B-4bit entries; "FLUX.2-klein" its own), by stripping
  the trailing size ("9B") and quant/dtype ("4bit", "bf16", "mxfp8", …)
  tokens off an HF-style repo name and grouping on what's left. A name
  that doesn't match anything just becomes its own singleton group
  rather than an error.

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

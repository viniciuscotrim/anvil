# Anvil

A single native macOS app that replaces three separate pieces of a local-LLM
stack — **oMLX / OffGrid AI** (LLM serving & multi-model chat), **Draw Things**
(image generation), and a standalone Flask image server — with one from-scratch
app: download or import models, run text (MLX & GGUF via llama.cpp) + image (Flux via mflux & Draw Things via libnnc)
+ voice models concurrently, and chat with durable auditable memory.
No terminal, no manual dependency setup, ever.

Full spec: [docs/build-brief.md](docs/build-brief.md).

## Current release: 0.13.1-ios-delete-fix (iOS: Deleting a Model Actually Works)

Reported live: deleting a downloaded model on iOS failed outright —
"Couldn't delete Z-Image because the volume 'User' doesn't have one"
(a Trash). iOS only supports moving a file to the Trash for a handful
of volumes that actually implement one; a model's files live inside
this app's own sandboxed container, which isn't one, so every delete
failed the same way. Now a direct, permanent delete on iOS — nothing
on the Mac side changed, so no new `.dmg` for it.

It follows 0.13.0's real "Suggest from Thread" memory digest (turns a
conversation's context into durable, global memory before it grows too
large to keep using, then picks it back up from a fresh thread — see
"A real memory digest" below), 0.12.2's fix for Chat hanging forever on
a stalled model, 0.12.1's fix for downloads landing truncated plus a
GGUF quantization picker on iOS, 0.12.0's GGUF/llama.cpp engine on iOS, a real app icon
on both platforms (Mac `.icns`, iOS `AppIcon.appiconset`), a fix for
Z-Image/FLUX.2/Krea-2 models loading through mflux's FLUX.1-only
pipeline at `0.11.1`, and 0.10.0's threads column plus 0.11.0's round
of Chat refinements before that. Full release history in
[CHANGELOG.md](CHANGELOG.md), now caught up through `0.7.0`'s download/
queue/image-version-history/Prompt-to-Model work, the iOS chat/sync
parity and iCloud sync fixes that followed it (`0.7.x`–`0.9.0`), and
the Models tab fixes and CivitAI support at `0.8.x`.

The Mac release artifact is signed with Apple Developer ID. Build with `scripts/package-dmg.sh 0.13.0`. See [CHANGELOG.md](CHANGELOG.md) for full history.

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

## A default image model for chat

With more than one image model registered, `generate_image` tool calls
in chat had no explicit preference — whichever image session happened
to already be loaded (arbitrary load order) or, failing that, whichever
registered entry came back first. Each image model's gear settings in
Models now has a "Default image model for chat" toggle
(`AppSettings.defaultChatImageModelID` — exclusive, like a profile's
model binding: turning it on for one model turns it off for whichever
held it before). `ChatViewModel` now picks in this order: the default,
if it's already loaded; otherwise whatever image model is already
loaded, rather than loading a second one just to satisfy an unmet
preference; otherwise the default from the registry, loaded on demand;
otherwise the first registered image model, same as before this existed.

## Two real registry bugs: duplicate models, and a wrongly-detected kind

Reported after actually using the models-folder feature: a duplicate
"FLUX.2 4b" entry with only one real copy on disk, and its gear icon
showing nothing but port/access — no image-model chat settings at all.
Both traced to real bugs, not the folder-scoping question they first
looked like (see below).

- **Duplicate registration.** `ModelImporter.importFolder` generated a
  fresh `"imported:<path>"` id for every directory it found, without
  checking whether that exact path was *already* registered under a
  different id — which happens as soon as a model is both downloaded
  through search (a stable Hugging Face repo id) and later swept up by
  a folder scan of wherever it landed (a second, path-derived id for
  the same files). Fixed at the source: the scan now checks the
  registry by `localPath` before generating any id, and refreshes the
  existing entry in place instead. `ModelRegistry.deduplicateByLocalPath`
  additionally repairs a registry that already has a duplicate in it
  from before this fix — merging by `localPath`, preferring the
  Hugging-Face-sourced entry over the path-derived one — and runs
  automatically whenever the Models tab loads the registry, so an
  existing duplicate self-heals rather than needing a manual fix.
  Applied for real to this Mac's own registry: found and merged exactly
  the reported duplicate.
- **Wrong kind.** `black-forest-labs/FLUX.2-klein-4b-nvfp4` ships as one
  flat `*.safetensors` file — no `config.json`, no diffusers-pipeline
  directory structure — so the original structural-only detector always
  fell through to `.text` for it, which is why its gear icon showed
  none of the image-model chat settings. `ModelKindDetector` now also
  checks the repo/folder name against known diffusion-family keywords
  ("flux", "stable-diffusion", "sdxl", …) and, failing that, peeks at a
  flat safetensors file's own JSON header — present at the very start
  of the file, no need to read any tensor data — for architecture-
  specific tensor-name patterns (FLUX-style `img_in`/`double_blocks`, a
  `vae.`/`text_encoder.` prefix) that a causal LM's tensor names never
  have. `ModelRegistry.refreshKinds` re-detects every entry's kind
  against its real files and updates whatever changed, run automatically
  the same way as the dedup pass. Verified for real against the actual
  previously-broken file on this Mac: now detects `.image` correctly.
- **Folder-scoping clarified, not changed.** Changing (or resetting)
  the models folder only ever affected new downloads and what Rescan
  looks at — it was never meant to hide or remove models already
  registered from elsewhere, and still doesn't; that's what Move/Delete
  (previous round) are for. Reset now also re-scans the (now current)
  default folder for symmetry with Change, and the folder bar's copy
  spells out the scope directly so it doesn't read as broken when
  nothing visibly changes.

## A model that fails to load now says why

Reported after the models-folder fixes above finally let a
previously-mis-detected image model show a Load button: it failed, with
a plain yellow warning triangle and, per the user, no message anywhere
about what actually went wrong.

The message existed — a `.help()` tooltip — but two real problems sat
behind it:

- **The detail itself was thrown away.** `LLMServer`/`ImageServer`
  only ever reported a generic wrapper phrase ("process exited before
  becoming ready") because nothing captured the child process's actual
  stdout/stderr unless a caller happened to pass an `onLog` closure —
  and `ModelSessionManager`/`ImageSessionManager` never did. Both
  servers now keep a rolling tail of their process's own output
  (`OutputTail`, fed from the same pipe regardless of `onLog`) and
  include it in a startup failure's message. Verified for real against
  the exact case that prompted this: loading
  `black-forest-labs/FLUX.2-klein-4b-nvfp4` through the real
  `ImageServer` now surfaces mflux's actual traceback —
  `FileNotFoundError: No safetensors files found in
  .../FLUX.2-klein-4b-nvfp4/vae` — instead of the old generic phrase.
  That traceback also explains the underlying limitation plainly: mflux
  expects a diffusers-style pipeline directory
  (`transformer/`/`vae/`/`text_encoder/` subfolders), and this
  particular repo ships as one flat raw checkpoint — a real format
  mismatch no code change here can paper over. A properly-packaged
  mflux-community checkpoint loads fine, as it always did.
- **A hover tooltip is easy to miss.** The warning triangle is now a
  real button — tapping it opens a popover with the full, selectable
  failure text (a Python traceback can run well past what a tooltip
  can show), while the hover tooltip stays for a quicker glance.

## Real download progress, a real download queue

- **A fillable bar and a real percentage**, not just a scrolling status
  line. `huggingface_hub`'s own progress bars (tqdm) update in place
  with `\r`, not `\n` — `ProcessRunner`'s line buffering only ever split
  on `\n`, so every intermediate tick glued into one blob until the next
  real newline instead of arriving as its own line. Now splits on
  either. `DownloadProgressParser` pulls the `NN%` straight out of
  tqdm's own bar format. Verified deterministically end to end: a
  synthetic script emitting six `\r`-separated ticks (0/20/40/60/80/100%)
  produced six distinct lines through the real `ProcessRunner`, each
  parsed to its exact percentage.
- **A real download queue — never simultaneous.** Clicking Download
  while one is already running now queues it (shown as "Queued (#N)"
  with its own Remove button) instead of doing nothing; the queue
  drains one at a time as each finishes, however it finishes —
  completed, paused, or stopped.

## The Images tab, Draw-Things-style: version history

Generating again from an image no longer means starting over or
overwriting it. Every generated image now belongs to a **lineage**
(`GeneratedImage.lineageID`/`versionNumber`) — a fresh generation starts
its own; clicking into an existing one and generating again (with an
edited prompt, a different model, or both) adds a new **version** to
that same lineage instead.

- The gallery grid shows one tile per lineage — its latest version.
  Clicking one opens a **detail canvas**: the image large, its prompt
  (loaded back into the input field, editable), and a vertical
  **version-history carousel** of every version in that lineage,
  newest at the top — clicking a thumbnail there switches which version
  is showing, each with its own prompt/model/seed.
- The model picker in the header is what the *next* generation uses —
  pick a different one, hit "New Version", and it's added to the same
  lineage under the new model rather than replacing anything.
- Deleting a version falls back to the next-latest surviving one in
  that lineage, or back to the gallery if none are left.
- An image saved before lineages existed just becomes its own
  singleton lineage (version 1) on next load — no migration step.

## Prompt to Model

A new tab: describe an image idea in plain language, pick a loaded text
model to interpret it, and get one tailored, **editable** prompt per
registered image model — written by that text model, which is told
every registered image model's name and asked to reply with one JSON
object mapping each to its own prompt (`PromptToModelViewModel.interpret`).
Local models don't always follow a JSON contract exactly, so parsing is
deliberately forgiving: it extracts the outermost `{...}` regardless of
surrounding text (a stray sentence, a markdown fence), matches a model's
name case/whitespace-insensitively if an exact key isn't there, and —
if a given model still isn't named in the response — falls back to the
raw idea verbatim for that one row rather than leaving it blank. Every
row gets its own Generate button: loads that model on demand if it
isn't already resident, generates with whatever the prompt now reads
(hand edits included), and saves into the same `GeneratedImageStore`
the Images tab's gallery/version-history reads from — it shows up there
immediately, like any other generation.

## A download that "disappeared" was still running — Models tab had the Chat bug too

Reported: leave the Models tab mid-download, come back, and the
download — progress bar, queue, everything — is gone from the UI, but
it's still actually running in the background.

Same root cause, same fix, as an earlier Chat bug (see "keeps `chat`...
alive across tab switches" in `AppState`'s own doc comment):
`ModelManagerViewModel` was still a view-local `@StateObject`, so
switching tabs away from Models and back tore the whole thing down and
built a fresh one from scratch. The in-flight download's `Task` kept
running regardless (once started, it holds a strong reference to the
view model it needs, independent of whatever SwiftUI does with the
view), so nothing crashed or leaked — it just became invisible and
uncontrollable, since the new view model had never heard of it. Fixed
the same way `ChatViewModel` was: moved into `AppState`, constructed
once, shared via `@EnvironmentObject` instead of rebuilt per tab visit.

## Xcode arrives, and a real fix for the actual FLUX.2-klein error

Xcode is now installed (a paid Apple Developer account signed in) —
`swift build`/`swift test` no longer need the Command Line Tools
workarounds this README used to document (the special `swift test`
frameworks-search-path flag, in particular; a plain `swift test` works
now). iOS Simulators are available and ready for that work whenever it
starts; a real device additionally needs Xcode to auto-generate a
signing identity from the signed-in account the first time a project
targets one, no separate action needed.

Investigating the FLUX.2-klein "no safetensors found in .../vae" error
further turned up the actual, useful explanation: Black Forest Labs
publishes **two different packagings** of the same model —
`black-forest-labs/FLUX.2-klein-4b-nvfp4` (what got downloaded — a flat
single-file NVIDIA-format quantized dump, genuinely not loadable by
`mflux`) and `black-forest-labs/FLUX.2-klein-4B` (no `-nvfp4` suffix,
capital B — a proper diffusers-style pipeline with real
`transformer/`/`vae/`/`text_encoder/` folders, confirmed for real via
`mflux`'s own `ModelConfig.from_name("flux2-klein-4b")`, which resolves
straight to it). Also confirmed: `ModelCompatibility` classifies the two
correctly — `.incompatible` for the nvfp4 one, `.compatible` for the
real one — so the new Hugging Face search filter (below) would have
caught this before the download, not after.

## A compatibility filter for Hugging Face search, and CivitAI support

- **Hugging Face: "Compatible only" filter (on by default).**
  `ModelCompatibility` classifies a search result from its own file list
  (`siblings`, fetched via `expand=siblings` on the same search request
  — no extra API call) — `.compatible` for a real diffusers pipeline
  (`model_index.json`, or `transformer/`+`vae/`), `.incompatible` for a
  flat single/few-file checkpoint with no pipeline structure and no
  `config.json` (the exact FLUX.2-klein-4b-nvfp4 shape), `.unknown`
  otherwise — deliberately never flagging an unfamiliar shape (most
  text models included) as incompatible just because it isn't a
  diffusion pipeline. Verified against real search results for both the
  broken repo and its working counterpart.
- **CivitAI search and download**, the same shape of feature as the
  Hugging Face one: a source picker in Models switches between them: a
  `CivitAICatalog` (civitai.com's public REST API), a `CivitAITokenStore`
  (macOS keychain, same reasoning as `HFTokenStore` — optional, needed
  for some gated content), and a `CivitAIDownloader` — native
  `URLSessionDownloadTask` (no Python needed; CivitAI's download is one
  file behind a redirect, not a whole-repo fetch), real progress via its
  delegate, cooperatively cancellable the same way the Hugging Face
  downloader is. Both sources share one download queue/progress/pause-
  stop mechanism (`DownloadJob`) — never two downloads running at once
  regardless of source. Verified for real end to end: searched CivitAI
  live, downloaded a real (small) file, confirmed it registered with
  `kind: .image`.
- **What CivitAI downloads can't do yet: load.** CivitAI's checkpoints
  are single files, not diffusers pipelines — `mflux` doesn't have a
  single-file loading path today, Flux-family checkpoints included, so
  a CivitAI download registers and shows up in Models but won't load
  until that's built (a real Python project,
  [robjsliwa/mlx-sd-single-file-models](https://github.com/robjsliwa/mlx-sd-single-file-models),
  shows this is solvable for MLX generally — not yet wired into Anvil).
  The Models UI says so plainly rather than implying it already works.

## A download nearly 3× the size it needed to be

Reported live, mid-download: the download link showed ~7GB but the
final size looked headed for 20GB+, and — separately — why does Draw
Things run a "Flux.2 9B 8-bit" comfortably when even this 4B model
looked bigger than this Mac's whole RAM?

Checked both for real, with actual byte counts from Hugging Face's own
API (`black-forest-labs/FLUX.2-klein-4B`, the repo from the previous
round's fix):

| file | size |
|---|---|
| `flux-2-klein-4b.safetensors` (root) | 7.75 GB |
| `transformer/diffusion_pytorch_model.safetensors` | 7.75 GB |
| `text_encoder/model-00001-of-00002.safetensors` | 4.97 GB |
| `text_encoder/model-00002-of-00002.safetensors` | 3.08 GB |
| `vae/diffusion_pytorch_model.safetensors` | 0.17 GB |
| **total** | **23.7 GB** |

Two real, separate things going on:

- **A genuinely redundant download.** The root-level file and
  `transformer/diffusion_pytorch_model.safetensors` are the same size
  to the byte — this repo ships its weights *twice*: once as real
  pipeline component folders (what `mflux` actually loads) and again as
  a flat single-file copy for tools that load a whole checkpoint from
  one file (ComfyUI-style). `mflux` never touches that second copy, so
  downloading it was pure waste — confirmed the actual root cause of
  "shows 7GB, ends up 20GB+". Fixed generally, not for just this one
  repo: `ModelDownloader.redundantRootLevelWeightFiles` looks at a
  repo's own file list (already fetched for search — no extra API call)
  and skips any root-level `.safetensors`/`.bin`/`.ckpt`/`.pt`/`.gguf`
  file *only* when `model_index.json` confirms a real pipeline exists
  in the subfolders — never touches anything inside a component
  subfolder, never guesses on a repo it isn't sure about. Verified for
  real against the actual repo's exact file list, and the
  Python-side `ignore_patterns` JSON round-trip and matching behavior
  independently confirmed against the same `fnmatch` logic
  `huggingface_hub` uses internally.
- **The wrong precision, separately.** Even after removing the
  duplicate, ~16GB of *unquantized* (BF16) weights is still a lot for
  24GB of RAM — and not what Draw Things is actually running: "Flux.2
  9B 8-bit" is a *pre-quantized* build, not the raw release. (Can't say
  for certain which exact repo Draw Things itself pulls from — no
  access to inspect its own network calls — but the *equivalent*,
  correct source for Anvil is the same `mflux-community` org already
  used elsewhere in this project.) Checked real sizes there too:
  `mflux-community/flux2-klein-9b-mflux-q8` (9B, 8-bit) is 17.9GB — the
  same ballpark as Draw Things' but still tight against this Mac's RAM;
  `mflux-community/flux2-klein-4b-mflux-q4` (4B, 4-bit) is 4.6GB and
  comfortably fits. Both have a clean file layout already (no redundant
  root-level copy) — confirmed via the same file-list check.

## A left-hand threads column in Chat

Requested: a way to navigate every open conversation from the Chat tab
itself, not just via the separate "Chat History…" window. `ChatView`
now has an optional left column (`chat.isThreadsSidebarOpen`, on by
default, toggled from a `sidebar.left` icon in the header) that lists
`ChatViewModel.allThreads` — the same source the popout window already
used, so no new state to keep in sync. That list already covered both
saved threads and in-session **temporary** ones (never written to
disk, gone once the app quits) via `ChatViewModel`'s `temporaryThreads`
tracking, so the new column gets both kinds of navigation for free.
Each row shows the title and last-message preview, highlights whichever
thread is currently open, and carries its own "new thread" and delete
controls. (The separate "Chat History…" window this replaced is gone
as of 0.11.0 below — the column made it fully redundant.)

## Chat layout refinements: titles, a leaner panel, a real popout

A follow-up round on the threads column above, all requested together:

- **Editable titles.** A thread's title used to be silently derived
  from its first message. It now defaults to "Profile name · created
  date" (`ChatViewModel.autoTitle`) and is shown as an editable
  `TextField` right in Chat's header — type a new one and
  `ChatThread.isTitleCustom` locks it in for good; clear it back to
  empty and it reverts to the auto-generated one. Until it's locked,
  the title stays in sync with the profile (picking one, or a model
  applying its default) the same way `profileID` itself only changes
  pre-first-message. Synced via LAN (already plain `Codable`) and
  iCloud (`CloudSyncEngine`'s `CKRecord` mapping gained the field too,
  defaulting to `false` on a record written before it existed).
- **A leaner right-hand panel.** "New Thread", "Chat History…", and
  "Clear Conversation" are gone from Chat's sidebar — the threads
  column and its own per-row delete button already cover all three.
- **Temporary Chat moved to the composer.** The toggle is now an icon
  button next to the message field, not a sidebar row, and — like
  Profile — locks the moment the thread has a first message
  (`ChatViewModel.canChangeProfile` doubles as the gate for both; the
  doc comment on it says so). There's no way to convert a temporary
  thread into a permanent one after that, by design — same as Profile,
  start a new thread instead.
- **iPhone Sync and iCloud Sync are app-wide now, not Chat-specific.**
  Both settings actually applied regardless of which tab or thread was
  open, so their controls moved to `RootView`'s global top bar —
  compact icons (iPhone, then iCloud) just to the left of the app
  version, each opening a popover with the exact controls the Chat
  sidebar used to carry. Their startup calls
  (`applyMacSyncSettingsIfNeeded`/`applyCloudSyncSettingsIfNeeded`)
  moved out of `ChatView`'s `.task` into `RootView`'s for the same
  reason — status has to be known even if Chat is never opened.
- **Popping a conversation out now really detaches it.** Before, the
  popout window just showed a second copy of the same chat pane. Now
  `ChatView(isPopout: true)` sets `chat.isPoppedOut`, and the main
  window reacts by blanking its own conversation pane (header,
  messages, composer) in favor of a plain "open in a separate window"
  placeholder — only the threads column stays usable there. The popout
  itself carries the conversation plus the settings panel, always
  shown (no left column, no panel toggle — that's its whole reason to
  exist). Closing the popout is the only way back; there's no separate
  in-app "undo."

## Why some image models wouldn't load

Reported: Z-Image Turbo (`mflux-community/z-image-turbo-mflux-q4`)
failed to load with `FileNotFoundError: No safetensors files found in
.../text_encoder_2`. Root cause: `mflux` isn't one pipeline — FLUX.1,
FLUX.2, Krea-2, and Z-Image are each a genuinely separate Python class
with a different on-disk component layout (only FLUX.1 has a second,
T5 `text_encoder_2`), but `ImageServerScript`'s `build_pipeline()`
loaded *every* registered model through the FLUX.1 class regardless.
That meant every non-FLUX.1 model in Anvil's own curated hub was
affected, not just Z-Image — `flux2-klein-4b/9b` and `krea-2-turbo`
too — since the size-only download fix in `0.8.2` never actually
verified any of them could generate an image.

Fixed by detecting a registered model's family from its folder name
(Anvil already names it after the source repo id) and routing to that
family's own `mflux` class — `ZImage`, `Flux2Klein`, or `Krea2` — each
sharing enough of a common shape with `Flux1` (constructor, a
compatible `generate_image()`, a `.callbacks` registry) that this was
a small, surgical addition rather than a rewrite. Verified for real
against the actual downloaded Z-Image model: loaded in ~13s, then
generated and saved a real PNG. Full writeup, including why FLUX.2/
Krea-2 were verified by reading `mflux`'s own installed source rather
than a live download, and what happens for a model outside these four
families: [docs/image-model-loading.md](docs/image-model-loading.md).

## GGUF on iOS

Requested: bring the GGUF/llama.cpp engine to the iPhone, the same way
the Mac app already runs it (`LLMServer` spawning `llama_cpp.server`).
That exact approach can't port over — there's no `Process` on iOS at
all, the same reason `NativeChatEngine`'s MLX path already runs
in-process instead of over HTTP to a subprocess.

`ggml-org/llama.cpp` itself dropped its own root `Package.swift` at
some point (confirmed by checking — no `Package.swift` at the repo
root on `master` or any recent tag), so consuming it via SPM directly
isn't an option the way `mlx-swift`/`mlx-swift-lm` are. `AnvilIOS` now
depends on `eastriverlee/LLM.swift` instead — a real, actively
maintained (876 GitHub stars, pushed within the month at integration
time) Swift wrapper that itself pulls `ggml-org/llama.cpp`'s own
prebuilt xcframework release as a binary target, so the actual
inference code is still upstream llama.cpp, not a reimplementation.

`GGUFChatBackend` wraps it to the same shape `NativeChatEngine` already
uses for MLX (`load`/`send`/`streamSend`/generation settings), and
`load` picks the backend automatically — a `.gguf` file present in a
downloaded model's folder means `GGUFChatBackend`, otherwise the
existing MLX path, no separate "which engine" choice to make. The
Models tab's search results no longer flag a GGUF result as unable to
load on iOS — it's a normal, loadable result now, like MLX or mflux.

The one choice that matters most: `GGUFChatBackend` leaves the chat
template unset, which makes `llama.cpp`'s own bundled template engine
render each model's *actual* embedded Jinja chat template instead of
guessing one of a handful of hardcoded presets. `LLM.swift` ships five
(ChatML, Alpaca, Llama 2, Mistral, Gemma) — none of them Llama 3's own
`<|start_header_id|>` header format, which is exactly the model this
was verified against for real: downloaded a genuine
`hugging-quants/Llama-3.2-1B-Instruct-Q4_K_M-GGUF`, loaded it in
~1.3s, confirmed its embedded template really does start with
`<|start_header_id|>` (so none of the five presets would have matched
it), and got a correct, coherent answer with the template left
unset — proof this works generically for whatever GGUF someone
downloads, not just a family that happens to match a preset.

Two gaps, both explicit trims rather than oversights: no
`generate_image` tool-calling from this backend yet (`LLM.swift`'s
`Tool` protocol doesn't share a shape with `MLXLMCommon`'s, so wiring
it is separable follow-up work), and `tokensPerSecond` for a GGUF
reply is an estimate (elapsed wall-clock time over
`ChatContextBuilder`'s own token-count guess) rather than a measured
figure — `LLM.swift` doesn't report one the way `mlx-swift-lm`'s
`streamDetails` or the Mac app's HTTP servers do.

## Download fixes: truncated files, GGUF quant picker

Reported live, right after shipping GGUF on iOS above: downloading a
model expected to be ~8GB produced a ~20KB file instead.

**Bug 1 — a "successful" download that wasn't.** `URLDownloader`
already validated the HTTP status code (a fix from `0.6.7`, for a
different-but-similar symptom), but a gated Hugging Face repo without
proper access can answer a file's resolve URL with `200 OK` and a
small HTML/JSON "request access" body — genuinely a successful HTTP
response, just not the file. Fixed by also comparing the finished
download's real size on disk against `URLSessionDownloadTask`'s own
`countOfBytesExpectedToReceive` (the server's declared `Content-Length`)
before accepting it; a mismatch fails with a clear message instead of
silently keeping the wrong bytes. `URLDownloader` is shared by iOS's
Hugging Face downloader and CivitAI's on both platforms, so this
covers all of them, not just the reported case.

**Bug 2 — one repo, every quantization at once.** The specific repo
reported (`DavidAU/Qwen3.5-9B-...-GGUF`) has 27 files: 24 separate
`.gguf` quantizations (`IQ2_M` through `Q8_0`, plain and "MTP"
variants) plus a few extras. `HFModelSummary.filePaths` is *every*
sibling in the repo, and `HFRepoDownloader.download` downloads
whatever list it's handed, in full — so tapping "Download" on a result
like this queued an attempt at 100GB+, not the one file actually
wanted. Likely the bigger real contributor to the reported symptom:
whatever briefly interrupted the giant combined download (storage
pressure, a transient network error partway through the *second* file
in the list) would leave just the tiny first files that happened to
finish, which is exactly what "way smaller than expected" looks like
from the user's side.

Fixed with a real picker, not an automatic guess (asked directly:
auto-pick a sensible default vs. let the user choose — chose to let
them choose). `ModelsViewModel.beginDownload` checks the result's own
`.gguf` file count first — a repo with zero or one is unaffected,
downloads immediately like before. More than one shows a sheet listing
every `.gguf` file with its real size, fetched from Hugging Face's repo
*tree* API (`/api/models/{id}/tree/{revision}`) — the search/lookup
endpoints' `expand=siblings` returns file *names* only, never sizes, so
this is a separate, on-demand call (`HuggingFaceCatalog.fileTree`),
not something paid for by every search result. Each row's label is the
longest common prefix across all the repo's `.gguf` names, trimmed off
— for this repo that turns "Qwen3.5-9B-The-Defiant-Fable-Uncnr-Heretic-
NEO-MAX-IQ2_M.gguf" into just "IQ2_M", correct for any quantizer's own
naming convention rather than a hardcoded pattern. Picking a file
narrows the download to just that one — a GGUF is self-contained, no
sibling files needed the way an MLX/diffusers pipeline directory needs
its whole folder.

The Mac app's Model Manager has the identical "downloads the whole
`filePaths` list" gap (`ModelManagerViewModel.swift`, same shape) —
not touched in this pass since the report was iOS-specific, but worth
the same fix as a follow-up.

## Chat no longer hangs forever on a stalled model

Reported live on the Mac app: sent a message, Chat sat on
"Thinking…", and — watching Activity Monitor — the model server's own
memory/GPU use visibly dropped back down while Chat just kept waiting,
with nothing happening and no way to tell "still working" apart from
"stuck" other than waiting to see if it ever came back (it didn't).

`ChatClient.streamSend` already set `request.timeoutInterval = 1800`
(30 minutes) — deliberately generous, since a genuinely slow model
producing output steadily can take that long. That's exactly why it's
the wrong tool for this: the reported failure isn't a slow reply, it's
the connection going *completely silent* — the server stopped actually
computing without closing the socket or sending anything else, so the
existing timeout (which resets on any activity) never had a reason to
fire, possibly for the full 30 minutes, possibly never.

Fixed with a separate watchdog that tracks *time since the last byte
actually arrived* (ticked on every SSE line read, even one that parses
to nothing — a keepalive counts as much as real content) rather than
total time since the request started. 120s of true silence now ends
the stream with a clear "the model stopped responding" error, instead
of only ever failing — if at all — after the full half hour. Cancelling
the stalled read is what actually unblocks the connection: finishing
the stream's continuation from the watchdog triggers
`AsyncThrowingStream`'s own `onTermination`, which cancels the
underlying task, which `URLSession.AsyncBytes` responds to by aborting
the connection — a real, working example of that same cancellation
path. `ChatClient` is shared code (`AnvilCore`), so this covers every
caller at once: Mac Chat, Code, and Prompt to Model, plus iOS's
remote-Mac chat.

Verified with a real test (`stallWatchdogSurfacesAHungConnectionInsteadOfWaitingForever`),
not just read for plausibility: a mock `URLProtocol` sends one genuine
SSE chunk, then never sends anything else and never closes the
connection — the exact reported shape — and the test uses a 0.3s
`stallInterval` (an injectable parameter, defaulting to the real 120s
for actual callers) so it catches the hang in well under a second
rather than needing to wait out a real two-minute interval.

## A real memory digest

Requested directly: clicking "Suggest from Thread" should read the
*whole* conversation and turn everything relevant into durable,
system-wide memory — so a conversation can be picked back up from a
brand-new thread once the current one's context has grown too large to
keep using, without losing what was already established.

The feature already existed (`ChatViewModel.suggestMemoriesFromCurrentThread`,
reviewable suggestions, an "Accept"/"Dismiss" per item), but three real
gaps kept it from doing what was asked:

1. **It reused live chat's own bounded context window**
   (`ChatContextBuilder.build`) — first turn + a recent window, filled
   backward until a token budget runs out. That's exactly the wrong
   tool here: it's *built* to drop a long thread's middle, which is
   precisely what needs reading for this to work at all on a
   conversation that's actually grown too large. Fixed with a new
   `ChatContextBuilder.batches(_:maxEstimatedTokensPerBatch:)` — splits
   the entire thread into ordered, token-bounded excerpts, each
   analyzed on its own turn, so coverage no longer depends on how long
   the conversation got. Two real regression tests cover it: every
   message shows up somewhere across the batches (nothing from the
   middle silently vanishes), and a single message bigger than the
   whole per-batch budget still becomes its own batch rather than
   disappearing.
2. **Suggestions were scoped to the source thread's own profile**
   (`acceptMemorySuggestion` passed `currentThread.profileID`). A
   memory meant to be "system-wide, read by the AI in any new thread"
   silently wasn't, for a thread using a *different* profile — `send()`
   only ever includes a memory with no profile of its own, or a
   matching one. Now always saved with `profileID: nil`.
3. **A fixed 1200-token reply budget** for the model's own JSON output
   — fine for a couple of suggestions, but a real digest of a full
   conversation can legitimately list dozens, and a cut-off JSON array
   fails to parse. The old code swallowed that failure with `try?`
   into a silently empty result — exactly the shape of "I clicked the
   button and nothing happened." Raised to 4000 tokens, and a parse
   failure now sets a visible error instead of disappearing.

Also added: **Accept All** — a real digest can surface a few dozen
suggestions, and clicking each one individually defeated the
"everything worth remembering" ask. It goes through the exact same
per-item `acceptMemorySuggestion` sequentially, so nothing about how a
memory is actually saved changes.

Mirrored on iOS (`ChatThreadsViewModel`/`MemoryView`) with the same
three fixes and Accept All. One further iOS-only gap: `NativeChatEngine
.respondOnce`'s output budget defaults to whatever `ChatSession` sizes
an ordinary reply at, not a long JSON array — it now takes an optional
`maxTokens` override (`nil` leaves every other caller, e.g. Prompt to
Model, exactly as it was), and this one call passes 4000 to match Mac.

**Verified for real**, not just unit-tested: sent a fabricated but
realistic multi-fact test conversation (name, city, current project,
tech stack, two preferences, favorite language, birthday) straight to
a live, already-running `mlx_lm.server` on this Mac, using the exact
request shape `suggestMemoriesFromCurrentThread` builds. It came back
with all 8 facts, correctly typed (fact/preference/date) and correctly
parsed by the same extraction logic the app uses — real end-to-end
proof the instruction, the model, and the parsing all agree, not just
that the code compiles.

## iOS: deleting a model actually works

Reported live: deleting a downloaded model on iOS failed with
"Couldn't delete Z-Image because the volume 'User' doesn't have one."
`ModelsViewModel.delete` called `FileManager.trashItem`, matching the
Mac app's own delete button — there, a model's files really do move to
the real Finder Trash, recoverable like any other delete. On iOS, a
model's files live inside this app's own sandboxed container
(`effectiveModelsRoot`), and `trashItem` is only actually implemented
for a handful of volumes — iCloud Drive, Files app locations, Photos —
not a plain app-container path, so every call failed outright with
exactly that "doesn't have a Trash" message. There's no Files app entry
or other user-facing place these files could have landed in a
recoverable Trash on iOS anyway, so a direct, permanent `removeItem` is
both the fix and the only behavior that made sense here. iOS-only
change; the Mac app's own Trash-based delete already works correctly
and is untouched.

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

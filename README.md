# Anvil

A single native macOS app that replaces three separate pieces of a local-LLM
stack — **oMLX** (LLM serving), **Draw Things** (image generation), and a
standalone Flask image server — with one from-scratch app: download or import
models, run text + image + voice models concurrently, and chat by voice.
No terminal, no manual dependency setup, ever.

Full spec: [docs/build-brief.md](docs/build-brief.md).

## Current release: 0.5.0

This release adds the local OpenAI-compatible gateway on `127.0.0.1:8000`,
shared unified-memory planning, process RSS telemetry, and bounded prefix KV
caching through `mlx-lm` (`16` cache entries and `2G` per text server). Chat
and Code requests carry an optional `conversation_id`, and the Chat header
reports the latest server-reported cached prompt tokens.

The release artifact is signed but not automatically notarized. Build it with
`scripts/package-dmg.sh 0.5.0`; notarization uses the separate
`scripts/notarize-dmg.sh` credentialed step. See [CHANGELOG.md](CHANGELOG.md)
for the complete release notes.

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

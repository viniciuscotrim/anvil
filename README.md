# Anvil

A single native macOS app that replaces three separate pieces of a local-LLM
stack — **oMLX / OffGrid AI** (LLM serving & multi-model chat), **Draw Things**
(image generation), and a standalone Flask image server — with one from-scratch
app: download or import models, run text (MLX & GGUF via llama.cpp) + image (Flux via mflux & Draw Things via libnnc)
+ voice models concurrently, and chat with durable auditable memory.
No terminal, no manual dependency setup, ever.

Full spec: [docs/build-brief.md](docs/build-brief.md).

## Current release: 0.18.0-search-tab-and-background-downloads (A Search Tab, and Downloads That Survive Backgrounding)

Three related asks in one message. **Mac**: the Models screen split
into "Search" (Hugging Face/CivitAI/Draw Things, downloads, results)
and "Models" (the registered library, same tab, same place) —
requested live: "vamos separar a busca e download de modelos em uma
nova aba/menu chamado Search, e os modelos Registrados ficam onde
estão agora. Igual já temos no iPhone." This also fixed a real,
reported layout bug: the old combined screen's stacked search
controls, downloads, results, and library didn't fit the window's old
minimum size, visibly crowding the app's own tab bar above it — "tem
menus como Hugging Face/CivitAI etc sobre [os] menus como
Models/Chat/etc." The whole window also now has one consistent
minimum size (900×640) instead of each tab's own smaller one, so a
fresh install never needs manual resizing to look right. **iOS**:
model downloads now keep transferring through a locked screen or a
switched-away app via a real background `URLSession` — "vamos no
iPhone atualizar pra que ele consiga continuar fazendo o download do
modelo mesmo que a tela bloquear ou trocar de app." See "A Search tab
on Mac, and downloads that survive backgrounding on iOS" below.

It follows 0.17.0-credential-sync, requested live: "vamos criar os campos onde as Keys do Huggs e do
Civitai ficam armazenadas e sincronizadas o iCloud assim não preciso
recadastrar elas depois de feito em um dos dois devices." Both fields
already existed (Mac's Models tab, iOS's Settings); `HFTokenStore`/
`CivitAITokenStore` now save them as synced keychain items
(`kSecAttrSynchronizable`) under a keychain access group shared by
both targets, so setting one on either device carries it to the
other via the user's own iCloud Keychain — independent of the app's
own "iCloud Sync" toggle, since a credential isn't conversation data.
A pre-existing token on either device migrates forward automatically
the first time it's read. See "Hugging Face and CivitAI keys sync via
iCloud" below for what actually made this fail silently until a
specific entitlement was added.

It follows 0.16.0-chat-model-profile-picker's own fix, requested/reported live: "você tirou a seleção do modelo pra
conversa" — the previous fix for reading history without a loaded
model had an unintended side effect: the header's model picker only
ever listed already-*loaded* models, so once nothing was loaded there
was no picker at all. Fixed together with the rest of what was asked
in the same message: "dentro da janela do chat tem que ter o modelo
utilizado e podendo mudá-lo mesmo durante a conversa. O mesmo para o
Profile, tem que ser chat-based e não system wide. E quando eu for
criar um novo chat estes campos tem que aparecer pra eu selecionar
antes de mandar a primeira mensagem. Se o modelo selecionado não
estiver carregado, ao mandar uma mensagem ele se carrega
automaticmente. Se não houver memória ele descarrega os modelos ativos
antes de carregar o necessário." Mac's header now lists every
registered model (loaded or not) and shows Profile right next to it
instead of hidden in the settings sidebar; sending loads whichever
model is picked on demand, unloading other loaded models automatically
if that's what it takes to fit. iOS's model field/menu are no longer
locked once something's loaded. See "Model and Profile, chosen right
in the chat window" below.

It follows 0.15.1-history-without-model, requested live: "faça o histórico das conversas estar disponível pra
ler e navegar mesmo sem um modelo carregado, hoje sou obrigado, mas
com o histórico na núvem não faz sentido" (make chat history readable
and navigable even without a model loaded — today I'm forced to, but
with history in the cloud it doesn't make sense). Mac's `ChatView`
used to hide a conversation's entire transcript behind a "No models
loaded" placeholder whenever nothing was resident, even for a thread
already full of saved messages — the threads column itself never
needed a model, only the placeholder covering the actual messages did.
Now the transcript always shows first when the current thread has any
messages; sending a new one still correctly requires a model loaded.
iOS never had this bug. See "Reading chat history without a model
loaded" below.

It follows 0.15.0-memory-model-picker's own Memory-screen model
picker, requested live: "vamos criar dentro do menu de Memórias a seleção do
modelo que vai ser utilizado pra fazer as sugestões" — a Memory-screen
picker for which model runs "Suggest from Thread", offering every
registered text model, not just a loaded one ("não apenas os modelos
carregados mas todos os mapeados na pasta"). On Mac, pressing Suggest
loads the picked model on demand if needed, and — "se faltar memoria o
outro modelo atualmente carregado será descarregado antes, após a
confirmação do usuário" — asks before unloading anything else to make
room. On iOS, since only one model is ever resident at a time, picking
a different one means Suggest swaps the engine to it first, also
asked, since it changes what Chat itself uses next on that phone. See
"Choosing a model for memory suggestions" below for the full writeup.

It follows 0.14.0-suggestion-sync's cross-device sync for suggested
memories, requested live: "as memórias geradas podem já subir pro iCloud, assim
eu posso aprová-las ou não no iPhone ou Mac, independente de onde
foram geradas" (generated memories should already go up to iCloud, so
I can approve them or not on iPhone or Mac, wherever they were
generated) — "uma coisa é ela existir e outra é eu escolher que ela
pode ser usada pela IA" (one thing is for it to exist, another is for
me to choose it can be used by the AI). A "Suggest from Thread" run
used to live only in the app that ran it; now every suggestion is
persisted (`ChatMemorySuggestionStore`) and synced as a fourth
`CloudSyncEngine` record kind, so it can be triaged — accepted or
dismissed — from either device, with the removal itself syncing back
so nothing gets reviewed twice. Mac and iOS both.

It follows 0.13.2's fixes for the memory digest's visible progress,
scrollable Mac Memory window, and shown errors (three real follow-up
bugs from 0.13.0, all reported live in the same session it shipped: a
genuinely long conversation's multi-batch analysis showed nothing
until it fully finished — looked exactly like a silent failure,
confirmed live when unloading the model, an unrelated action,
happened to coincide with the run finishing and every suggestion
appearing at once; Mac's Memory window never displayed an actual
failure at all; and there was no way to scroll a long suggestions or
memory list on Mac, "preciso de uma barra de rolagem pois são
muitas"). See "Memory digest: real progress, a real scrollbar" below
for that writeup.

It follows 0.13.1's fix for deleting a model on iOS, 0.13.0's real
"Suggest from Thread" memory digest (turns a conversation's context
into durable, global memory before it grows too large to keep using,
then picks it back up from a fresh thread — see "A real memory digest"
below), 0.12.2's fix for Chat hanging forever on a stalled model,
0.12.1's fix for downloads landing truncated plus a GGUF quantization
picker on iOS, 0.12.0's GGUF/llama.cpp engine on iOS, a real app icon
on both platforms (Mac `.icns`, iOS `AppIcon.appiconset`), a fix for
Z-Image/FLUX.2/Krea-2 models loading through mflux's FLUX.1-only
pipeline at `0.11.1`, and 0.10.0's threads column plus 0.11.0's round
of Chat refinements before that. Full release history in
[CHANGELOG.md](CHANGELOG.md), now caught up through `0.7.0`'s download/
queue/image-version-history/Prompt-to-Model work, the iOS chat/sync
parity and iCloud sync fixes that followed it (`0.7.x`–`0.9.0`), and
the Models tab fixes and CivitAI support at `0.8.x`.

The Mac release artifact is signed with Apple Developer ID. Build with `scripts/package-dmg.sh 0.18.0-search-tab-and-background-downloads`. See [CHANGELOG.md](CHANGELOG.md) for full history.

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

## Memory digest: real progress, a real scrollbar

Three follow-up bugs from 0.13.0's memory digest, all reported live
against a real conversation in the same session it shipped.

**A long digest looked like it silently failed.** 0.13.0 made
"Suggest from Thread" split a whole conversation into several
sequential batches — each its own model call, and a real reasoning
model can genuinely take a while per call. The old code only ever set
`memorySuggestions` once, after every batch had finished, so a
multi-minute run showed nothing at all until the very end. Reported
live in exactly this shape: after clicking the button and waiting,
nothing appeared — then unloading the model (a completely unrelated
action, tried out of frustration) happened to coincide with the run
finally finishing, and every suggestion it had already found appeared
all at once. Fixed by updating `memorySuggestions` after *every* batch
instead of only at the end, plus a new `memorySuggestionProgress`
(`(completed, total)`) the button now shows directly — "Analyzing (2
of 5)…" instead of a static "Analyzing…" that gives no sense whether
anything is actually happening.

**Mac's Memory window never showed a failure at all.** `chat
.suggestMemoriesFromCurrentThread` already set `chat.errorMessage` on
a genuine failure (a batch's JSON not parsing, a request erroring),
but `MemoryView` never read it — an actual error and a quiet
non-event looked identical. Now shown inline, dismissible, matching
what iOS's own `MemoryView` already did.

**No way to scroll a long list on Mac.** Reported live: "preciso de
uma barra de rolagem pois são muitas" (need a scrollbar, there are too
many). `MemoryView`'s body was a plain `VStack` — never scrollable on
its own — and a real digest producing a few dozen suggestions, or a
Memory store that's grown over time, can both genuinely overflow the
window's fixed `520`-point height. Rewritten as a real `List` with
sections (mirroring the layout iOS's own `MemoryView` already used),
which scrolls the way any standard list does.

All three fixes are mirrored on iOS's `ChatThreadsViewModel`/
`MemoryView` (iOS's list already scrolled correctly, so only the
progress-and-incremental-update half applied there).

## Suggested memories sync across devices

Requested live: "as memórias geradas podem já subir pro iCloud, assim
eu posso aprová-las ou não no iPhone ou Mac, independente de onde
foram geradas" — generated memories should already go up to iCloud,
so they can be approved or not on either device, regardless of where
they were generated. "Uma coisa é ela existir e outra é eu escolher
que ela pode ser usada pela IA" — one thing is for a suggestion to
exist, another is choosing that it can actually be used by the AI.

Before this, a "Suggest from Thread" run only ever produced an
in-memory `memorySuggestions` list local to whichever app ran it —
run it on the Mac and the iPhone had no idea it happened, so there was
no way to review or approve a suggestion anywhere but the device that
generated it, even though both devices already shared *approved*
memories via `CloudSyncEngine`.

Fixed by promoting `ChatMemorySuggestion` from "held only in a
view model's published property" to "persisted and synced" — the
exact same treatment threads, profiles, and memories already got:

- A new `ChatMemorySuggestionStore` actor (`Sources/AnvilCore/Serving/
  ChatMemory.swift`), file-backed with tombstone-tracked deletions,
  identical in shape to the existing `ChatMemoryStore`.
- `ChatMemorySuggestion` gained `createdAt`/`updatedAt` (for
  last-write-wins merge), `originDeviceName` (so a suggestion's Memory
  row can show which device generated it, even when reviewed on the
  other one), `sourceThreadID` (which thread it came from — captured
  at generation time, not read from "whatever's open" at accept time,
  since that could be a different thread entirely once suggestions
  sync across devices), and `createdFromMessageID` (carried through to
  the resulting `ChatMemory` on accept, so deleting the source
  conversation still cascades to a memory that only exists because of
  it — even one accepted well after the fact, on a different device).
- `CloudSyncEngine` gained a fourth synced record kind
  (`"ChatMemorySuggestion"`), full `CKRecord` encode/decode, and
  `markSuggestionChanged`/`markSuggestionDeleted` — wired into the
  same `pendingChange`/`applyRemote`/`applyRemoteDeletion` switches
  the other three kinds already use.
- `suggestMemoriesFromCurrentThread` now persists (and syncs) each
  suggestion as soon as its batch finishes, rather than only keeping
  it in memory — clearing any stale suggestions from a prior run on
  the same thread first, so re-running the digest doesn't leave
  duplicates behind.
- Accepting or dismissing a suggestion — on *either* device — deletes
  it from the shared store and syncs that tombstone immediately, so
  the same suggestion is never triaged twice from two different
  places. Accepting now threads the suggestion's own
  `createdFromMessageID` through to the new memory (not whatever
  happens to be `currentThread` at accept time, which may not even be
  the thread the suggestion came from once it's reviewed elsewhere).

Mac and iOS both, mirroring the same architecture on each side
(`ChatViewModel`/`ChatThreadsViewModel`); requires iCloud Sync turned
on in Settings on both devices, exactly like thread and memory sync
already did — with it off, suggestions behave exactly as before,
local to whichever device generated them.

## Choosing a model for memory suggestions

Requested live: "vamos criar dentro do menu de Memórias a seleção do
modelo que vai ser utilizado pra fazer as sugestões. Tem que oferecer
não apenas os modelos carregados mas todos os mapeados na pasta" — a
picker in Memory for which model runs "Suggest from Thread", offering
every registered text model, not just one already loaded.

Until now, the digest silently used whatever model Chat currently had
selected (Mac) or loaded (iOS) — there was no way to run it against a
different, better-suited model (a stronger reasoner for extracting
facts, say) without first switching Chat's own active model and back.
`memorySuggestionModelID` (`AppSettings`, shared by both platforms) is
now a separate, persisted choice, `nil` meaning "whatever Chat is
currently using" — and Memory's own picker lists every `ModelEntry` of
kind `.text` from `ModelRegistry.all()`, loaded or not, the same
full list the Models tab itself shows.

Picking a model there doesn't load anything by itself — only pressing
"Suggest" does, on demand, and the two platforms differ in exactly
what that means:

- **Mac** can run several model server processes at once
  (`ModelSessionManager`), so loading the chosen model alongside
  whatever's already running is attempted first. Requested live: "e se
  faltar memoria o outro modelo atualmente carregado será descarregado
  antes, após a confirmação do usuário que o modelo pode ser
  descarregado" — if that fails for lack of unified memory,
  `ChatViewModel` now asks before unloading anything (a new
  `pendingModelUnloadConfirmation`/`resolveModelUnloadConfirmation`
  pair, driven by a `confirmationDialog` naming exactly which
  currently-loaded model(s) would be freed, text and image both, since
  they share one `ResidencyPlanner` budget) rather than either failing
  outright or unloading something without asking. Declining just
  cancels the digest; nothing is touched. Agreeing unloads them and
  retries the load once.
- **iOS** only ever keeps one model resident in `NativeChatEngine` at
  a time (there's no concurrent-residency budget to manage the way Mac
  has one) — so picking a different model for suggestions means
  Suggest first swaps the engine over to it. Also asked first (a local
  `confirmationDialog` in `MemoryView`), since — unlike Mac, where the
  suggestion model is independent of Chat's own selection — this
  swap also changes what Chat itself would use for its very next
  reply on this phone, not just what the digest runs on.

Mac (`ChatViewModel`/`MemoryView`) and iOS
(`ChatThreadsViewModel`/`MemoryView`) both.

## Reading chat history without a model loaded

Requested live: "faça o histórico das conversas estar disponível pra
ler e navegar mesmo sem um modelo carregado, hoje sou obrigado, mas
com o histórico na núvem não faz sentido" — make chat history
available to read and navigate even without a model loaded; today
that's forced, but with history syncing through iCloud it doesn't make
sense to require it.

Mac's `ChatView` gated its *entire* message area on
`ModelSessionManager.readySessions` being non-empty:

```swift
if sessions.readySessions.isEmpty {
    emptyState   // "No models loaded — load a model from the Models tab first."
} else if chat.visibleMessages.isEmpty {
    …
} else {
    messageList
}
```

That check made sense for "can this conversation still be replied
to," but it was also the *only* condition deciding whether
`messageList` (i.e. `chat.visibleMessages`) rendered at all — so
opening an old, fully-populated thread while no model happened to be
loaded (a common state now: the app doesn't auto-load anything at
launch, and iCloud sync means every synced conversation is browsable
long before its original model is ever loaded on this Mac) replaced
the whole transcript with a placeholder, as if the messages didn't
exist. The threads column and `ChatViewModel.selectThread` never
touched `readySessions` at all — nothing about navigating between
conversations ever needed a model resident; only this one placeholder
did.

Reordered so the transcript takes priority whenever there's anything
to show:

```swift
if !chat.visibleMessages.isEmpty {
    messageList
} else if sessions.readySessions.isEmpty {
    emptyState
} else {
    …
}
```

The "no models loaded" placeholder now only appears for a genuinely
empty thread — the state it actually describes. Sending a *new*
message still correctly requires a loaded model: the input bar's own
`.disabled(sessions.readySessions.isEmpty)` was never part of this bug
and needed no change. iOS's `NativeChatView` already rendered
`threads.currentThread.messages` unconditionally, so it never had this
problem in the first place.

## Model and Profile, chosen right in the chat window

Reported/requested live, right after the fix above shipped: "você
tirou a seleção do modelo pra conversa" (you removed the model
selection for the conversation) — an unintended side effect of that
same fix, since the header's model picker had always been conditioned
on `sessions.readySessions` (already-*loaded* models) being non-empty;
once nothing was loaded to make history readable without it, there was
no picker at all any more.

Fixed together with the rest of what came in the same message: "dentro
da janela do chat tem que ter o modelo utilizado e podendo mudá-lo
mesmo durante a conversa. O mesmo para o Profile, tem que ser
chat-based e não system wide. E quando eu for criar um novo chat estes
campos tem que aparecer pra eu selecionar antes de mandar a primeira
mensagem. Se o modelo selecionado não estiver carregado, ao mandar uma
mensagem ele se carrega automaticamente. Se não houver memória ele
descarrega os modelos ativos antes de carregar o necessário."

**Mac.** `ChatView`'s header `modelPicker` now lists every registered
text model from `ModelRegistry.all()` — loaded or not — with a filled
vs. hollow dot marking which ones already are, and stays live for the
whole conversation (unlike before, switching mid-thread was already
technically possible when a picker was visible at all; now it always
is). `profilePicker` moved out of the collapsible settings sidebar
(where it was easy to never notice) into the header right next to it —
same per-thread `ChatThread.profileID` storage as always (this was
already "chat-based" at the data layer), just no longer hidden behind
a panel toggle most people never open. It still locks after the first
message (`canChangeProfile`), since a profile shapes the system prompt
from the first turn; unlike the model, there's no sensible "swap
mid-conversation" for it. Creating a new thread (`newThread()`) resets
`profileID` to none, so both pickers are immediately there to fill in
before the first message goes out, exactly as asked.

Sending now loads whichever model is selected if it isn't already
resident (`ChatViewModel.ensureModelLoadedForSending`), the literal "se
o modelo selecionado não estiver carregado, ao mandar uma mensagem ele
se carrega automaticamente." If that doesn't fit the remaining unified-
memory budget, every other currently-loaded model — text and image,
since they share one `ResidencyPlanner` budget — is unloaded first,
automatically: "se não houver memória ele descarrega os modelos ativos
antes de carregar o necessário." Deliberately **no confirmation** here,
unlike the memory digest's own on-demand load
(`ensureModelLoadedForSuggestions`, `0.15.0`) — that one asks first
because the model it loads is incidental to the conversation you're
having; this one is the model you explicitly picked to chat with, so
swapping what's resident to honor that just happens. `syncSelectedModel`
no longer resets the selection back to a loaded model the instant any
session's status changes elsewhere — that used to undo this same
choice on its own before a message was even sent.

**iOS.** `NativeChatEngine` only ever holds one model at a time, so
there's no separate memory-budget check to make: `load(modelID:)`
already discards whatever was previously resident on its own. The gap
was purely in the UI — the model ID field and its "pick a registered
model" menu both disabled themselves the moment something was loaded,
requiring an explicit Unload first to change anything. Now both stay
live throughout, `canSend`/`sendLocal` no longer require `engine
.isLoaded` up front, and sending loads (or swaps to) whichever model is
currently typed/picked before generating. Profile already had its own
visible, chat-based `profileBar` here (`0.9.x`) — nothing to fix on
that side.

## Hugging Face and CivitAI keys sync via iCloud

Requested live: "vamos criar os campos onde as Keys do Huggs e do
Civitai ficam armazenadas e sincronizadas o iCloud assim não preciso
recadastrar elas depois de feito em um dos dois devices" — the fields
themselves already existed (Mac's Models tab, iOS's Settings screen,
both backed by the same cross-platform `HFTokenStore`/
`CivitAITokenStore`), but each only ever wrote to that one device's own
local keychain — setting a token on the Mac never showed up on the
phone, or vice versa.

**Why a plain `kSecAttrSynchronizable` flip wasn't enough.** The
obvious first fix — add `kSecAttrSynchronizable: true` to the existing
`SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` calls — compiles
fine and looks like it should just work, but confirmed directly against
a real, properly Developer-ID-signed binary: `SecItemAdd` fails
outright with `errSecMissingEntitlement` (`-34018`) the moment
`kSecAttrSynchronizable` is `true`, even for an app that's otherwise
validly signed with a real Team ID and no sandbox restrictions. Plain,
non-synced keychain items have no such requirement, which is exactly
why nobody had hit this before — nothing had ever asked for a synced
item until now. The fix is a `keychain-access-groups` entitlement
(the "Keychain Sharing" capability) — confirmed by adding it to a
throwaway signed test binary and watching the identical `SecItemAdd`
call start returning `errSecSuccess`.

**Why the two platforms need to agree on one specific group name.**
Mac and iOS are two different bundle identifiers
(`com.viniciuscotrim.anvil` vs `.anvil.ios`), so left to their own
defaults each would get its own separate implicit keychain group —
both would sync fine via iCloud, just never with *each other*, since
an iCloud-synced keychain item only ever propagates within the access
group it was saved under. Fixed by declaring one explicit, shared group
— `U3H5DHZP65.com.viniciuscotrim.anvil.credentials` — in both targets'
`keychain-access-groups` entitlement (iOS's added through
`AnvilIOS/project.yml`'s own `entitlements.properties`, since
`xcodegen generate` regenerates `AnvilIOS.entitlements` from there on
every run — editing the checked-in file directly doesn't survive the
next regeneration) and passing it explicitly as `kSecAttrAccessGroup`
on every keychain call in both stores, rather than trusting either
platform's own implicit default.

**Migration.** `load()` now checks, in order: the current shared+synced
item; the same shared group without the sync flag (a transient shape
that shouldn't really persist, but cheap to also cover); and finally
the exact shape a pre-this-feature version of Anvil used — no explicit
access group, no sync flag at all. Whichever one is found is
immediately re-saved into the new shared+synced shape via `save()`
(which also deletes the older copies it replaces), so the fallback
path only ever runs once per device — a token set months ago on either
platform keeps working without the user having to re-enter anything,
and then starts syncing from that point on.

Deliberately **not** gated behind the app's own `isCloudSyncEnabled`
toggle (`CloudSyncEngine`, threads/profiles/memories/suggestions) —
a credential isn't conversation data, and tying it to a setting most
people leave off by default would defeat the entire point. The only
external requirement is each device's own system-wide iCloud Keychain
setting being on, which it is by default for most users and is outside
this app's control either way — the same standard mechanism any other
app relying on `kSecAttrSynchronizable` depends on.

## A Search tab on Mac, and downloads that survive backgrounding on iOS

Three related asks in one message.

**A Search tab on Mac.** Requested live: "vamos separar a busca e
download de modelos em uma nova aba/menu chamado Search, e os modelos
Registrados ficam onde estão agora. Igual já temos no iPhone" — iOS
already drew this line between `ModelSearchView` and `ModelLibraryView`
(both backed by one shared `ModelsViewModel`); Mac's old
`ModelManagerView` mixed both into a single screen. Split into
`ModelSearchView` (Hugging Face/CivitAI/Draw Things search, downloads
in progress, results, the models-folder setting) and `ModelLibraryView`
(the registered library, keeping the "Models" name and its place in
the tab bar), both still backed by the one shared
`ModelManagerViewModel` — exactly the iOS pattern, mirrored.

This wasn't just a rename: the old combined screen stacked every one of
those pieces — source picker, search bar, live downloads, a results
list, the models-folder row, *and* the entire registered library — in
one plain, unscrollable `VStack`. At the window's old minimum size that
didn't fit, and reported live as menus visually sitting on top of each
other: "quando o app abre tem menus como Hugging Face/CivitAI etc sobre
[os] menus como Models/Chat/etc." Both new tabs are a `List` with
defined `Section`s instead — every part gets a fixed place and the
whole thing scrolls internally on its own, the exact fix `MemoryView`
already got for an identical complaint ("Memory digest: real progress,
a real scrollbar" above).

**One minimum window size for the whole app.** Requested in the same
message: "o app no Mac precisa ter um tamanho mínimo de interface pra
não quebrar visualmente e exigir o usuário de ajustar o tamanho do app
quando ele é instalado." Every tab used to declare its own
`.frame(minWidth:minHeight:)` — 480×480 for Chat's content pane,
560×420 for the old combined Models screen, 520×420 for Profiles, and
so on — and since `.windowResizability(.contentSize)` derives the
window's actual resize limits from whichever tab is currently showing,
the *effective* minimum kept changing (and shrinking) depending on
which tab was active, which is exactly how the layout bug above could
happen at all. `RootView` now wraps the whole tab bar + content area in
one `.frame(minWidth: 900, minHeight: 640)` — comfortably larger than
any single tab's own minimum — so the window can still grow for a tab
that needs more room (Chat with both side panels open, say) but can
never be resized smaller than what every tab needs to render correctly,
on a fresh install or any time after.

**Downloads that survive backgrounding on iOS.** Requested live:
"vamos no iPhone atualizar pra que ele consiga continuar fazendo o
download do modelo mesmo que a tela bloquear ou trocar de app."
`URLDownloader` (what both `HFRepoDownloader` and `CivitAIDownloader`
called, on both platforms) used a plain foreground
`URLSession(configuration: .default, …)` — fine on Mac, which has no
suspension model to begin with, but on iOS the moment this app's own
process is suspended (the screen locks, or the user switches away),
that session's sockets are suspended right along with it, stalling a
multi-gigabyte GGUF mid-transfer.

New `BackgroundDownloadCoordinator` (iOS-only, gated by `#if
os(iOS)` — Mac's own path through `URLDownloader` is untouched) routes
iOS downloads through a real background session
(`URLSessionConfiguration.background(withIdentifier:)`) instead,
handing the transfer to the system's own daemon so it keeps moving
independent of whether this app is suspended, backgrounded, or even
terminated outright by jetsam — the same mechanism Podcasts/Music/the
App Store itself use for exactly this kind of long transfer.

The one real wrinkle a background session adds over a foreground one:
if iOS fully terminates the app mid-transfer, there's no live Swift
`Task`/continuation left anywhere to resume once it finishes — the
next thing that runs is a fresh process, reconnecting a session under
the identical identifier (`reconnectIfNeeded()`, called from
`AnvilIOSApp.init`, and from a new `AnvilIOSAppDelegate`'s
`handleEventsForBackgroundURLSession`, the documented hook iOS uses to
wake an app specifically to hand back exactly this). To finish the job
with zero reliance on any of that in-memory state surviving, every
task's own `taskDescription` — a plain string iOS itself persists and
restores alongside the transfer, not this app's memory — carries the
one thing actually needed: where the finished file belongs. The
delegate moves it there directly, whether or not anything is still
waiting on a continuation for that task when it happens.

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

# Build Brief: "Anvil" — Unified Local Model Engine (MVP)
*Working title — rename freely. Hand this whole file to a fresh Claude Code session.*

## Objective

Replace three separate pieces of the current Westworld stack — **oMLX** (LLM serving), **Draw Things** (image generation), and the standalone **flux_server.py** Flask wrapper (port 8200) — with **one app, built from scratch**, on the M4 Pro Mac that:

1. Downloads models from Hugging Face and can also import already-downloaded ones
2. Generates images (and, later, video) from Flux-family models, both standalone and inline in chat
3. Runs multiple models at the same time (text + image + voice loaded together, not swapped in and out)
4. Adds voice chat: speak → transcribed into the chat → response as text and/or spoken back

The rest of the Westworld stack (VPS on Tailscale, persona proxies Sofia :8003 / Bernard :8002 / Monet :8001 / Westworld Host :8005 / Mesa de Controle :8006, Qdrant, Open WebUI) must keep working unmodified — they all talk to the LLM backend over the same OpenAI-compatible API on port 8000 today, and that contract cannot break.

**This is a from-scratch build.** No existing third-party app or server is forked, wrapped, or evaluated as a substitute. Standard libraries (mlx-lm, mflux, mlx-audio, huggingface_hub) are used as dependencies — the same way any app depends on libraries — but every line of serving, orchestration, and UI code is yours.

---

## Zero-friction install and dependency system (this is a core deliverable, not an afterthought)

The user installs a `.dmg`, drags it to Applications, opens it, picks a model, and starts talking to it. Nothing else. No terminal, ever, no README, no manual `pip install` or `brew install` of anything, at any point, for any feature.

**The rule for every dependency, no exceptions:** does the app need X? Check if it's already present. If not, install it silently. Never surface a command for the user to run themselves.

Concretely:

- The app owns a **private runtime** — its own Application Support directory containing an isolated Python environment. It never touches, depends on, or modifies the user's system Python.
- **Bootstrap mechanism:** use `uv`'s standalone installer to stand up that private Python environment. It's a single static binary, needs neither Homebrew nor an existing Python to install itself, and — unlike Homebrew's first-time install — doesn't require a macOS admin-password prompt. This gets you from zero to "ready" with no interruption at all.
- **On Homebrew specifically:** the check-then-install pattern still applies if anything the app needs genuinely requires it (e.g., a system library like `ffmpeg` for audio handling). But don't reach for Homebrew as the primary bootstrap path — worth knowing going in that Homebrew's very first install on a clean Mac does require one macOS admin-password prompt, which is an OS-level requirement no app can silence. Using `uv` directly for the Python side avoids that entirely; only fall back to checking/installing Homebrew if a specific, real need for it turns up during the build.
- **Installation is modular and lazy — nothing installs until the user's own choice requires it:**
  - First launch → only enough installs to browse and pick a model (the Hugging Face client)
  - User selects a text/chat model → `mlx-lm` installs, silently, at that moment, not before
  - User selects an image-capable model → `mflux` installs, silently, at that moment, not before
  - User taps the mic / enables voice chat → `mlx-audio` installs, silently, at that moment, not before
- Every install step shows, at most, one friendly status line with a progress bar ("Setting up image generation…"). Never a terminal window. Never raw `pip`/`brew` output.

**The bar for "done":** if installing this app and picking a model feels like anything other than "wait, that's it?" — it's not done. The only manual decision the user ever makes is which model to use.

---

## Architecture

- Single native SwiftUI macOS app — this is the entire `.dmg` deliverable
- The app manages its own backend Python process, running inside the private venv described above, built on `mlx-lm` (text), `mflux` (image), `mlx-audio` (voice) as dependencies
- OpenAI-compatible API on port 8000 — a drop-in replacement for oMLX, zero config changes needed on any persona proxy

---

## Phase 1 — Requirements Manager (build this first, it's the foundation everything else sits on)

- A checklist component: each dependency has a **check** function (is this already satisfied?) and an **install** function (silent, non-interactive), triggered lazily per the rules above
- **Gate:** on a clean macOS user account with nothing pre-installed, install the `.dmg`, launch the app, select a text model — confirm zero terminal windows ever appeared, confirm a working chat response, and log exactly what installed and how long it took. Then confirm separately that picking only a text model did **not** install `mflux` or `mlx-audio` — those must stay uninstalled until image generation or voice is actually used.

## Phase 2 — Model manager (HF download + import)

- Build the browse/search/download UI against Hugging Face directly (`huggingface_hub`)
- Local import: point at an existing model folder (e.g. today's oMLX model directory) and register it without re-downloading anything already on disk
- **Gate:** download one model from a cold state, import one already-existing model from disk, both confirmed via a printed model registry — not "it looked fine in the UI"

## Phase 3 — LLM serving: oMLX replacement on port 8000

- `mlx-lm`-based serving of `/v1/chat/completions` and `/v1/models`, same shape oMLX serves today
- **Gate:** the Sofia persona proxy (:8003) gets a valid response through the new backend with zero changes on the proxy side. Only after this passes: retire oMLX for good.

## Phase 4 — Image generation: Draw Things + flux_server.py replacement

- `mflux`-based Flux serving (Schnell and/or Dev), your own `/v1/images/generations` endpoint, your own UI
- Inline generation: give the chat LLM a tool it can call (e.g. `generate_image(prompt)`) mid-conversation
- **Gate:** generate an image via direct API call and via a normal chat request, confirm output lands where the current workflow expects it, then retire `flux_server.py` and its port-8200 listener

## Phase 5 — Concurrent multi-model residency

- Known hardware constraint on this exact Mac: **~18.55GB usable after kernel tuning on 24GB unified memory** — build a memory-budget manager for this yourself (load / unload / queue policy), since there's no third-party gateway to lean on here
- **Gate:** load the daily-driver LLM + Flux + Whisper + Kokoro simultaneously, log real measured memory usage on the actual Mac, and write down the working combination (or the point it breaks and the fallback combination that doesn't)

## Phase 6 — Voice chat

- `mlx-audio`-based Whisper (STT) and Kokoro (TTS)
- Push-to-talk for the MVP (hold a button while speaking) — simplest, avoids a background-audio entitlement fight
- **Gate:** speak a real question, see an accurate transcript appear as your chat message, get a text reply, confirm the "speak it back" toggle produces audible output

---

## Non-goals for this MVP (explicit, to prevent scope creep)

- No video generation — no mature MLX-native option exists yet; revisit later
- No iPhone client yet — next phase, after this Mac-side engine is solid
- No Messages/Mail reading integration — separate future phase
- No exposure beyond the existing Tailscale network
- No GGUF/llama.cpp fallback unless a specific wanted model has no MLX version

## Deliverable

A single `.dmg` that, once installed, needs nothing from the user but a model choice — no terminal, no manual dependency setup, ever — and that fully replaces oMLX, Draw Things, and flux_server.py while keeping the existing persona proxies working unmodified.

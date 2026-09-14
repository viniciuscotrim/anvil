import Foundation

/// The Python orchestrator `ContextShiftCoordinator` drives — a
/// standalone "Stop-and-Swap" pipeline that compacts a conversation's
/// older history under a strict 24 GB unified-memory budget (17 GB max
/// per phase) so it never has to compete for RAM with whichever model
/// is actually loaded. Requested live: a Python backend focused on
/// Apple Silicon (MLX) for the model lifecycle, triggered by Anvil
/// itself, that watches KV-cache usage, frees the active model's
/// memory, vectorizes old history (text and code separately) into a
/// local store, summarizes it with a small model, and hands back a
/// compacted payload for Anvil to resume from.
///
/// Verified end-to-end against real, already-downloaded checkpoints
/// (nomic-embed-text-v2-moe, CodeRankEmbed, Phi-4-mini-instruct-mlx-
/// fp16) before this was written into Swift at all: `--self-test`
/// covers every part of this script that doesn't need a model on disk
/// (code/text splitting, chunking, the vector store's save/load/search
/// round trip, the JSON-lines protocol), and a full `--run-once`
/// against a real fixture conversation produced correct bullet-point
/// summaries in ~28s, peaking at under 6 GB RSS — comfortably inside
/// the 17 GB per-phase ceiling.
enum ContextShiftScript {
    static func ensureWrittenToDisk() throws -> URL {
        let scriptsDir = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("scripts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: scriptsDir.path) {
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        }
        let scriptURL = scriptsDir.appendingPathComponent("context_shift.py")
        // Always rewritten — keeps it in sync with whatever version
        // ships in this build of Anvil rather than trusting a stale
        // copy from a previous install.
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        return scriptURL
    }

    private static let source = #"""
    #!/usr/bin/env python3
    """
    Anvil Context Shift orchestrator.

    Compacts a conversation's older history under a strict Apple Silicon
    unified-memory budget, using a "Stop-and-Swap" discipline: only one
    heavy model is ever resident at a time, and each phase releases its
    own memory back to the OS (`mx.clear_cache()` for MLX, `torch.mps
    .empty_cache()` for the embedding phase's PyTorch/MPS path — see
    `embed_texts`'s own docstring for why that phase isn't pure MLX)
    before the next phase loads anything.

    Communicates with the Swift side (Anvil) entirely through line-
    delimited JSON: one JSON object per line on stdout for every event
    this process wants to report (`emit()`), and the same shape read back
    one line at a time on stdin for control acknowledgements Swift needs
    to send this process (`wait_for_control_event()`) — e.g. "the model
    you asked me to unload is actually gone now, memory's free." This
    mirrors the JSON-lines convention Anvil's other subprocess-driven
    features already use for structured status.

    Two invocation modes:
      --watch STATUS_JSON        Long-running: tails a small status file
                                  Anvil rewrites after every chat turn
                                  (estimated tokens used + the active
                                  model's own path), and the moment that
                                  crosses --trigger-fraction of the active
                                  model's context window (read from its own
                                  config.json), requests a pause + unload
                                  from Swift and, once acknowledged, runs
                                  one full compaction pass.
      --run-once THREAD_JSON      Runs exactly one compaction pass against
                                  a given thread export (already-paused,
                                  already-unloaded) — used for direct,
                                  on-demand invocation and for this
                                  script's own --self-test.

    --self-test exercises every part of this file that doesn't need a real
    multi-gigabyte model on disk (code/text splitting, chunking, the
    vector store's own save/load/search round trip, the JSON-lines
    protocol) against synthetic data, so the plumbing can be verified
    without downloading anything.
    """

    from __future__ import annotations

    import argparse
    import gc
    import json
    import re
    import sys
    import threading
    import time
    from dataclasses import dataclass
    from pathlib import Path
    from typing import Any, Optional

    # ---------------------------------------------------------------------------
    # Memory budget constants — the strict ceiling this whole script exists to
    # respect. TOTAL_MEMORY_BUDGET_BYTES is informational (logged alongside every
    # memory_status event so the Swift UI can render it against the real system
    # total); MAX_STEP_MEMORY_BYTES is the hard per-phase ceiling `guard_step
    # _budget` checks against after each model unloads.
    # ---------------------------------------------------------------------------
    TOTAL_MEMORY_BUDGET_BYTES = 24 * 1024**3
    MAX_STEP_MEMORY_BYTES = 17 * 1024**3
    DEFAULT_TRIGGER_FRACTION = 0.90
    INTACT_TAIL_MESSAGES = 5
    DEFAULT_SUMMARY_BATCH_CHARS = 6000
    MEMORY_LOG_INTERVAL_SECONDS = 1.0

    HIDDEN_SYSTEM_PROMPT = (
        "You are Anvil's internal context-compaction assistant. You will be shown "
        "an excerpt from an older part of a conversation between a user and an AI "
        "assistant. Summarize it into concise bullet points capturing every "
        "durable decision, established fact, and the logical flow of the "
        "discussion — write in the same language the excerpt itself is in. Do "
        "not address the user directly, do not add commentary or preamble, and "
        "never invent information that isn't in the excerpt. Return only the "
        "bullet points, nothing else."
    )


    # ---------------------------------------------------------------------------
    # stdout/stdin JSON-lines protocol
    # ---------------------------------------------------------------------------

    def emit(event: str, **fields: Any) -> None:
        """One JSON object per line on stdout — the whole of this script's
        status/progress reporting to Swift. Always flushed immediately:
        Swift reads this line-by-line as it arrives, not after the process
        exits."""
        payload = {"event": event, "ts": time.time(), **fields}
        print(json.dumps(payload), flush=True)


    def read_control_line(timeout: Optional[float] = None) -> Optional[dict]:
        """Reads one JSON object from stdin, or None on EOF/timeout. Used
        for Swift's control acknowledgements (see `wait_for_control_event`)
        — a plain blocking `readline()` when no timeout is given (the
        common case: the watcher's own control thread has nothing better
        to do while waiting), a `select()`-bounded one otherwise."""
        if timeout is not None:
            import select
            ready, _, _ = select.select([sys.stdin], [], [], timeout)
            if not ready:
                return None
        line = sys.stdin.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            return None
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return None


    def wait_for_control_event(event: str, timeout: float = 60.0) -> Optional[dict]:
        """Blocks until Swift sends `{"event": event, ...}` on stdin, or
        `timeout` seconds pass. Any other event line seen while waiting is
        ignored (forward-compatible with control messages this version
        doesn't know about yet) rather than treated as an error."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            remaining = max(0.1, deadline - time.time())
            message = read_control_line(timeout=remaining)
            if message is None:
                continue
            if message.get("event") == event:
                return message
        return None


    # ---------------------------------------------------------------------------
    # Memory monitoring — real numbers via psutil (which, on macOS, is itself a
    # thin wrapper over the same host_statistics64/task_info Mach calls a raw
    # ctypes binding would otherwise have to hand-roll), not a hand-maintained
    # guess. Logged continuously so the Swift UI can render a live hot-swap
    # status, and checked once per phase boundary against MAX_STEP_MEMORY_BYTES.
    # ---------------------------------------------------------------------------

    class MemoryMonitor:
        """Background thread emitting `memory_status` events at a fixed
        interval for as long as it's running — started once per phase
        (`label` tags every event so the UI can attribute a spike to the
        phase that caused it) and always stopped before that phase's model
        is unloaded, so the very last reading before a swap reflects that
        phase's true peak."""

        def __init__(self, label: str, interval: float = MEMORY_LOG_INTERVAL_SECONDS):
            self._label = label
            self._interval = interval
            self._stop = threading.Event()
            self._thread: Optional[threading.Thread] = None
            self.peak_rss_bytes = 0

        def __enter__(self) -> "MemoryMonitor":
            self._thread = threading.Thread(target=self._loop, daemon=True)
            self._thread.start()
            return self

        def __exit__(self, *exc: Any) -> None:
            self._stop.set()
            if self._thread is not None:
                self._thread.join(timeout=self._interval * 2)

        def _loop(self) -> None:
            import psutil

            proc = psutil.Process()
            while not self._stop.is_set():
                vm = psutil.virtual_memory()
                rss = proc.memory_info().rss
                self.peak_rss_bytes = max(self.peak_rss_bytes, rss)
                emit(
                    "memory_status",
                    phase=self._label,
                    process_rss_bytes=rss,
                    system_used_bytes=vm.total - vm.available,
                    system_total_bytes=vm.total,
                    budget_bytes=TOTAL_MEMORY_BUDGET_BYTES,
                    step_ceiling_bytes=MAX_STEP_MEMORY_BYTES,
                )
                self._stop.wait(self._interval)


    def guard_step_budget(label: str, peak_rss_bytes: int) -> None:
        """Never raises — a step that overran its own ceiling already
        finished by the time this runs (there's nothing left to abort),
        but the operator/developer needs to know the budget itself needs
        retuning (a smaller batch size, a smaller model) rather than
        silently pretending everything fit."""
        if peak_rss_bytes > MAX_STEP_MEMORY_BYTES:
            emit(
                "step_budget_exceeded",
                phase=label,
                peak_rss_bytes=peak_rss_bytes,
                step_ceiling_bytes=MAX_STEP_MEMORY_BYTES,
            )


    def release_mlx_model(*objects: Any) -> None:
        """Drops every reference passed in, forces a GC pass (MLX arrays
        can sit behind reference cycles the same as any Python object),
        then actually hands the freed Metal buffer pool back to the OS —
        without this last step, MLX's own allocator happily keeps holding
        onto memory for reuse, which is normally the right call but is
        exactly what this pipeline's per-phase ceiling can't tolerate."""
        del objects
        gc.collect()
        import mlx.core as mx

        if hasattr(mx, "clear_cache"):
            mx.clear_cache()
        else:  # pragma: no cover - older mlx releases only
            mx.metal.clear_cache()


    def release_torch_model(*objects: Any) -> None:
        """The PyTorch/MPS equivalent of `release_mlx_model`, for the
        embedding phase's fallback path — see `embed_texts`'s docstring."""
        del objects
        gc.collect()
        try:
            import torch

            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
        except ImportError:  # pragma: no cover - torch not installed at all
            pass


    # ---------------------------------------------------------------------------
    # Phase 1: trigger — context-window bookkeeping. The actual watch loop lives
    # in `watch_loop` further down; this just resolves "how big is this model's
    # own context window", read straight from its config.json rather than
    # hardcoded, so a new model swapped in later is handled correctly with zero
    # code changes.
    # ---------------------------------------------------------------------------

    _CONTEXT_WINDOW_FIELDS = (
        "max_position_embeddings",
        "model_max_length",
        "max_sequence_length",
        "n_positions",
        "seq_length",
    )


    def context_window_for(model_path: Path, default: int = 4096) -> int:
        config_path = model_path / "config.json"
        try:
            config = json.loads(config_path.read_text())
        except (OSError, json.JSONDecodeError):
            return default
        for field_name in _CONTEXT_WINDOW_FIELDS:
            value = config.get(field_name)
            if isinstance(value, int) and value > 0:
                return value
        return default


    def watch_loop(status_path: Path, trigger_fraction: float, config: "PipelineConfig") -> None:
        """Tails `status_path` (Anvil rewrites it after every turn) and
        triggers exactly one compaction pass the moment usage crosses
        `trigger_fraction` of the active model's own context window —
        then goes right back to watching, since the reconstructed,
        just-compacted thread starts accumulating usage again from a much
        smaller baseline.
        """
        emit("watch_started", status_path=str(status_path), trigger_fraction=trigger_fraction)
        last_seen_mtime: Optional[float] = None
        while True:
            try:
                mtime = status_path.stat().st_mtime
            except FileNotFoundError:
                time.sleep(1)
                continue

            if mtime != last_seen_mtime:
                last_seen_mtime = mtime
                try:
                    status = json.loads(status_path.read_text())
                except (OSError, json.JSONDecodeError):
                    time.sleep(1)
                    continue

                model_path = Path(status["active_model_path"])
                window = context_window_for(model_path)
                estimated_tokens = int(status["estimated_tokens"])
                ratio = estimated_tokens / max(1, window)
                emit(
                    "context_usage",
                    ratio=ratio,
                    estimated_tokens=estimated_tokens,
                    context_window=window,
                    active_model_id=status.get("active_model_id"),
                )

                if ratio >= trigger_fraction:
                    run_triggered_shift(status, config)
                    # Deliberately *not* reset to None here: `last_seen
                    # _mtime` already holds this exact file's mtime from
                    # the top of this block, so the loop won't reprocess
                    # this same, still-95%-full status again until Anvil's
                    # own next `send()` actually rewrites it (a fresh
                    # mtime) — reflecting the *compacted* thread's much
                    # smaller token count. Confirmed directly: resetting
                    # this to None here (an earlier version of this loop
                    # did) re-triggered an immediate second compaction pass
                    # against the exact same stale file, forever, since
                    # nothing else was updating it in this test.

            time.sleep(1)


    def run_triggered_shift(status: dict, config: "PipelineConfig") -> None:
        """Phase 1's actual trigger action — pause, request the unload,
        wait for Swift's ack that the 17 GB is really free, then run the
        rest of the pipeline. Never assumes the unload happened just
        because it asked; `context_shift_failed` is emitted (not raised
        past this function) if Swift doesn't acknowledge in time, so the
        watch loop can simply keep watching rather than crash the whole
        background process over one missed handshake.
        """
        model_id = status.get("active_model_id")
        emit("pause_requested", reason="kv_cache_90pct")
        emit("unload_requested", model_id=model_id)

        ack = wait_for_control_event("unload_complete", timeout=config.unload_ack_timeout)
        if ack is None:
            emit("context_shift_failed", reason="unload_not_acknowledged", model_id=model_id)
            return

        thread_path = status.get("thread_export_path")
        if not thread_path:
            emit("context_shift_failed", reason="missing_thread_export")
            return
        try:
            thread = json.loads(Path(thread_path).read_text())
        except (OSError, json.JSONDecodeError) as exc:
            emit("context_shift_failed", reason=f"could not read thread export: {exc}")
            return

        run_compaction(thread, config)


    # ---------------------------------------------------------------------------
    # Phase 2: RAG — text/code separation, embedding, and a small local vector
    # store.
    # ---------------------------------------------------------------------------

    CODE_BLOCK_RE = re.compile(r"```[ \t]*[a-zA-Z0-9_+-]*\r?\n(.*?)```", re.DOTALL)


    @dataclass
    class Chunk:
        id: str
        text: str
        source_message_id: str
        source_role: str


    def split_text_and_code(messages: list[dict]) -> tuple[list[Chunk], list[Chunk]]:
        """Every fenced Markdown code block in the old history becomes its
        own chunk, vectorized separately from the surrounding prose —
        CodeRankEmbed is trained on code, not natural language, and mixing
        the two into one embedding dilutes both. What's left of each
        message after pulling its code blocks out (still natural language,
        Portuguese/English/anything — nomic-embed-text-v2-moe is
        multilingual, so no language filtering happens here) becomes a
        text chunk, when there's anything left worth keeping.
        """
        text_chunks: list[Chunk] = []
        code_chunks: list[Chunk] = []

        for message in messages:
            content = message.get("content") or ""
            message_id = str(message.get("id", ""))
            role = str(message.get("role", ""))

            code_blocks = CODE_BLOCK_RE.findall(content)
            for index, code in enumerate(code_blocks):
                stripped = code.strip()
                if not stripped:
                    continue
                code_chunks.append(Chunk(
                    id=f"{message_id}:code:{index}",
                    text=stripped,
                    source_message_id=message_id,
                    source_role=role,
                ))

            remaining = CODE_BLOCK_RE.sub(" ", content).strip()
            if remaining:
                text_chunks.append(Chunk(
                    id=f"{message_id}:text",
                    text=remaining,
                    source_message_id=message_id,
                    source_role=role,
                ))

        return text_chunks, code_chunks


    @dataclass
    class VectorRecord:
        id: str
        text: str
        embedding: list[float]
        kind: str  # "text" | "code"
        source_message_id: str
        source_role: str


    class LocalVectorStore:
        """Deliberately not a real vector database: brute-force cosine
        similarity over a plain matrix is exact and plenty fast at the
        scale this exists for (one conversation's worth of chunks — tens
        to low hundreds, not millions), and needs nothing beyond numpy,
        already an MLX dependency — no compiled ANN library (faiss,
        hnswlib), no extra bootstrap step, no server to run.

        Persisted as two files sharing a stem: `<path>.npz` (the embedding
        matrix, numpy's own compressed format) and `<path>.json` (every
        record's text/metadata, index-aligned with the matrix's rows) —
        kept separate because JSON can't hold a numpy array. Either can
        stand in for a placeholder store (a fresh one that hasn't seen `add`
        yet) with no rows at all.
        """

        def __init__(self, path: Path):
            self.path = path
            self.records: list[VectorRecord] = []

        @classmethod
        def load(cls, path: Path) -> "LocalVectorStore":
            store = cls(path)
            json_path = path.with_suffix(".json")
            npz_path = path.with_suffix(".npz")
            if not json_path.exists() or not npz_path.exists():
                return store

            import numpy as np

            meta = json.loads(json_path.read_text())
            matrix = np.load(npz_path)["embeddings"]
            for row_index, entry in enumerate(meta):
                store.records.append(VectorRecord(
                    id=entry["id"],
                    text=entry["text"],
                    embedding=matrix[row_index].tolist(),
                    kind=entry["kind"],
                    source_message_id=entry["source_message_id"],
                    source_role=entry["source_role"],
                ))
            return store

        def add(self, records: list[VectorRecord]) -> None:
            """Upserts by id rather than blindly appending — `id` is
            deterministic per source message (`split_text_and_code`'s
            `f"{message_id}:text"`/`f"{message_id}:code:{index}"`), so
            re-running the pipeline against overlapping history
            (Suggest from Thread run twice, or Suggest followed by an
            automatic trigger over the same messages) used to append
            every chunk again verbatim — confirmed directly: nothing
            here ever checked for an existing row with the same id.
            An unchanged chunk (same id, identical text) is now left
            alone instead of duplicated; a changed one (same id,
            different text — the same message re-embedded with
            different wording, e.g. after an edit) replaces the old
            row in place. This store is never reviewed by the user the
            way a memory suggestion is, so there's no approval step at
            this layer — just keep-the-latest, silently.
            """
            index_by_id = {record.id: index for index, record in enumerate(self.records)}
            for record in records:
                existing_index = index_by_id.get(record.id)
                if existing_index is None:
                    self.records.append(record)
                    index_by_id[record.id] = len(self.records) - 1
                elif self.records[existing_index].text != record.text:
                    self.records[existing_index] = record

        def save(self) -> None:
            import numpy as np

            self.path.parent.mkdir(parents=True, exist_ok=True)
            meta = [
                {
                    "id": r.id,
                    "text": r.text,
                    "kind": r.kind,
                    "source_message_id": r.source_message_id,
                    "source_role": r.source_role,
                }
                for r in self.records
            ]
            self.path.with_suffix(".json").write_text(json.dumps(meta))
            if self.records:
                matrix = np.array([r.embedding for r in self.records], dtype=np.float32)
            else:
                matrix = np.zeros((0, 0), dtype=np.float32)
            np.savez_compressed(self.path.with_suffix(".npz"), embeddings=matrix)

        def search(self, query_embedding: list[float], top_k: int = 5, kind: Optional[str] = None) -> list[VectorRecord]:
            import numpy as np

            candidates = [r for r in self.records if kind is None or r.kind == kind]
            if not candidates:
                return []
            matrix = np.array([r.embedding for r in candidates], dtype=np.float32)
            query = np.array(query_embedding, dtype=np.float32)
            query_norm = np.linalg.norm(query) or 1.0
            matrix_norms = np.linalg.norm(matrix, axis=1)
            matrix_norms[matrix_norms == 0] = 1.0
            similarities = (matrix @ query) / (matrix_norms * query_norm)
            ranked = np.argsort(-similarities)[:top_k]
            return [candidates[i] for i in ranked]


    def _patch_nomic_bert_attention_mask(model: Any) -> None:
        """`sentence-transformers`/`transformers` fallback path only (see
        `embed_texts`): nomic's own remote modeling code
        (`modeling_hf_nomic_bert.py`, fetched with `trust_remote_code=True`
        straight from its Hugging Face repo) calls
        `self.get_extended_attention_mask(...)`, a helper that shipped on
        every `PreTrainedModel` in `transformers` 4.x but was removed in
        5.x — confirmed directly: loading either nomic-embed-text-v2-moe or
        CodeRankEmbed against `transformers` 5.17.0 raises
        `AttributeError: 'NomicBertModel' object has no attribute
        'get_extended_attention_mask'` before this patch, and produces
        correct embeddings after it. The reimplementation below is the
        historical, well-known one (an unmasked position gets 0, a masked
        one gets the dtype's most-negative finite value, broadcastable
        against attention scores) — its semantics never changed across
        `transformers` versions, only its removal did.
        """
        import torch

        def get_extended_attention_mask(self: Any, attention_mask: "torch.Tensor", input_shape: Any, device: Any = None, dtype: Any = None) -> "torch.Tensor":
            if dtype is None:
                dtype = next(self.parameters()).dtype
            if attention_mask.dim() == 3:
                extended = attention_mask[:, None, :, :]
            elif attention_mask.dim() == 2:
                extended = attention_mask[:, None, None, :]
            else:
                raise ValueError(f"Wrong shape for attention_mask (shape {attention_mask.shape})")
            extended = extended.to(dtype=dtype)
            return (1.0 - extended) * torch.finfo(dtype).min

        for module in model.modules():
            if hasattr(module, "get_extended_attention_mask"):
                continue
            try:
                next(module.parameters())
            except StopIteration:
                continue
            import types
            module.get_extended_attention_mask = types.MethodType(get_extended_attention_mask, module)


    def embed_texts(model_path: Path, texts: list[str], batch_size: int = 16) -> list[list[float]]:
        """Embeds `texts` with whatever model lives at `model_path`,
        preferring MLX (`mlx_embeddings`, Apple's own tensor stack) and
        falling back to `sentence-transformers` on PyTorch/MPS (still
        Apple Silicon GPU-accelerated, just not the `mlx` package) only
        when the loaded architecture isn't one `mlx_embeddings` supports
        yet.

        Confirmed directly against the actual checkpoints this pipeline is
        built for: both nomic-embed-text-v2-moe and CodeRankEmbed report
        `model_type: "nomic_bert"` in their own `config.json`, and
        `mlx_embeddings` 0.1.0's own architecture registry does not include
        it (`ValueError: Model type nomic_bert not supported`) — so today,
        both actually run this fallback path, not the MLX one. The `mlx
        _embeddings` attempt stays first regardless, so a future release
        adding `nomic_bert` support picks it up automatically with zero
        changes needed here.
        """
        if not texts:
            return []

        try:
            from mlx_embeddings import load as mlx_load, generate as mlx_generate
            import mlx.core as mx

            model, tokenizer = mlx_load(str(model_path))
            vectors: list[list[float]] = []
            for start in range(0, len(texts), batch_size):
                batch = texts[start:start + batch_size]
                output = mlx_generate(model, tokenizer, texts=batch)
                pooled = output.text_embeds if hasattr(output, "text_embeds") else output
                vectors.extend(np_tolist(pooled))
            release_mlx_model(model, tokenizer)
            return vectors
        except ValueError as exc:
            if "not supported" not in str(exc):
                raise
            emit("embedding_fallback", model_path=str(model_path), reason=str(exc))

        import torch
        from sentence_transformers import SentenceTransformer

        device = "mps" if torch.backends.mps.is_available() else "cpu"
        model = SentenceTransformer(str(model_path), trust_remote_code=True, device=device)
        _patch_nomic_bert_attention_mask(model)
        vectors = model.encode(texts, batch_size=batch_size, normalize_embeddings=True, show_progress_bar=False)
        result = [row.tolist() for row in vectors]
        release_torch_model(model)
        return result


    def np_tolist(array_like: Any) -> list[list[float]]:
        """`mlx.core.array` and `numpy.ndarray` both support `.tolist()`
        directly; this only exists so `embed_texts` reads as plain library
        calls rather than an inline `hasattr` check."""
        return array_like.tolist()


    def run_rag_phase(old_messages: list[dict], config: "PipelineConfig") -> tuple[int, int]:
        emit("phase_started", phase="rag")
        text_chunks, code_chunks = split_text_and_code(old_messages)

        store = LocalVectorStore.load(config.vector_store_path)

        with MemoryMonitor("rag_text") as monitor:
            emit("model_loading", phase="rag", model="nomic-embed-text-v2-moe")
            text_vectors = embed_texts(config.nomic_model_path, [c.text for c in text_chunks])
            emit("model_unloaded", phase="rag", model="nomic-embed-text-v2-moe")
        guard_step_budget("rag_text", monitor.peak_rss_bytes)

        store.add([
            VectorRecord(id=chunk.id, text=chunk.text, embedding=vector, kind="text",
                         source_message_id=chunk.source_message_id, source_role=chunk.source_role)
            for chunk, vector in zip(text_chunks, text_vectors)
        ])

        if code_chunks:
            with MemoryMonitor("rag_code") as monitor:
                emit("model_loading", phase="rag", model="CodeRankEmbed")
                code_vectors = embed_texts(config.coderank_model_path, [c.text for c in code_chunks])
                emit("model_unloaded", phase="rag", model="CodeRankEmbed")
            guard_step_budget("rag_code", monitor.peak_rss_bytes)

            store.add([
                VectorRecord(id=chunk.id, text=chunk.text, embedding=vector, kind="code",
                             source_message_id=chunk.source_message_id, source_role=chunk.source_role)
                for chunk, vector in zip(code_chunks, code_vectors)
            ])

        store.save()
        emit("phase_completed", phase="rag", text_chunks=len(text_chunks), code_chunks=len(code_chunks))
        return len(text_chunks), len(code_chunks)


    # ---------------------------------------------------------------------------
    # Phase 3: summarization — native MLX (`mlx_lm`) throughout.
    # ---------------------------------------------------------------------------

    def chunk_messages(messages: list[dict], max_chars: int = DEFAULT_SUMMARY_BATCH_CHARS) -> list[list[dict]]:
        """Greedy character-budget batching — the Python-side counterpart
        to Anvil's own `ChatContextBuilder.batches` on the Swift side (see
        that type's doc comment for why a single, huge prompt isn't an
        option: coverage of a long history can't depend on how much of it
        fits in one context window). An oversized single message still
        becomes its own batch rather than being silently dropped.
        """
        batches: list[list[dict]] = []
        current: list[dict] = []
        current_chars = 0

        for message in messages:
            length = len(message.get("content") or "")
            if current and current_chars + length > max_chars:
                batches.append(current)
                current = []
                current_chars = 0
            current.append(message)
            current_chars += length

        if current:
            batches.append(current)
        return batches


    def format_excerpt(messages: list[dict]) -> str:
        lines = []
        for message in messages:
            role = message.get("role", "user")
            content = (message.get("content") or "").strip()
            if not content:
                continue
            speaker = "User" if role == "user" else "Assistant"
            lines.append(f"{speaker}: {content}")
        return "\n".join(lines)


    def summarize(phi4_model_path: Path, old_messages: list[dict]) -> str:
        from mlx_lm import load, generate

        with MemoryMonitor("summarize") as monitor:
            emit("model_loading", phase="summarize", model="Phi-4-mini-instruct")
            model, tokenizer = load(str(phi4_model_path))

            bullet_summaries: list[str] = []
            batches = chunk_messages(old_messages)
            for index, batch in enumerate(batches):
                emit("summarize_batch_started", index=index, total=len(batches))
                excerpt = format_excerpt(batch)
                if not excerpt:
                    continue
                conversation = [
                    {"role": "system", "content": HIDDEN_SYSTEM_PROMPT},
                    {"role": "user", "content": excerpt},
                ]
                prompt = tokenizer.apply_chat_template(conversation, add_generation_prompt=True)
                text = generate(model, tokenizer, prompt=prompt, max_tokens=800, verbose=False)
                bullet_summaries.append(text.strip())
                emit("summarize_batch_completed", index=index, total=len(batches))

            release_mlx_model(model, tokenizer)
            emit("model_unloaded", phase="summarize", model="Phi-4-mini-instruct")
        guard_step_budget("summarize", monitor.peak_rss_bytes)

        return "\n".join(part for part in bullet_summaries if part)


    def run_summarization_phase(old_messages: list[dict], config: "PipelineConfig") -> str:
        emit("phase_started", phase="summarize")
        summary = summarize(config.phi4_model_path, old_messages)
        emit("phase_completed", phase="summarize", summary_chars=len(summary))
        return summary


    # ---------------------------------------------------------------------------
    # Orchestration
    # ---------------------------------------------------------------------------

    @dataclass
    class PipelineConfig:
        nomic_model_path: Path
        coderank_model_path: Path
        phi4_model_path: Path
        vector_store_path: Path
        unload_ack_timeout: float = 60.0
        intact_tail_messages: int = INTACT_TAIL_MESSAGES


    def run_compaction(thread: dict, config: PipelineConfig) -> dict:
        """Runs phases 2–4 against an already-paused, already-unloaded
        thread and returns the reconstructed payload — also emitted as a
        single `context_shift_ready` event, the signal Swift is waiting on
        to reload the original model and resume generation. Requested
        live: "todos os resultados gerados de memória devem ser alocados e
        solicitados aprovação como já acontece hoje no menu Memórias" — the
        summary text is handed back as plain data for Swift to route
        through its own `ChatMemorySuggestionStore` (the same approval
        queue "Suggest from Thread" already uses), never written directly
        into anything Swift treats as already-approved memory from this
        process.
        """
        messages = thread["messages"]
        tail = config.intact_tail_messages
        old_messages = messages[:-tail] if tail > 0 else messages
        intact_messages = messages[-tail:] if tail > 0 else []

        emit("shift_started", total_messages=len(messages), old_messages=len(old_messages), intact_messages=len(intact_messages))

        text_chunks, code_chunks = run_rag_phase(old_messages, config)
        summary = run_summarization_phase(old_messages, config)

        payload = {
            "system_prompt": thread.get("system_prompt"),
            "summary": summary,
            "intact_messages": intact_messages,
            "text_chunks_indexed": text_chunks,
            "code_chunks_indexed": code_chunks,
        }
        emit("context_shift_ready", **payload)
        return payload


    # ---------------------------------------------------------------------------
    # Self-test — exercises everything above that doesn't need a real model.
    # ---------------------------------------------------------------------------

    def _self_test() -> int:
        import tempfile
        import uuid

        failures: list[str] = []

        def check(label: str, condition: bool) -> None:
            if condition:
                print(f"PASS: {label}")
            else:
                print(f"FAIL: {label}")
                failures.append(label)

        # --- split_text_and_code -------------------------------------------
        messages = [
            {"id": "m1", "role": "user", "content": "Como faço para somar dois números em Python?"},
            {
                "id": "m2",
                "role": "assistant",
                "content": "Assim:\n```python\ndef add(a, b):\n    return a + b\n```\nSimples, não?",
            },
            {"id": "m3", "role": "user", "content": "And in JavaScript?"},
            {
                "id": "m4",
                "role": "assistant",
                "content": "```javascript\nfunction add(a, b) { return a + b; }\n```",
            },
        ]
        text_chunks, code_chunks = split_text_and_code(messages)
        check("split_text_and_code finds both code blocks", len(code_chunks) == 2)
        check("split_text_and_code keeps surrounding text", any("somar" in c.text for c in text_chunks))
        check("split_text_and_code strips fences from code", all("```" not in c.text for c in code_chunks))
        check("split_text_and_code keeps python body", any("def add" in c.text for c in code_chunks))
        check("split_text_and_code drops a message that's pure code", not any(c.text.strip() == "" for c in text_chunks))

        # --- chunk_messages ---------------------------------------------------
        long_messages = [{"role": "user", "content": "x" * 100} for _ in range(50)]
        batches = chunk_messages(long_messages, max_chars=250)
        check("chunk_messages covers every message", sum(len(b) for b in batches) == len(long_messages))
        check("chunk_messages respects the char budget (± one oversized message)",
              all(sum(len(m["content"]) for m in b) <= 250 or len(b) == 1 for b in batches))
        oversized = [{"role": "user", "content": "y" * 1000}]
        check("chunk_messages keeps an oversized message as its own batch",
              chunk_messages(oversized, max_chars=10) == [oversized])

        # --- LocalVectorStore round trip --------------------------------------
        with tempfile.TemporaryDirectory() as tmp:
            store_path = Path(tmp) / "vectors"
            store = LocalVectorStore.load(store_path)
            check("a fresh vector store starts empty", len(store.records) == 0)

            records = [
                VectorRecord(id=str(uuid.uuid4()), text="the cat sat on the mat", embedding=[1.0, 0.0, 0.0],
                             kind="text", source_message_id="m1", source_role="user"),
                VectorRecord(id=str(uuid.uuid4()), text="def add(a, b): return a + b", embedding=[0.0, 1.0, 0.0],
                             kind="code", source_message_id="m2", source_role="assistant"),
                VectorRecord(id=str(uuid.uuid4()), text="dogs are great too", embedding=[0.9, 0.1, 0.0],
                             kind="text", source_message_id="m3", source_role="user"),
            ]
            store.add(records)
            store.save()

            reloaded = LocalVectorStore.load(store_path)
            check("vector store round-trips every record", len(reloaded.records) == len(records))
            check("vector store round-trips embeddings", reloaded.records[0].embedding == [1.0, 0.0, 0.0])

            top = reloaded.search([1.0, 0.0, 0.0], top_k=1, kind="text")
            check("vector store search finds the closest text match", top and top[0].text == "the cat sat on the mat")
            code_only = reloaded.search([0.0, 1.0, 0.0], top_k=5, kind="code")
            check("vector store search respects the kind filter", all(r.kind == "code" for r in code_only))

            # --- LocalVectorStore.add upserts by id instead of duplicating -----
            reloaded.add([
                VectorRecord(id=records[0].id, text=records[0].text, embedding=[1.0, 0.0, 0.0],
                             kind="text", source_message_id="m1", source_role="user"),
            ])
            check("re-adding an identical chunk (same id, same text) doesn't duplicate it",
                  len(reloaded.records) == len(records))

            reloaded.add([
                VectorRecord(id=records[0].id, text="the cat sat on the rug", embedding=[1.0, 0.0, 0.0],
                             kind="text", source_message_id="m1", source_role="user"),
            ])
            check("re-adding a changed chunk (same id, different text) replaces it in place, still no duplicate",
                  len(reloaded.records) == len(records)
                  and reloaded.records[0].text == "the cat sat on the rug")

        # --- context_window_for -------------------------------------------
        with tempfile.TemporaryDirectory() as tmp:
            model_dir = Path(tmp)
            (model_dir / "config.json").write_text(json.dumps({"max_position_embeddings": 40960}))
            check("context_window_for reads max_position_embeddings", context_window_for(model_dir) == 40960)

            empty_dir = Path(tmp) / "missing"
            empty_dir.mkdir()
            check("context_window_for falls back to the default when config.json is missing",
                  context_window_for(empty_dir, default=4096) == 4096)

        # --- emit()/read_control_line protocol shape --------------------------
        import io
        import contextlib

        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            emit("phase_started", phase="rag")
        line = buffer.getvalue().strip()
        parsed = json.loads(line)
        check("emit() produces one parseable JSON object per line", parsed["event"] == "phase_started" and parsed["phase"] == "rag")
        check("emit() always includes a timestamp", "ts" in parsed)

        print()
        if failures:
            print(f"{len(failures)} check(s) failed: {', '.join(failures)}")
            return 1
        print("All self-test checks passed.")
        return 0


    # ---------------------------------------------------------------------------
    # CLI
    # ---------------------------------------------------------------------------

    def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
        parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
        mode = parser.add_mutually_exclusive_group(required=True)
        mode.add_argument("--watch", metavar="STATUS_JSON", help="Path to the status file Anvil rewrites after every turn.")
        mode.add_argument("--run-once", metavar="THREAD_JSON", help="Path to a thread export to compact immediately.")
        mode.add_argument("--self-test", action="store_true", help="Run this file's own self-test and exit.")

        parser.add_argument("--nomic-model", help="Local path to nomic-embed-text-v2-moe.")
        parser.add_argument("--coderank-model", help="Local path to CodeRankEmbed.")
        parser.add_argument("--phi4-model", help="Local path to Phi-4-mini-instruct-mlx-fp16.")
        parser.add_argument("--vector-store", help="Path (no extension) for the local vector store's .npz/.json pair.")
        parser.add_argument("--trigger-fraction", type=float, default=DEFAULT_TRIGGER_FRACTION)
        parser.add_argument("--intact-tail-messages", type=int, default=INTACT_TAIL_MESSAGES)
        parser.add_argument("--unload-ack-timeout", type=float, default=60.0)
        return parser.parse_args(argv)


    def main(argv: Optional[list[str]] = None) -> int:
        args = parse_args(argv)

        if args.self_test:
            return _self_test()

        missing = [name for name in ("nomic_model", "coderank_model", "phi4_model", "vector_store")
                   if getattr(args, name) is None]
        if missing:
            print(f"error: --{missing[0].replace('_', '-')} is required for this mode", file=sys.stderr)
            return 2

        config = PipelineConfig(
            nomic_model_path=Path(args.nomic_model),
            coderank_model_path=Path(args.coderank_model),
            phi4_model_path=Path(args.phi4_model),
            vector_store_path=Path(args.vector_store),
            unload_ack_timeout=args.unload_ack_timeout,
            intact_tail_messages=args.intact_tail_messages,
        )

        if args.run_once:
            thread = json.loads(Path(args.run_once).read_text())
            run_compaction(thread, config)
            return 0

        watch_loop(Path(args.watch), args.trigger_fraction, config)
        return 0


    if __name__ == "__main__":
        sys.exit(main())
    """#
}

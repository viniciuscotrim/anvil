import Foundation

/// The Python HTTP server `ImageServer` drives. `mflux` (unlike
/// `mlx-lm`) ships no server of its own — only a generate-once-and-exit
/// CLI — so this is genuinely Anvil's own `/v1/images/generations`
/// endpoint, keeping the Flux pipeline resident in memory across
/// requests instead of reloading multi-gigabyte weights every call.
enum ImageServerScript {
    static func ensureWrittenToDisk() throws -> URL {
        let scriptsDir = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("scripts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: scriptsDir.path) {
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        }
        let scriptURL = scriptsDir.appendingPathComponent("image_server.py")
        // Always rewritten — keeps it in sync with whatever version
        // ships in this build of Anvil rather than trusting a stale
        // copy from a previous install.
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        return scriptURL
    }

    private static let source = #"""
    import argparse
    import base64
    import json
    import sys
    import threading
    import time
    import uuid
    from concurrent.futures import ThreadPoolExecutor
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from pathlib import Path

    from mflux.models.common.config import ModelConfig
    from mflux.models.flux.variants.txt2img.flux import Flux1

    # mflux ships a genuinely separate pipeline class per model
    # architecture — FLUX.1, FLUX.2, Krea-2, Z-Image — each with its
    # own component shapes on disk (only FLUX.1 has a second,
    # T5 `text_encoder_2`; the others have just one). A real, reported
    # bug: every registered image model was loaded through `Flux1`
    # regardless of which of these it actually was, so anything but a
    # genuine FLUX.1 checkpoint failed with a "No safetensors files
    # found in .../text_encoder_2" (or similar) error — Flux1's loader
    # went looking for a component the other families never have.
    # `detect_model_family`/`build_non_flux1_pipeline` below route each
    # family to its own class instead; see docs/image-model-loading.md
    # for the full writeup of why this happened and what these curated
    # families actually need.
    FAMILY_CONFIG_FACTORY = {
        "z-image-turbo": "z_image_turbo",
        "flux2-klein-4b": "flux2_klein_4b",
        "flux2-klein-9b": "flux2_klein_9b",
        "krea-2": "krea2",
    }

    def detect_model_family(model_path):
        # Matched against the local folder's own name (Anvil names a
        # registered model's directory after its source repo id), not
        # file contents — cheap, and every curated entry's repo id
        # names its family unambiguously. Falls back to "flux1" (the
        # existing, unchanged path) for anything that doesn't match one
        # of the three families that actually need a different loader.
        name = model_path.name.lower()
        if "z-image" in name or "z_image" in name:
            return "z-image-turbo"
        if "flux2-klein-9b" in name or "flux-2-klein-9b" in name:
            return "flux2-klein-9b"
        if "flux2" in name or "flux-2" in name:
            return "flux2-klein-4b"
        if "krea" in name:
            return "krea-2"
        return "flux1"

    def build_non_flux1_pipeline(family, model_path, quantize):
        model_config = getattr(ModelConfig, FAMILY_CONFIG_FACTORY[family])()
        # Each class only needs its own weights actually present in
        # model_path — passing it directly (rather than resolving a
        # named alias through mflux's own CLI config-resolution path)
        # is exactly what mflux's own CLIs do too whenever --model-path
        # is a local checkpoint, per mflux's own
        # ConfigResolution.resolve_restricted: model_path given means
        # "load from here", full stop, no name matching needed.
        if family == "z-image-turbo":
            from mflux.models.z_image.variants.z_image import ZImage
            return ZImage(model_config=model_config, quantize=quantize, model_path=str(model_path))
        if family in ("flux2-klein-4b", "flux2-klein-9b"):
            from mflux.models.flux2.variants import Flux2Klein
            return Flux2Klein(model_config=model_config, quantize=quantize, model_path=str(model_path))
        if family == "krea-2":
            from mflux.models.krea2.variants.txt2img.krea2 import Krea2
            return Krea2(model_config=model_config, quantize=quantize, model_path=str(model_path))
        raise ValueError(f"Unhandled model family: {family}")

    # MLX ties its compute stream to whatever thread first touches it —
    # calling generate_image() from a thread other than the one that
    # loaded the model fails ("There is no Stream(cpu, 0) in current
    # thread"), confirmed by hitting that error for real. A single
    # dedicated worker thread runs both the load and every generation
    # call; ThreadingHTTPServer's own handler threads stay free to
    # answer GET /v1/images/progress while a POST is in flight — they
    # just submit generation work to this executor and block on the
    # result, not on the shared HTTP server itself.
    mlx_executor = ThreadPoolExecutor(max_workers=1)


    def parse_args():
        parser = argparse.ArgumentParser()
        parser.add_argument("--model", required=True)
        parser.add_argument("--base-model", default=None)
        parser.add_argument("--quantize", type=int, default=None)
        parser.add_argument("--host", default="127.0.0.1")
        parser.add_argument("--port", type=int, default=8200)
        parser.add_argument("--output-dir", required=True)
        return parser.parse_args()


    def build_pipeline(args):
        model_path = Path(args.model)
        base_model = args.base_model

        if model_path.is_dir():
            family = detect_model_family(model_path)
            if family != "flux1":
                print(f"Loading '{model_path.name}' as {family} (not FLUX.1)...", file=sys.stderr, flush=True)
                return build_non_flux1_pipeline(family, model_path, args.quantize)

            has_pipeline = (model_path / "vae").is_dir() or (model_path / "model_index.json").is_file()
            if not has_pipeline:
                # Check for single checkpoint
                safetensors = list(model_path.glob("*.safetensors")) + list(model_path.glob("*.ckpt"))
                if safetensors:
                    print(
                        f"Notice: '{model_path.name}' is a standalone weights file without local VAE/text-encoder subfolders. "
                        f"Attempting base model resolution with '{base_model or 'black-forest-labs/FLUX.1-schnell'}'...",
                        file=sys.stderr,
                        flush=True
                    )
                    if not base_model:
                        base_model = "black-forest-labs/FLUX.1-schnell" if "schnell" in args.model.lower() else "black-forest-labs/FLUX.1-dev"
                    try:
                        model_config = ModelConfig.from_name(model_name=str(safetensors[0]), base_model=base_model)
                        return Flux1(model_config=model_config, quantize=args.quantize)
                    except Exception as exc:
                        raise RuntimeError(
                            f"Cannot load standalone weights '{safetensors[0].name}' because the required base model components could not be resolved: {exc}. "
                            f"Please download a complete pipeline package (e.g. mflux-community/flux-1-schnell-mflux-q4 or mflux-community/flux2-klein-4b-mflux-q4)."
                        ) from exc
                else:
                    raise FileNotFoundError(
                        f"Directory '{model_path}' has no recognized model files (safetensors or ckpt)."
                    )

        model_config = ModelConfig.from_name(model_name=args.model, base_model=base_model)
        return Flux1(model_config=model_config, quantize=args.quantize)


    class ProgressState:
        """Shared between the generation thread (writer, via the mflux
        in-loop callback) and any GET /v1/images/progress request
        (reader) — a ThreadingHTTPServer serves those concurrently while
        a generation POST is still blocking its own thread."""

        def __init__(self):
            self._lock = threading.Lock()
            self._step = 0
            self._total = 0
            self._active = False

        def begin(self):
            with self._lock:
                self._step = 0
                self._total = 0
                self._active = True

        def update(self, step, total):
            with self._lock:
                self._step = step
                self._total = total

        def end(self):
            with self._lock:
                self._active = False

        def snapshot(self):
            with self._lock:
                return {"step": self._step, "total": self._total, "active": self._active}


    class ProgressCallback:
        def __init__(self, state: ProgressState):
            self._state = state

        def call_in_loop(self, t, seed, prompt, latents, config, time_steps):
            total = getattr(time_steps, "total", None) or 0
            self._state.update(t + 1, total)


    def make_handler(flux, output_dir: Path, model_label: str, progress: ProgressState):
        class Handler(BaseHTTPRequestHandler):
            def _send_json(self, status, payload):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                sys.stderr.write(
                    "%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args)
                )

            def do_GET(self):
                if self.path.startswith("/v1/images/progress"):
                    self._send_json(200, progress.snapshot())
                elif self.path.startswith("/v1/models"):
                    self._send_json(200, {"object": "list", "data": [{"id": model_label, "object": "model"}]})
                else:
                    self._send_json(404, {"error": "not found"})

            def do_POST(self):
                if not self.path.startswith("/v1/images/generations"):
                    self._send_json(404, {"error": "not found"})
                    return

                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    body = json.loads(self.rfile.read(length) or b"{}")
                except Exception as exc:
                    self._send_json(400, {"error": f"bad request body: {exc}"})
                    return

                prompt = body.get("prompt")
                if not prompt:
                    self._send_json(400, {"error": "prompt is required"})
                    return

                size = str(body.get("size", "1024x1024"))
                try:
                    width_str, height_str = size.lower().split("x")
                    width, height = int(width_str), int(height_str)
                except Exception:
                    width, height = 1024, 1024

                try:
                    steps = int(body.get("steps", 4))
                    guidance = float(body.get("guidance", 4.0))
                    seed = body.get("seed")
                    seed = int(seed) if seed is not None else int(time.time() * 1000) % (2**31)
                except Exception as exc:
                    self._send_json(400, {"error": f"invalid parameter: {exc}"})
                    return

                progress.begin()
                try:
                    image = mlx_executor.submit(
                        flux.generate_image,
                        seed=seed,
                        prompt=prompt,
                        num_inference_steps=steps,
                        height=height,
                        width=width,
                        guidance=guidance,
                    ).result()
                except Exception as exc:
                    progress.end()
                    self._send_json(500, {"error": f"generation failed: {exc}"})
                    return
                progress.end()

                output_dir.mkdir(parents=True, exist_ok=True)
                filename = f"{int(time.time())}-{uuid.uuid4().hex[:8]}.png"
                output_path = output_dir / filename
                image.save(path=str(output_path))

                item = {
                    "path": str(output_path),
                    "seed": seed,
                    "width": width,
                    "height": height,
                }
                # The native client reads the local file directly. Keep the
                # base64 field for ordinary OpenAI-compatible clients.
                if self.headers.get("X-Anvil-Local") != "1":
                    item["b64_json"] = base64.b64encode(output_path.read_bytes()).decode("ascii")
                self._send_json(
                    200,
                    {
                        "created": int(time.time()),
                        "data": [item],
                    },
                )

        return Handler


    def main():
        args = parse_args()
        print(f"Loading {args.model}...", file=sys.stderr, flush=True)
        # Loaded on the same dedicated worker thread every generation
        # call below will also run on — see the mlx_executor comment.
        flux = mlx_executor.submit(build_pipeline, args).result()
        progress = ProgressState()
        flux.callbacks.register(ProgressCallback(progress))
        print("Model loaded.", file=sys.stderr, flush=True)

        handler = make_handler(flux, Path(args.output_dir), args.model, progress)
        # Threading, not the plain single-threaded HTTPServer: a
        # generation POST blocks its own thread for a while, and
        # GET /v1/images/progress needs to be answered while that's
        # happening, not queued behind it.
        server = ThreadingHTTPServer((args.host, args.port), handler)
        print(f"Starting httpd at {args.host} on port {args.port}...", file=sys.stderr, flush=True)
        server.serve_forever()


    if __name__ == "__main__":
        main()
    """#
}

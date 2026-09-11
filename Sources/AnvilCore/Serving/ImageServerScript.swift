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
        model_config = ModelConfig.from_name(model_name=args.model, base_model=args.base_model)
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

                b64 = base64.b64encode(output_path.read_bytes()).decode("ascii")
                self._send_json(
                    200,
                    {
                        "created": int(time.time()),
                        "data": [
                            {
                                "b64_json": b64,
                                "path": str(output_path),
                                "seed": seed,
                                "width": width,
                                "height": height,
                            }
                        ],
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

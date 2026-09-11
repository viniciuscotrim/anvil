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
    import time
    import uuid
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from pathlib import Path

    from mflux.models.common.config import ModelConfig
    from mflux.models.flux.variants.txt2img.flux import Flux1


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


    def make_handler(flux, output_dir: Path, model_label: str):
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
                if self.path.startswith("/v1/models"):
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

                try:
                    image = flux.generate_image(
                        seed=seed,
                        prompt=prompt,
                        num_inference_steps=steps,
                        height=height,
                        width=width,
                        guidance=guidance,
                    )
                except Exception as exc:
                    self._send_json(500, {"error": f"generation failed: {exc}"})
                    return

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
        flux = build_pipeline(args)
        print("Model loaded.", file=sys.stderr, flush=True)

        handler = make_handler(flux, Path(args.output_dir), args.model)
        server = HTTPServer((args.host, args.port), handler)
        print(f"Starting httpd at {args.host} on port {args.port}...", file=sys.stderr, flush=True)
        server.serve_forever()


    if __name__ == "__main__":
        main()
    """#
}

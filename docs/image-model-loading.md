# Why some image models wouldn't load (Z-Image, FLUX.2, Krea-2)

## The report

Loading a downloaded Z-Image Turbo model (`mflux-community/z-image-turbo-mflux-q4`,
registered locally as
`drawthings--mflux-community--z-image-turbo-mflux-q4-4-bit`) failed immediately with:

```
Could not start the model server: process exited before becoming ready
...
FileNotFoundError: No safetensors files found in
/Volumes/APFS3/oMLX/Models/drawthings--mflux-community--z-image-turbo-mflux-q4-4-bit/text_encoder_2
```

## Root cause

`mflux` (the library Anvil's image server wraps — see
`Sources/AnvilCore/Serving/ImageServerScript.swift`) is not one pipeline. It ships a
genuinely separate Python class, and a separate on-disk component layout, per model
*architecture*:

| Family (mflux class) | Local folder actually has |
|---|---|
| FLUX.1 (`Flux1`) | `text_encoder` (CLIP) **and** `text_encoder_2` (T5), `transformer`, `vae` |
| FLUX.2 Klein (`Flux2Klein`) | one `text_encoder` (Qwen3), `transformer`, `vae` — **no** `text_encoder_2` |
| Krea-2 (`Krea2`) | one `text_encoder`, `transformer`, `vae` — **no** `text_encoder_2` |
| Z-Image Turbo (`ZImage`) | `text_encoder`, `tokenizer`, `transformer`, `vae` — **no** `text_encoder_2` |

`Sources/AnvilCore/Serving/ImageServerScript.swift`'s `build_pipeline()` — the code that
loads *every* registered image model — always instantiated `Flux1`, unconditionally:

```python
model_config = ModelConfig.from_name(model_name=args.model, base_model=base_model)
return Flux1(model_config=model_config, quantize=args.quantize)
```

`Flux1`'s own initializer (`FluxInitializer`) is written specifically for the FLUX.1
layout, so it always looks for `text_encoder_2/*.safetensors`. For a genuine FLUX.1
checkpoint that folder exists and loading works. For Z-Image, FLUX.2, or Krea-2 it
doesn't exist — because those architectures never had one — and the loader raises
exactly the `FileNotFoundError` in the report, for whichever FLUX.1-only component it
went looking for first.

This means the bug wasn't specific to Z-Image: **every non-FLUX.1 model in Anvil's own
curated hub was affected** — `mflux-community/flux2-klein-4b-mflux-q4`,
`flux2-klein-9b-mflux-q4/q8`, and `krea-2-turbo-mflux-q4` (see
`Sources/AnvilCore/Models/DrawThingsCatalog.swift` for the exact curated list) would all
have failed the same way, the first time anyone actually tried to generate with one —
prior verification of those (CHANGELOG `0.8.2`) only confirmed *download size*, never
that the weights actually loaded and ran.

## The fix

`build_pipeline()` now detects which of the four families a registered model's folder
name identifies (Anvil names a model's local directory after its source repo id, so the
family is unambiguous from the name alone — `detect_model_family()`), and routes to that
family's own mflux class with its own default `ModelConfig` factory:

- `z-image-turbo` → `mflux.models.z_image.variants.z_image.ZImage`, `ModelConfig.z_image_turbo()`
- `flux2-klein-4b` / `flux2-klein-9b` → `mflux.models.flux2.variants.Flux2Klein`, `ModelConfig.flux2_klein_4b()` / `.flux2_klein_9b()`
- `krea-2` → `mflux.models.krea2.variants.txt2img.krea2.Krea2`, `ModelConfig.krea2()`
- anything else → unchanged, the existing `Flux1` path (including the standalone
  single-file-checkpoint fallback)

All four classes share the same shape that made this a small, surgical fix rather than a
rewrite: `__init__(quantize=, model_path=, model_config=, ...)`, a compatible
`generate_image(seed=, prompt=, num_inference_steps=, height=, width=, guidance=, ...)`,
a `.callbacks` registry, and a `generate_image()` result that responds to `.save(path=)`
— confirmed by reading each class directly in the installed `mflux` package
(`.../venv/lib/python3.12/site-packages/mflux/models/{z_image,flux2,krea2}/...`), not
assumed from FLUX.1's shape.

Passing `model_path` directly (rather than resolving a named alias through mflux's own
CLI argument parser) is exactly what mflux's own CLIs do too whenever the model comes
from a local checkpoint rather than a bare registry name — confirmed in
`ConfigResolution.resolve_restricted`'s own logic: a non-`None` `model_path` short-circuits
name resolution entirely and returns the family's default config, no alias matching
needed.

## Verified for real

Not just read — actually run, against the real downloaded model on disk:

```
$ python3 -c "... build_pipeline(args) ..."
Loading 'drawthings--mflux-community--z-image-turbo-mflux-q4-4-bit' as z-image-turbo (not FLUX.1)...
LOADED_OK in 12.79s -> <class 'mflux.models.z_image.variants.z_image.ZImage'>
```

Followed by an actual generation (2 steps, 256×256) that produced a real, valid PNG —
not just a successful load. FLUX.2 Klein and Krea-2 were verified by source inspection
only (no complete download of either was available locally to test against at fix time)
— the class-shape table above is what that verification rests on; if either still fails
after this fix, that's the first place to look.

## If a model still won't load

The family-detection here is deliberately narrow — it only recognizes the four families
Anvil's own curated hub (`DrawThingsCatalog.swift`) actually offers. A model from
outside that hub, or a future mflux architecture (`qwen`, `ernie_image`, `fibo`, and
others already exist in `mflux.models.*` but nothing in Anvil registers them), will still
fall through to the `Flux1` path and fail the same way this bug did — by design, not by
oversight: silently guessing a fifth architecture's class from a folder name is exactly
the kind of wrong-but-plausible behavior this bug report was about, so a new family needs
its own explicit branch here (same shape as the three added for this fix) rather than a
looser heuristic.

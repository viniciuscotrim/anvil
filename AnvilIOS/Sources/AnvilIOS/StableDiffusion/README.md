# Vendored: mlx-swift-examples' StableDiffusion library

These 9 files are copied verbatim from
[ml-explore/mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples)
`Libraries/StableDiffusion/`, MIT-licensed (see `LICENSE.txt`), unmodified.

## Why vendored instead of a package dependency

`mlx-swift-examples` (latest tag `2.29.1`) pins `swift-transformers` to
`1.0.0..<1.1.0`. `mlx-swift-lm` (the chat engine's own dependency, see
`NativeChatEngine.swift`) requires `swift-transformers >= 1.3.0`. These
two ranges have no overlap — a real, confirmed SwiftPM resolution
failure (`Failed to resolve dependencies... required because
'mlx-swift-examples' 2.29.1 depends on 'swift-transformers'
1.0.0..<1.1.0`), not a guess. The actual Swift *source* has no such
constraint — it only imports `Hub` (a `swift-transformers` product,
version-agnostic at the API level used here) — so vendoring the source
directly, rather than depending on the whole package with its overly
strict manifest, sidesteps the conflict without forking anything.

Update by re-downloading these same files from `main` if
`mlx-swift-examples` ever loosens its own `swift-transformers`
constraint to the point a plain package dependency becomes possible
again.

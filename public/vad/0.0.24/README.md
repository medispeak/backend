# Vendored voice-activity detection

Used by the template playground (`app/javascript/controllers/playground_controller.js`)
to cut the microphone stream into whole utterances, each uploaded to
`POST /api/v2/scribe_sessions/:id/audio/segments` as its own WAV.

| File | Source | Version |
|---|---|---|
| `vad.bundle.min.js` | `@ricky0123/vad-web` → `dist/bundle.min.js` | 0.0.24 |
| `vad.worklet.bundle.min.js` | `@ricky0123/vad-web` → `dist/vad.worklet.bundle.min.js` | 0.0.24 |
| `silero_vad_v5.onnx` | `@ricky0123/vad-web` → `dist/silero_vad_v5.onnx` | 0.0.24 |
| `ort/ort.wasm.min.js` | `onnxruntime-web` → `dist/ort.wasm.min.js` | 1.14.0 |
| `ort/ort-wasm-simd.wasm` | `onnxruntime-web` → `dist/ort-wasm-simd.wasm` | 1.14.0 |

`onnxruntime-web` is pinned to 1.14.0 because that is the exact version
`vad-web@0.0.24` depends on. The reference implementation this playground is
modelled on (`ohcnetwork/care_filly_fe`, branch `medi`) resolves the same pair.

## Why these live in `public/` rather than `app/assets/`

`vad-web` builds its own asset URLs by appending fixed filenames to the
`baseAssetPath` and `onnxWASMBasePath` options — it asks for
`<base>/vad.worklet.bundle.min.js`, not for a digested name. Propshaft
fingerprints everything it serves, so a digested path could never satisfy that.
Serving undigested from `public/` is the way to give the library the directory
layout it expects. The **version in the directory name is the cache-buster**:
upgrading means a new directory, which changes every URL.

## Why not importmap

`bin/importmap pin @ricky0123/vad-web --download` does not work: JSPM does not
carry the package. `dist/index.js` is CommonJS in any case. `bundle.min.js` is
a UMD build that assigns `self.vad` and reads a global `ort`, which is why the
Stimulus controller injects the two `<script>` tags in order rather than
importing them.

## Constraints to preserve when upgrading

- **CSP.** `config/initializers/content_security_policy.rb` carries
  `:wasm_unsafe_eval` in `script_src` solely for this. A bare `script_src :self`
  blocks `WebAssembly.instantiate`.
- **Single-threaded only.** The controller forces `ort.env.wasm.numThreads = 1`.
  Multi-threaded onnxruntime needs `SharedArrayBuffer`, which would require
  COOP/COEP cross-origin isolation across the whole app.
- **SIMD only.** Only `ort-wasm-simd.wasm` is vendored; the non-SIMD fallback is
  deliberately omitted because `allow_browser versions: :modern`
  (`app/controllers/application_controller.rb:8`) already gates to browsers that
  all support WebAssembly SIMD. Re-add `ort-wasm.wasm` if that gate is relaxed.

## Upgrading

```bash
V=0.0.30           # new vad-web version
ORT=1.14.0         # whatever that release depends on — check its package.json
mkdir -p public/vad/$V/ort
curl -sL "https://registry.npmjs.org/@ricky0123/vad-web/-/vad-web-$V.tgz" | tar xz -C /tmp
curl -sL "https://registry.npmjs.org/onnxruntime-web/-/onnxruntime-web-$ORT.tgz" | tar xz -C /tmp/ort
# copy the five files above, then update the data-playground-*-base values in
# app/views/playground/show.html.erb and delete the old directory.
```

`test/system/playground_test.rb` is the check that this still works: it drives a
real headless Chrome with a synthetic microphone and asserts `window.vad` is
defined after pressing record, which fails if the wasm cannot load or compile.

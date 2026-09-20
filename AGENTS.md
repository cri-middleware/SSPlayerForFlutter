# SSPlayerForFlutter — AI Agent Guide

## Operating rules

* Keep changes scoped to the request; read callers and invariants before editing.
* **Do not commit or push unless the user explicitly asks.**
* Follow the existing Dart style (naming, null-safety, `dispose` discipline).
* After editing Dart, run `flutter analyze lib test` and `flutter test` in the package you touched.
  Build the native libs first with `scripts/build-runtime.sh`.
* Fix stale docs in the same turn you notice them.
* When a rendering or behaviour detail is unclear, the flagship
  [SSPlayerForGodot](https://github.com/cri-middleware/SSPlayerForGodot) is the closest reference,
  then `SpriteStudio-SDK/libs/ssruntime/docs/`.

## What this repo is

The Flutter **Body** for the SpriteStudio-SDK **Brain**: a pub workspace, released with Melos, that
renders `.ssab` animations by driving the Rust `libssruntime` over `dart:ffi`. The Brain lives in
the `SpriteStudio-SDK/` submodule — see its own [AGENTS.md](./SpriteStudio-SDK/AGENTS.md).

## Where each answer is written

| Question | File |
|---|---|
| What the packages are, how to install and use them | [README.md](./README.md), the [docs site](./docs/en/) |
| How to build, generate code and test from a checkout | [CONTRIBUTING.md](./CONTRIBUTING.md), [Build Guide](./docs/en/contributing/build.md) |
| The four layers and what each owns | [Architecture](./docs/en/contributing/architecture.md) |
| How the native library is resolved and packaged | [Native Runtime](./docs/en/contributing/native-runtime.md) |
| How versions are computed and published | [Releasing](./docs/en/contributing/releasing.md) |
| How the site is built and a release is cut | [RELEASING.md](./RELEASING.md), maintainers only |
| What to build next, and what is out of scope | [ROADMAP.md](./ROADMAP.md) |
| What each script does and takes | that script's `--help` |

Do not restate those here. This file is for what an agent would otherwise break silently.

## Invariants

*   **Keep L2 (`SpriteStudioInternalPlayer`) Widget-free** so it stays reusable headless, from
    Flame, and behind the flutter_gpu backend. The dependency runs one way, downward.
*   **Never call `PartState.updateFlag`** — the flatc `bit_flags` enum throws on OR-combined bits.
    Read the raw `uint64` and bitwise-AND.
*   **The flatc write side is not in `lib/`.** `*Builder` / `*ObjectBuilder` generate into
    `packages/ssplayer_flutter/test/support/*_builders.g.dart`; a test that synthesises a fixture
    imports the shim, which re-exports its reader library. Never hand-edit generated code.
*   **`local_uvs` / `local_vertices` are texture-PIXEL, stride 10** (`lt,rt,lb,rb,center`), not
    normalized and not ×8 — pass them straight to `drawVertices`. The world matrix is column-major
    4×4 (`x' = m0·x + m4·y + m12`), the coordinate system is Y-Down, and **the Brain flips once**:
    do not flip again in the Body.
*   **A world matrix can be a reflection, and the sign is a product** of authored negative scale
    and the player's flip, so the two can cancel. Read `determinant()`; never infer it from the
    flip settings.
*   **Per-kind geometry differs.** Normal and Shape verts are local, so apply the world matrix;
    **Mesh and Effect verts are world/sim-space**, so do not. Effect UVs are normalized 0..1
    (scale back up), Mesh is CSR-sliced, Shape fixed-stride 24.
*   **FFI pointers are borrows valid only until the next `update`.** Call `get_frame_data(frame)`
    *before* reading SoA getters, and keep the `.ssab` buffer alive past the resource.
*   **Texture key = `cellmap.name_hash` == `DrawBatch.texture_hash`** — use the pre-baked hash,
    never re-implement FNV-1a in Dart. **It spans two hash spaces**, so `SsTextureLoader` loads
    `cellmaps()` (required) *and* `external_textures()` (best-effort, a superset): a batch binds the
    second on the frames a TextureChange fires. Miss that table and TCHG frames draw nothing.
*   **Runtime texture replacement is `TextureRegistry`, keyed by `texture_hash`** — not the Override
    Layer. `setCellmapTexture(name, image?)` sets or clears a per-hash override; `null` restores the
    original instantly, and the override image belongs to the caller. The registry is shared across
    the whole instance tree, so an override reaches every part sampling that hash. It invalidates
    the GPU backend's per-hash upload cache and retires the old `ImageShader` at the next frame's
    `flushRetired`, never on the spot. To replace what a TCHG shows, target the external-texture
    name (`common.png`), not the cellmap (`common`).
*   **Instance parts: the Brain owns all playback; the Body owns the child player, pack resolution
    and drawing.** `play()` on `transitioned` is mandatory and `childFrame` must stay raw.
*   **An instance part's alpha crosses into its child; its colour does not.** This is the family's
    rule, held by every sibling and by the Editor. `RenderBackend` has no group-tint hook: a tint
    that needs an isolating layer breaks every framebuffer blend inside the subtree.
*   **Flip and offset live in `SsRootTransform`, and both consumers must read it** — the backends'
    `beginFrame` and `partWorldMatrix`. Put it in the geometry bake alone and every
    `SpriteStudioPartAnchor` detaches the moment a player flips. Instance children inherit it.
*   **Mask roles come from the static `.ssab` `PartData`**, read once at load. There is no C-API for
    them; ignore `FrameData.mask_indices`.
*   **PartColor alpha is pre-folded by the Brain** — do not re-multiply `PartState.alpha`.
*   **Integration shaders (`SHDR`) are a per-part attribute, not a draw kind.** The Brain does not
    split batches by it, so peel shader parts out of Normal batches as PartColor ones are peeled.
    `ss-blur` skips the PartColor fold; a masked part drops its shader; `map0`/`map1` and shader
    parts on Mesh/Shape/Effect are out of scope, matching both siblings.
*   **dart:ui shaders are not full GLSL.** Canvas runtime effects take no per-vertex varyings, and
    `impellerc` rejects bitwise ops and `discard` — **a rejected shader fails silently**, which is
    why Canvas uses one program per effect. `test/part_shader_test.dart` pins the uniform float
    count (48); that test failing is how a rejection surfaces. The flutter_gpu shaders under
    `shaders/gpu/` are real GLSL and fail the bundle build loudly.
*   **Blend: only RGB varies. Alpha is premultiplied source-over for every mode.** The ground truth
    is ssplayer-webgl's `applyBlend`. Break it and a Sub or Mul part erases what is under it.
    Effect blend is a separate byte whose additive row adds alpha too, unlike batch Add.
*   **Canvas Sub and Invert are multi-pass rebuilds, not approximations**, and they need one part
    per plan and the same geometry every pass. They are exact only over an **opaque** backdrop: the
    invert pass writes saturated opaque white over the part's footprint, so over a transparent
    destination the rgb matches but alpha comes back as 1 across every texel the art covers.
    `SS_BACKEND=gpu` is the workaround; the GPU backend sets the real GL state.

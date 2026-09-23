# SSPlayerForFlutter — AI Agent Guide

## Operating rules

*   Keep changes scoped to the requested task. Unrequested hardening is a suggestion, not a commit; a defect
    you actually hit in the code you touched is not — fix it, or say plainly why you did not.
*   Do not commit, push, or open PRs unless the user explicitly asks.
*   Before editing, read enough surrounding context to understand callers and invariants, the ones below
    included. If the read tool truncated a file, read the remaining ranges first.
*   Follow the existing style of the file you touch (naming, type usage, control flow, error handling).
*   **Anything that exists twice changes twice** — a page and its translation, a `.sh` and its `.ps1`. A
    change that lands in one half is the defect this family produces most.
*   **Never break a line between two Japanese characters**: Chrome draws that break as a visible space.
*   **Finish by running this repository's checks**: `flutter analyze lib test` and `flutter test` (`dart test`
    in a pure Dart package) in each package or example you touched, after building the native libraries
    with `scripts/build-runtime.sh`. Read what a run says it verified rather than its exit code — several
    checks here pass, or skip themselves, when a prerequisite is missing.
*   **Do not restate here what another file owns.** The table below says which file that is; a fact that
    belongs to none of them goes where it will be seen to go stale.
*   **Never commit inside the `SpriteStudio-SDK` submodule.** A change the core needs is a pull request in
    the SDK repository, followed by a submodule bump here.
*   **Playback and rendering semantics are the SDK's** — see [its AGENTS.md](./SpriteStudio-SDK/AGENTS.md)
    and `SpriteStudio-SDK/libs/ssruntime/docs/`; do not reimplement the rules they own.
*   **Code comments do not cite the SDK's porting guide** — no section numbers, page paths or quotes.
    Its sections move as it is revised and nothing checks a citation inside a comment; say what breaks
    if the code changes, and leave the rule to the guide.
*   When a rendering or behaviour detail is unclear, the flagship
    [SSPlayerForGodot](https://github.com/cri-middleware/SSPlayerForGodot) is the closest reference, then
    that porting guide.

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

## Invariants

*   **Never call `PartState.updateFlag`** — the flatc `bit_flags` enum throws on OR-combined bits, so read
    the raw `uint64` and bitwise-AND. Relatedly, **the flatc write side is not in `lib/`**: `*Builder` /
    `*ObjectBuilder` generate into `packages/ssplayer_flutter/test/support/*_builders.g.dart`, and a test
    that synthesises a fixture imports the shim, which re-exports its reader library. Never hand-edit
    generated code.
*   **`local_uvs` / `local_vertices` are texture-PIXEL, stride 10** (`lt,rt,lb,rb,center`), not normalized
    and not ×8 — pass them straight to `drawVertices`. The world matrix is column-major 4×4, the coordinate
    system is Y-Down, and **the Brain flips once**: never flip again here.
*   **A world matrix can be a reflection, and the sign is a product** of authored negative scale and the
    player's flip, so the two can cancel — read `determinant()`, never the flip settings. **Per-kind
    geometry differs** too: Normal and Shape verts are local, so apply the world matrix; **Mesh and Effect
    verts are world/sim-space**, so do not. Effect UVs are normalized 0..1, Mesh is CSR-sliced, Shape
    fixed-stride 24.
*   **FFI pointers are borrows valid only until the next `update`.** Call `get_frame_data(frame)` *before*
    reading SoA getters, and keep the `.ssab` buffer alive past the resource.
*   **Texture key = `cellmap.name_hash` == `DrawBatch.texture_hash`** — use the pre-baked hash, never
    re-implement FNV-1a in Dart. **It spans two hash spaces**, so `SsTextureLoader` loads `cellmaps()`
    (required) *and* `external_textures()` (best-effort, a superset): a batch binds the second on the frames
    a TextureChange fires. Miss that table and TCHG frames draw nothing.
*   **Runtime texture replacement is `TextureRegistry`, keyed by `texture_hash`** — not the Override Layer.
    `setCellmapTexture(name, image?)` sets or clears a per-hash override; `null` restores the original
    instantly, and the override image belongs to the caller. The registry is shared across the whole
    instance tree, so an override reaches every part sampling that hash. It invalidates the GPU backend's
    upload cache and retires the old `ImageShader` at the next frame's `flushRetired`, never on the spot. To
    replace what a TCHG shows, target the external-texture name, not the cellmap.
*   **Instance parts: the Brain owns all playback; the Body owns the child player, pack resolution and
    drawing.** `play()` on `transitioned` is mandatory and `childFrame` must stay raw. **An instance part's
    alpha crosses into its child; its colour does not** — the family's rule, held by every sibling and by
    the Editor. `RenderBackend` has no group-tint hook: a tint that needs an isolating layer breaks every
    framebuffer blend inside the subtree.
*   **Flip and offset live in `SsRootTransform`, and both consumers must read it** — the backends'
    `beginFrame` and `partWorldMatrix`. Put it in the geometry bake alone and every `SpriteStudioPartAnchor`
    detaches the moment a player flips. Instance children inherit it.
*   **Mask roles come from the static `.ssab` `PartData`**, read once at load — there is no C-API for them,
    so ignore `FrameData.mask_indices` — and **PartColor alpha is pre-folded by the Brain**, so never
    re-multiply `PartState.alpha`.
*   **Integration shaders (`SHDR`) are a per-part attribute, not a draw kind.** The Brain does not split
    batches by it, so peel shader parts out of Normal batches as PartColor ones are peeled. `ss-blur` skips
    the PartColor fold, a masked part drops its shader, and `map0` / `map1` and shader parts on
    Mesh/Shape/Effect are out of scope — matching both siblings.
*   **dart:ui shaders are not full GLSL.** Canvas runtime effects take no per-vertex varyings and
    `impellerc` rejects bitwise ops and `discard` — **a rejected shader fails silently**, which is why
    Canvas uses one program per effect. `test/part_shader_test.dart` pins the uniform float count; that test
    failing is how a rejection surfaces. The `shaders/gpu/` shaders are real GLSL and fail the bundle build
    loudly.
*   **Blend: only RGB varies. Alpha is premultiplied source-over for every mode**, the ground truth being
    ssplayer-webgl's `applyBlend`; break that and a Sub or Mul part erases what is under it. Effect blend is
    a separate byte whose additive row adds alpha too. Canvas rebuilds Sub and Invert from stock modes in
    several passes — one part per plan, the same geometry each pass — and is exact only over an **opaque**
    backdrop, because the invert pass writes saturated opaque white over the part's footprint.
    `SS_BACKEND=gpu` is the workaround.

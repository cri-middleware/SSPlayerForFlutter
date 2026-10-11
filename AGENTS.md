# SSPlayerForFlutter — AI Agent Guide

## Operating rules

*   **Unrequested hardening is a suggestion, not a commit.** A defect you hit in code you touched is not:
    fix it, or say why you did not.
*   **Anything that exists twice changes twice** — a page and its translation, a `.sh` and its `.ps1`.
    Missing one half is this family's most common defect.
*   **Never break a line between two Japanese characters**; Chrome renders the break as a space.
*   **Finish with this repository's checks**: `flutter analyze lib test` and `flutter test` (`dart test` in
    a pure Dart package) in each package you touched, after `scripts/build-runtime.sh`. Read what a run
    says it verified, not its exit code — several checks pass, or skip themselves, without a prerequisite.
*   **Do not restate what another file owns**; the table below says which file. A fact no file owns goes
    where its staleness will be noticed.
*   **Never commit inside the `SpriteStudio-SDK` submodule.** A core change is an SDK pull request, then a
    submodule bump here.
*   **Playback and rendering semantics are the SDK's**: its [AGENTS.md](./SpriteStudio-SDK/AGENTS.md) and
    the porting guide in `SpriteStudio-SDK/libs/ssruntime/docs/`. Where the guide is silent,
    SSPlayerForWgpu decides. Do not reimplement either.
*   **Code comments never cite the porting guide** (sections, paths, quotes): it moves, and nothing checks
    the citation. Say what breaks instead.

## What this repo is

The Flutter **Body** for the SpriteStudio-SDK **Brain** (the `SpriteStudio-SDK/` submodule): a pub
workspace that drives the Rust `libssruntime` over `dart:ffi`.

## Where each answer is written

| Question | File |
|---|---|
| Use and install | [README.md](./README.md), the [docs site](./docs/en/) |
| Constraints, build, codegen, tests, docs | [CONTRIBUTING.md](./CONTRIBUTING.md), [Build Guide](./docs/en/contributing/build.md) |
| The four layers and what each owns | [Architecture](./docs/en/contributing/architecture.md) |
| Native library resolution and packaging | [Native Runtime](./docs/en/contributing/native-runtime.md) |
| Releases, maintainers only | [RELEASING.md](./RELEASING.md) |
| Plans and non-goals | [ROADMAP.md](./ROADMAP.md) |
| What a script takes | its header comment |

## Invariants

*   **Never call `PartState.updateFlag`**: the flatc `bit_flags` enum throws on OR-combined bits. Read the
    raw `uint64` and bitwise-AND.
*   **Pass `local_uvs` straight to `drawVertices`.** They are texture pixels, which is what it takes; do not
    normalize them as the porting guide does for other engines.
*   **Per-kind geometry**: Normal and Shape vertices are local (apply the world matrix); Mesh and Effect
    vertices are world / simulation space (do not). Effect UVs are normalized, Mesh is CSR-sliced, Shape
    is fixed-stride 24.
*   **Keep the `.ssab` buffer alive as long as its resource.**
*   **No per-frame heap allocations in the playback hot path.** Consume SoA views and `DrawBatch` plans as
    they are, and bake into `GeometryBuilder`'s grow-only scratch.
*   **Never re-implement FNV-1a in Dart**; use the pre-baked `name_hash` / `texture_hash`.
*   **Runtime texture replacement is `TextureRegistry`, keyed by `texture_hash`**, not the Override Layer.
    It retires the old `ImageShader` at the next `flushRetired`, never on the spot.
*   **An instance part's alpha crosses into its child; its colour does not**, as in every sibling and the
    Editor. `RenderBackend` has no group-tint hook: an isolating layer would break every framebuffer blend
    in the subtree.
*   **Integration shaders (`SHDR`) are a per-part attribute, not a draw kind**: peel shader parts out of
    Normal batches as PartColor parts are. As in SSPlayerForWgpu, `ss-blur` skips the PartColor fold, a
    masked part drops its shader, and `map0` / `map1` and Mesh / Shape / Effect shaders are out of scope.
*   **dart:ui shaders are not full GLSL, and `impellerc` rejects silently** — no per-vertex varyings,
    bitwise ops or `discard`. Hence one Canvas program per effect; `test/part_shader_test.dart` pins the
    uniform float count, and its failure is how a rejection surfaces. `shaders/gpu/` is real GLSL and fails
    the bundle build loudly.
*   **Blend varies RGB only; alpha is premultiplied source-over in every mode** (ground truth:
    ssplayer-webgl's `applyBlend`), or a Sub or Mul part erases what is under it. The Effect blend byte's
    additive row adds alpha too.

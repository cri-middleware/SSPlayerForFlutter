# SSPlayerForFlutter — AI Agent Guide

Flutter "Body" for the SpriteStudio-SDK "Brain". This repo implements the
Player (rendering / resource / coordinate transform) that consumes the Rust
`libssruntime` runtime over `dart:ffi`. The Brain itself lives in the
`SpriteStudio-SDK/` git submodule — see its own [AGENTS.md](./SpriteStudio-SDK/AGENTS.md).

## Operating rules

* Keep changes scoped to the requested task.
* **Do not commit or push unless the user explicitly asks.**
* Before editing, read enough surrounding context to understand callers and invariants.
* Follow the existing Dart style in touched files (naming, null-safety, `dispose` discipline).
* After editing Dart, run `flutter analyze` and the tests (see [Verification](#verification)).
* Treat the flagship **SSPlayerForGodot** (`../SSPlayerForGodot`) as the reference
  implementation when a rendering/behavior detail is unclear — it is closest to
  Flutter's canvas model. Fall back to the porting guide under
  `SpriteStudio-SDK/libs/ssruntime/docs/`.

## Architecture in one paragraph

The Brain (`libssruntime`, Rust `no_std`) loads a `.ssab`, advances time, and
emits per-frame **SoA buffers** (world matrices, local vertices/UVs) plus a
FlatBuffers **`FrameData`** carrying a **DrawBatch** plan. The Body (this repo)
is a strict 4-layer downward dependency: **L4** drawing adapters
(`SpriteStudioView` = `RenderBox`; Flame/CustomPaint optional) → **L3**
`SpriteStudioPlayer` (`ChangeNotifier` + `Ticker`, transport/events) → **L2**
`SpriteStudioInternalPlayer` (Widget-agnostic: FFI Resource/Context lifecycle,
SoA→`ui.Vertices` bake, `paint`) → **L1** ffigen `@Native` C-API bindings
(`dart:ffi`), which live in the sibling **`ssruntime_dart`** binding package
(a plain Dart, non-Flutter package — top-level bindings + the
`framedata`/`effect_draw_plan` FlatBuffers; `ssplayer_flutter` depends on it). The native `libssruntime` is delivered via
**native assets** (`ssruntime_dart/hook/build.dart` bundles the prebuilt dylib as
a code asset; the `@Native` bindings resolve it by asset id) — there is no
`DynamicLibrary` loader, no `SSRUNTIME_LIBRARY_PATH`, and (on Flutter) no
CocoaPods framework. Layers below are nearer the Brain; keep L2 Widget-free so it
is reusable headless / from Flame / flutter_gpu.
The host `.sspj`→`.ssab` converter is a third binding package,
**`ssconverter_dart`** — ffigen `@Native` bindings to the host `libssconverter`
dylib behind a `ssconvert` CLI + `SsConverter` lib (desktop only); the conversion
itself runs in Rust, mirroring how `ssruntime_dart` binds `libssruntime`.

## Key files

| Path | Role |
|---|---|
Paths are under `packages/ssplayer_flutter/` unless noted; **L1** now lives in the
sibling `../ssruntime_dart/` package.

| `lib/ssplayer_flutter.dart` | Public API barrel (L2–L4; import L1 from `ssruntime_dart` directly). |
| `../ssruntime_dart/` | **L1** binding package (plain Dart, non-Flutter): ffigen `@Native` top-level C-API bindings (`lib/src/ssruntime_bindings.g.dart`; native lib bundled by `hook/build.dart`) + runtime FlatBuffers `lib/src/fbs/{framedata,effect_draw_plan}.g.dart` (imported as `package:ssruntime_dart/framedata.dart`). |
| `../ssconverter_dart/` | Host `.sspj`→`.ssab` converter — ffigen `@Native` bindings to the host `libssconverter` dylib (`lib/src/ssconverter_bindings.g.dart`; dylib bundled by `hook/build.dart`) behind the `ssconvert` CLI + `SsConverter` lib (desktop only). |
| `lib/src/internal_player.dart` | **L2** engine — FFI lifecycle, SoA getters, `paint` = `DrawBatch.kind` dispatch (`_emit{Normal,Mesh,Effect,Instance,Shape}Batch`). |
| `lib/src/render/geometry_builder.dart` | **L2** — `GeometryBuilder` (pure SoA→`ui.Vertices` bake) + `DrawFrame` (per-frame SoA bundle) + `MeshBuffers` (§8, CSR) / `ShapeBuffers` (§11, fixed stride). New kinds add build methods here. |
| `lib/src/render/blend.dart` | **L2** — `blendModeFor` (`BlendType`→`ui.BlendMode`); future PartColor coef table. |
| `lib/src/render/part_color.dart` | **L2** — PartColor (§10) reader (`PartColor.read`) + `PartColor.identity` passthrough. |
| `lib/src/render/mask.dart` | **L2** — Mask (§9) pure logic: `MaskPartFlags` (ssab PartData roles + writer geometry kind), `MaskPlan` (writer collection, scope, coverage bbox/UV), `MaskBits`. |
| `lib/src/render/effect.dart` | **L2** — Effect (§8): `EffectPart` (ssab effect binding) + `EffectSlots` (slot lifecycle, per-frame `step`, plan cache). |
| `lib/src/render/instance.dart` | **L2** — Instance (§8): `InstancePart` (ssab binding + pack resolution), `InstanceChild` (the child-player surface, so this stays below L2), `InstanceSlots` (slot lifecycle, per-frame `step`). |
| `shaders/partcolor.frag` | PartColor blend + mask replay — the shader every *peeled* part uses. |
| `shaders/mask_write.frag` | Writes one mask writer's bit into the coverage bitmap. |
| `lib/src/texture_registry.dart` | **L2** — pure texture store: hash→`ui.Image` + cached `shaderFor` (`ImageShader`). No blend/Paint logic. |
| `lib/src/texture_loader.dart` | `SsTextureLoader` — reference + embedded texture loading + per-cellmap routing (§16C). |
| `lib/src/instance_loader.dart` | `SsInstanceLoader` — fetches the external `.ssab` packs instance parts reference (the async half; L2 builds children synchronously). |
| `lib/src/ssab_info.dart` | `SsAnimeInfo` — enumerate animation/cellmap names from bytes. |
| `lib/src/player.dart` | **L3** `SpriteStudioPlayer`. |
| `lib/src/render/sprite_studio_view.dart` | **L4** `SpriteStudioView` / `SpriteStudioRenderBox`. |
| `lib/src/ssab/*.g.dart` | flatc-generated `.ssab`/`.ssqb` **asset-format** accessors (do not hand-edit; runtime `framedata`/`effect` FlatBuffers live in `ssruntime_dart`). |
| `scripts/*` | Native build + codegen toolchain (below). |
| `examples/overall/` | overall/Basic validation app. |

## Toolchain scripts

All mirror the sibling players (`../SSPlayerFor{Godot,Unity,Web,RenPy}`).
`.sh` + `.ps1` variants; SDK located via `$SSSDK`, else `./SpriteStudio-SDK`.

| Script | Does | When |
|---|---|---|
| `scripts/build-runtime.{sh,ps1}` | Builds `ssruntime`/`ssconverter` (host direct; cross via `SpriteStudio-SDK/scripts/release-*`) and places the **bare** dynamic libs into each binding package's `native/libs/<platform>/[<arch>]` — `libssruntime` → `ssruntime_dart`, the host `libssconverter` → `ssconverter_dart`. No framework wrapping / `macos/Frameworks/` symlink on the Flutter side: each package's `hook/build.dart` bundles the dylib as a **native-assets code asset** (Flutter re-wraps it into `ssruntime.framework` inside the `.app` automatically). Then copies the SDK `build.rs`-emitted plain-C headers (`<crate>.h`) into each package's `native/include/` — but does **not** regenerate the ffigen bindings (they are committed; that is a separate manual step). | After changing Rust / first setup. |
| `scripts/generate-ffigen-code.{sh,ps1}` | `dart run ffigen` → each package's `lib/src/*_bindings.g.dart` (`@Native` top-level bindings) from `native/include/*.h`. **No cbindgen** — the SDK `build.rs` emits the C header. **Standalone** — NOT invoked by `build-runtime`; run it yourself after a C-API change and commit the result. | After a native / C-API change (then commit). |
| `scripts/generate-fbs-code.{sh,ps1}` | `flatc --dart` → `lib/src/ssab/*.g.dart` from the SDK `.fbs`. Standalone (deliberately NOT part of `build-runtime`). | After changing a `.fbs` schema. |
| `scripts/deploy-examples.sh` | Converts `tests/overall/overall.sspj` → `.ssab` into `examples/overall/assets/spritestudio/overall/`. | Refreshing example assets. |

> There is **no** `download-sdk` script: a Rust-less consumer gets the prebuilt
> `libssruntime` from `ssruntime_dart/hook/build.dart`'s download branch (see the
> Native-packaging gotcha), not a separate setup step.

## Hard constraints & gotchas

These were learned the hard way — respect them.

* **Never call `PartState.updateFlag`.** The flatc-generated `bit_flags` enum's
  `fromValue` throws `StateError` on any OR-combined value (i.e. almost always).
  Read the raw `uint64` from the FrameData buffer and bitwise-AND. Phase-1 Basic
  sidesteps this with the 4-corner quad; the 5-vertex center fan is only needed
  when `update_flag & (AttributeVertex | AttributePartColor)`.
* **`local_uvs` are texture-PIXEL coordinates, stride 10** (`lt,rt,lb,rb,center`),
  not normalized and not ×8 (the design doc's "×8" predates this runtime). In
  Flutter, `ImageShader` with an identity matrix samples in image pixels, so pass
  the UVs straight to `drawVertices` — no scaling. `local_vertices` is also
  stride 10. World matrix is column-major 4×4:
  `x' = m0·x + m4·y + m12`, `y' = m1·x + m5·y + m13`.
* **Texture key = `cellmap.name_hash` == `DrawBatch.texture_hash`.** Use the
  pre-baked hash; never re-implement FNV-1a on the Dart side. For runtime name→id
  use `ss_runtime_hash_string`.
* **Coordinate system = 1 (Y-Down); the Brain applies the flip once.** Do not
  double-flip in the Body. The flagship sets only `coordinate_system`, leaving
  origin/unit at defaults; positioning is the Body's job (`paint` centers on `dst`).
* **FFI pointer lifetime.** `FrameData` + SoA pointers are borrows into the
  Brain's internal buffer, valid only until the next `update` — consume within
  the frame. `Context`/`Resource` are freed by `dispose()`; a `NativeFinalizer`
  is a backstop. The borrowed `.ssab` native buffer must outlive the resource
  (borrow mode). Call `get_frame_data(frame)` BEFORE reading the SoA getters.
* **ffigen types.** ffigen maps `const unsigned char *` → `Pointer<UnsignedChar>`
  and `uintptr_t *` → `Pointer<UintPtr>`. L2 keeps ergonomic `Uint8`/`Size`
  scratch cells and `.cast()`s at the FFI boundary.
* **Native packaging = native assets (no CocoaPods framework on Flutter).** The
  Brain reaches the app through Dart's **build hooks**: `ssruntime_dart/hook/build.dart`
  emits a `CodeAsset(package: 'ssruntime_dart', name: 'ssruntime', file: <bare dylib
  from native/libs/<platform>/<arch>>, linkMode: DynamicLoadingBundled())`, and the
  generated `@Native` bindings carry a matching `@ffi.DefaultAsset('package:ssruntime_dart/ssruntime')`.
  `build.dart` resolves that `file` in priority order: (1) a consumer override
  `hooks.user_defines.ssruntime_dart.libssruntime` (bring-your-own dylib), (2) the
  package's local `native/libs/…` (source checkout / `build-runtime.sh`), else
  (3) a **download** of the pinned SDK release asset (`_sdkVersion` in `build.dart`)
  cached under `outputDirectoryShared` — so a pub.dev consumer with no Rust
  toolchain gets the Brain automatically (this replaced the old `download-sdk`).
  `dart`/`flutter test` and `flutter build` run the hook automatically (native assets
  is stable & default-on since Flutter 3.38 / Dart 3.10). On macOS, Flutter re-wraps
  the bundled dylib into `Contents/Frameworks/ssruntime.framework` and records the
  mapping in `flutter_assets/NativeAssetsManifest.json` (`package:ssruntime_dart/ssruntime`
  → `ssruntime.framework/ssruntime`) — verified: the runtime *is* embedded, dlopen-resolved
  at runtime, no `@rpath` link-time dependency on the main binary. So there is **no**
  vendored podspec, `macos/Frameworks/` symlink, or `SSRUNTIME_LIBRARY_PATH`; the
  example's `macos/` needs no CocoaPods plugin integration (`pod install` re-syncs
  cleanly with zero plugin pods). `ssconverter_dart` bundles the host `libssconverter`
  the same way. NB: the SDK still builds the versioned `libssruntime.framework` via
  `scripts/make-macos-framework.sh` for the universal release + the other players
  (Godot/Unity/RenPy consume it directly) — only Flutter's *consumption* moved to
  native assets. **iOS/Android** go through the same `ssruntime_dart/hook/build.dart`
  (only that runtime hook; `ssconverter_dart` is a desktop-only host tool). Android
  resolves one bare `.so` per NDK ABI (`native/libs/android/{arm64-v8a,armeabi-v7a,x86_64}/`);
  iOS uses **bare per-slice dylibs, NOT an xcframework** — the hook is invoked once
  per `code.iOS.targetSdk`, so it picks
  `native/libs/ios/{iphoneos,iphonesimulator}/<arch>/libssruntime.dylib` (device-arm64,
  sim-arm64 and sim-x86_64 are distinct Mach-O targets that can't share a slice —
  that is what an xcframework separates). `build-runtime.sh` places these; Flutter's
  embedding wraps+signs the chosen slice like on macOS. **Verified 2026-07-13**:
  the example renders on an iOS **simulator** (iphonesimulator/arm64) and an Android
  **emulator** (APK bundles all three ABIs under `lib/<abi>/`; ran on x86_64/arm64) —
  `[ssplayer] OK` + on-screen animation on both. Still unconfirmed: a physical iOS
  device (iphoneos slice, code-signed) and the armeabi-v7a ABI at runtime.
* **Generated code is never hand-edited.** The flatc FlatBuffers accessors are
  **committed** — asset format in `ssplayer_flutter/lib/src/ssab/`, runtime output
  in `ssruntime_dart/lib/src/fbs/` (schema-driven; regenerate with
  `generate-fbs-code`, which routes each `.fbs` to its owning package). The ffigen
  bindings (each binding package's `lib/src/*_bindings.g.dart`) are **also
  committed** (like the flatc accessors) so a normal checkout / pub.dev consumer
  builds without ffigen — they track the native C-API and are regenerated by the
  **standalone** `generate-ffigen-code` (globbing `packages/*/ffigen*.yaml`),
  NOT by `build-runtime`; run it after a C-API change and commit. Each package's
  `native/` (prebuilt libs + copied C headers) is gitignored. The SDK
  `build.rs` emits two headers per crate: `<crate>.h` (plain C — ffigen input +
  framework module-map umbrella) and `<crate>.hpp` (C++ — Godot); both ship in the
  release `include/`.
* **Blend types (`render/blend.dart`, `blendModeFor`)**: the SS `BlendType` →
  `ui.BlendMode` table is ported from **ssplayer-webgl** (`SSWebGLRenderer.applyBlend`),
  which realises every mode as a fixed-function GL blend state. Read against a
  premultiplied source + opaque dst, most rows have an **exact** stock Skia mode —
  Mix→`srcOver`, Add→`plus`, Mul/Mulalpha/Mul2→`multiply`, Screen/Screen2→`screen`,
  Exclusion→`exclusion`. The two Flutter's fixed enum can't express are Sub
  (reverse-subtract) and Invert (dst-replace `Cs·(1-Cb)`) → both approximate to
  `difference` (exact in the darkening / opaque-overlay regime each targets; a
  pixel-exact pass would need a framebuffer read-back the immediate-mode canvas
  lacks). Div2/Overlay2 have no upstream GL mapping → `srcOver`. Straight
  (non-premultiplied) authoring alpha. The 4-mode **PartColor** blend (§10) is a
  separate *shader-side* concern (`FragmentProgram`), not this framebuffer mapping.
* **Flutter's fragment-shader dialect is NOT full GLSL.** `impellerc` rejects
  **integer bitwise operators** (`<<`, `>>`, `&`, `|`, `~`) and **`discard`** —
  runtime effects are SkSL *shaders*, which return a colour. Port bit twiddling
  to float arithmetic (`bitAt(set, 2^i) = floor(mod(set/p, 2.0))`; an 8-bit
  `~x` is `255.0 - x`; a 24-bit set is exact in a float32 mantissa) and replace
  `discard` with `fragColor = vec4(0.0)` — a zero premultiplied fragment is a
  no-op under every blend mode we emit. Shaders also get **no per-vertex
  varyings**, which is why `drawVertices` can't feed them: a shaded part is
  peeled onto its own `drawPath` and its UVs are rebuilt from a CPU affine
  (`buildPartColorQuad`). **`flutter test` compiles the shaders** (impellerc runs
  in the asset build), so a dialect error shows up there — but the tests still
  pass, because the programs merely fail to load and the code falls back. Grep
  the test output for `impellerc failure` / `SkSL Error`; fragment programs never
  *execute* headless, so shader output can only be verified in `examples/overall/`.
* **Mesh (§8) vertices are ALREADY world-space — do not apply the world matrix.**
  The opposite of the Normal path (`local_vertices`, which you must transform).
  `mesh_vertices_x/_y` are a separate-axis SoA; `mesh_uvs` are interleaved and in
  texture-pixel space like `local_uvs` (so on Flutter they pass straight through
  — the Godot flagship's `* inv_tex_size` is Godot needing normalised UVs, not a
  step you port); `mesh_indices` are **part-local, 0-based**. All four slice by a
  CSR prefix sum of length `parts + 1` (`[offsets[p], offsets[p+1])`, empty for a
  non-mesh part) — guard `p + 1 < len`. A Mesh `DrawBatch` **is batchable**
  (`count > 1`), so concatenating parts into one `drawVertices` means rebasing
  each part's indices by its vertex base. UVs/indices are static (a mesh part
  can't change cell), but re-fetch every pointer each frame anyway: `play()`
  clears the static mesh Vecs, which can reallocate them. Only `RenderMode`
  Direct fills these (we set it at load); SceneGraph leaves them empty.
* **Effect (§8) inverts two conventions the other kinds share.** Its geometry
  never comes from the SoA: `ss_effect_slot_step` returns an `EffectDrawPlan`
  (its own FlatBuffers root, valid only until that slot steps again). (a) The
  plan's verts are in the **slot's own simulation space** — the step API takes no
  matrix — so the Body applies the effect part's world matrix (mesh is the
  opposite). (b) The plan's UVs are **normalised 0..1** (the runtime divides by
  `size_original`), while `local_uvs`/`mesh_uvs` are texture pixels — Flutter
  samples in pixels, so scale them back up. Also: `EffectDrawCommand.blend` is
  the raw SS6 byte (`0=Mix, 1=Add`), **not** a `BlendType` — passing it to
  `blendModeFor` reads 1 as Mul (use `effectBlendModeFor`); the plan carries no
  part alpha, so fold `alphaOf(part)` into the vertex colours; an Effect batch's
  `texture_hash`/`vertex_count`/`index_count` are meaningless (texture is per
  `command.cellmap_hash`); commands with `quad_count == 0` are emitted for
  unresolved cells; and indices are 0..`quad_count*4` **within a command**, so
  they need rebasing only if you merge commands. Slots are stepped from
  `update` (where the delta is), not `paint`, and must be reset on `play()` /
  `setupAnimation` or the "last started key" debounce eats the first key.
* **Instance (§8): the Brain owns everything except the child itself.** Every
  playback attribute — start/end labels, loop count, speed, reverse, pingpong,
  independent — is resolved *inside* `ss_instance_slot_step`. Never read
  `PartAttributeInstance` (the flagship has 0 references to it), and never branch
  on `ev.is_synthetic_default`. The Body owns exactly three things: a child
  player per instance part (own Context **and** Resource; `ss_instance_slot_create()`
  takes **no arguments** and binds no resource — `step` takes the *child* ctx per
  call, while `ss_runtime_get_active_event_instance` is resolved against the
  *parent*), resolving `external_instances` (`<baseAssetDir>/<pack>.ssab`; a
  same-pack sub-animation is absent from that manifest and resolves against the
  own bytes), and drawing. Slot index == **part index**. Gotchas, each one bought
  with a bug:
  - **`play()` on `transitioned` is MANDATORY, not a courtesy.** `step` configures
    the child (section/direction/loop) but leaves it **stopped**, and returns the
    *pre-play* frame on that tick, expecting the host to snap it to the start.
    Skip it and `Context::update` no-ops on the stopped controller, so every
    `independent` child freezes forever while synced ones look fine (they are
    seeked, not updated). The Godot header's 「コントローラは step() 内で既に設定・
    再生済み」 is *half* true — 設定 yes, 再生 **no**; trust `InstanceSlot::step` in
    `libs/ssruntime/src/lib.rs`. Because the returned frame is stale on that tick,
    re-read the child's clock after `play()` or you flash a frame of the previous
    playthrough. Also `stop()` the child at setup so it can't self-advance before
    its key fires.
  - **`childFrame` must stay raw.** Never floor/clamp the *stored* value: it is
    handed back down as the grandchildren's `parent_frame`, and a synced child is
    seeked to `(parent_frame - event_frame) * speed`, so rounding it quantizes
    every synced descendant to integer frames. Round only at draw. (The flagship
    propagates the rounded draw frame here when sub-frame is off; we don't.)
  - `subFrame` must propagate to children recursively, or they stutter at integer
    frames under a smooth parent.
  - The child's clock is the parent's slot, so a child must **not** call
    `ss_runtime_update` — but its *own* effects and nested instances still need a
    per-tick step at the frame the slot moved it to.
  - Unlike Godot (retained CanvasItems: draw the child early, re-parent later)
    Flutter is immediate-mode — paint the child **recursively** inside the
    Instance batch under `canvas.transform(slotMatrix)`. That also gets ordering
    for free: the whole child occupies exactly the instance part's z-slot and can
    never interleave with the parent's parts. Use only the 2D affine
    (`GeometryBuilder.world2dOf`), not the Brain's raw 4×4.
  - Alpha folds *down* (`DrawFrame.alphaScale`), never a `saveLayer`: group alpha
    differs from Godot's cascading per-item modulate wherever child parts overlap.
  - Nesting is expanded eagerly and **unbounded**, like every sibling player — a
    cyclic `.ssab` overflows the stack. Deliberate: `.ssab` is trusted input (the
    Brain does not validate it either), and a depth cap only ever fires on nesting
    the editor cannot practically author while silently dropping the innermost
    child if it did. `SsInstanceLoader`'s per-pack dedup is *not* that guard — it
    is plain fetch-once, and it does bound the asset walk.
* **Shape (§11) is Normal's geometry rules with Mesh's batching — and it is the
  one kind PartColor does NOT go through the shader.** Three getters, no others:
  `ss_runtime_get_shape_{vertices,vertex_box_coords,vertex_counts}`.
  - **Fixed stride 24 floats (12 verts) per part — NOT CSR.** There is no offsets
    array; `shape_vertex_counts[p]` is the only slice, and a Shape batch's
    `vertex_count`/`index_count` are **0** (the Brain fills those for Normal
    only), so sizing a buffer from the batch silently allocates nothing. Guard
    `count < 3`. Non-shape parts carry count 0 + zero-filled slots, so the
    buffers are `parts × 24` long regardless.
  - **Vertices are LOCAL** — apply the world matrix (the opposite of Mesh, whose
    verts arrive world-space). Pivot and the Y-Down flip are already baked in.
  - **Geometry is a center-first TRIANGLE_FAN** `[center, perimeter…, closing]`,
    triangulated `(0, i+1, i+2)`. A Rectangle is deliberately 4 triangles from
    its center, not 2 across a diagonal, so a per-corner gradient does not crease.
    Shape batches are batchable → rebase each part's fan onto its vertex base.
  - **PartColor bypasses the compositing formula** (§1-2-3): the vertex colour is
    `pc.rgba` *directly*, forced Mix, rate pinned to 1, bilinearly weighted by
    `box_coords` (that buffer exists for exactly this). Alpha is pre-folded (the
    converter additionally forces `a=255` for a Mix shape so the product lands on
    the part's alpha) — do NOT re-multiply `PartState.alpha`. Without PartColor:
    white at the part's alpha. So the whole kind collapses to per-vertex colours
    and needs **no texture and no fragment program** — pair it with a **white**
    `Paint` under `BlendMode.modulate`. (The siblings instead rely on an unbound
    sampler returning white; Flutter has no such default, and a shader-less paint
    would modulate against opaque *black*.)
  - **Mask**: a Shape can be a pure mask (`draw_as_mask`) or a clipping writer,
    and its **polygon is the mask — no alpha cutout** (§2-5「シェイプの特例」:
    it has no cell, so there is no texel to threshold). `mask == 0` still
    disables the writer though — that rule is separate (`mask`「カットアウト閾値
    を兼ねる。0 で writer 無効」). A shape writer needs no texture and no shader:
    fill its triangles with the bit colour under `BlendMode.plus`, **AA off** (a
    coverage bit is a number; a half-covered edge decodes as another writer's
    bits). As a mask *target* it must be peeled — but a `FragmentProgram` cannot
    receive varyings, so the gradient can never come from the shader; instead
    `drawVertices(…, BlendMode.modulate, paint..shader = gate)` keeps the vertex
    colours and lets the shader answer only "does this fragment pass?".
  - **Two different `ShapeType` enums**: ssab is `Unknown=0, Triangle, Rectangle,
    Arrow, Star`; the Rust `core::geometry` one is `Rectangle=0, Triangle, Star,
    Arrow`. They are mapped by *name* in `lib.rs`, so both are correct in place —
    never assume the values interchange. The Body needs neither: the runtime
    hands over finished vertices.
  - **Arrow is broken upstream**: the runtime emits it as a bare 7-point polygon
    with no center vertex, while every player (this one included) fans it — so
    2 of its 5 triangles paint outside the arrow. Fix belongs in the SDK (give
    Arrow a center + closing vertex, count 7→9); see docs/status.ja.md.
* **PartColor alpha is either/or — the Brain pre-folds it (§1-3).** With a
  PartColor, the hierarchical alpha is already multiplied into `rgba.a`, so
  `a = texel.a * col.a` and re-multiplying `PartState.alpha` double-applies.
  Without one, §1-2-4 says the vertex is 「白（α は階層 α）／rate 0」 — the alpha
  must be supplied. That asymmetry is a trap for the *peeled* shader path: a part
  peeled only for a mask test (§9) has no PartColor, and handing it a shared α=1
  identity renders it fully opaque. Use `PartColor.passthrough(frame.alphaOf(p))`,
  and `scaleAlpha` only for the instance chain (which the Brain cannot pre-fold —
  it lives in the *parent's* FrameData).
* **Mask (§9) has no C-API — it is a data contract.** The roles come from the
  **static `.ssab` `PartData`** (`mask_write` / `draw_as_mask` /
  `visible_inside_mask` / `mask_influence`), read once at load
  (`MaskPartFlags.readAll`), NOT from `FrameData` and NOT from any SoA buffer;
  only `mask` / `priority` / `hide` are per-frame. `mask_influence` is
  **deliberately overloaded** (writer → OP invert/increment; target → opt-in) —
  never normalise it away. Ignore `FrameData.mask_indices`: the runtime omits
  clipping writers from it and *includes* hidden masks, so walk `draw_order` +
  `PartData` instead (the flagship does the same).

## Verification

Native libs must be built first (`scripts/build-runtime.sh`). The tests pick up
the Brain automatically via **native assets** — `dart`/`flutter test` runs the
binding package's `hook/build.dart`, which bundles the prebuilt dylib; there is
no `SSRUNTIME_LIBRARY_PATH` / `DynamicLibrary.open` and no framework to point at.

| Check | Command (run in `packages/ssplayer_flutter/`) |
|---|---|
| Analyze | `flutter analyze lib test` |
| Unit + render tests | `flutter test` |
| L1 bindings smoke (in `../ssruntime_dart/`) | `dart test` |
| Converter smoke + CLI (in `../ssconverter_dart/`) | `dart test` / `dart run ssconverter_dart:ssconvert -o <out> <sspj>` |
| Native host build (also copies C headers) | `bash ../../scripts/build-runtime.sh` |
| ffigen bindings only | `bash ../../scripts/generate-ffigen-code.sh` |
| FlatBuffers (on `.fbs` change) | `bash ../../scripts/generate-fbs-code.sh` |
| macOS desktop run | (in `examples/overall/`) `flutter run -d macos` → expect `[ssplayer] OK` |
| macOS embedding check | (in `examples/overall/`) `flutter build macos` → `ssruntime.framework` under `*.app/Contents/Frameworks/` |

`examples/overall/` is analyzed as its own package (path dependency on the `ssplayer_flutter`
package; no longer a Flutter plugin — native assets replace the plugin/podspec).

## Render recipe (Phase 1 Basic)

Per frame: `update(dt)` → `get_frame_data(frameNo)` → iterate `draw_batches`;
for `kind == Normal`, gather `draw_order[start_rank .. +count]` parts, bake each
part's 4 world-transformed corners + pixel UVs + white×`alpha` vertex colors +
quad indices into one indexed `ui.Vertices`, and `drawVertices(v,
BlendMode.modulate, paint)` once per batch (`paint` = `ImageShader(texture)` +
framebuffer blend). Sub-frame sampling is ON by default. See
`SpriteStudio-SDK/libs/ssruntime/docs/30_core/30_render_loop.ja.md` and the
Flutter architecture design doc.

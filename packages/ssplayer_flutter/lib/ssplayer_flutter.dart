/// SpriteStudio player for Flutter.
///
/// A dart:ffi "Body" over the SpriteStudio-SDK Rust "Brain" (libssruntime).
/// Layering (top → bottom): [SpriteStudioView] (L4 adapter) →
/// [SpriteStudioPlayer] (L3 control) → [SpriteStudioInternalPlayer] (L2 draw
/// engine) → [SsRuntimeBindings] (L1 dart:ffi).
library;

// Layer 4 — drawing adapters.
export 'src/render/sprite_studio_view.dart';
// The same layer, for the caller who has no reason to own a player: builds one
// from an asset key, loads it, starts it and disposes it.
export 'src/render/sprite_studio_animation.dart' show SpriteStudioAnimation;
// Part following (ForUnity part tracker / ForGodot part attachment, done the
// Flutter way): a Widget that sticks to a part's live transform. The read API it
// drives (partTransform / isPartHidden) lives on SpriteStudioPlayer.
export 'src/render/part_anchor.dart'
    show
        SpriteStudioPartAnchor,
        SpriteStudioAnchorHidden,
        SpriteStudioAnchorMirror;

// Layer 3 — user-facing controller.
export 'src/player.dart' show SpriteStudioPlayer, SsEventCallback;
// Playback shape — the direction / round-trip enums taken by
// SpriteStudioPlayer.setPlaybackDirection.
export 'src/playback.dart' show SsPlaybackDirection, SsPlaybackStyle;
// Render backend selector (Canvas default / flutter_gpu opt-in). Passed to the
// SpriteStudioPlayer constructor.
export 'src/render/backend/backend_kind.dart' show SpriteStudioBackend;
export 'src/event.dart'
    show
        SsUserData,
        SsSignal,
        SsSignalParam,
        SsAudioEvent,
        SsUserDataCallback,
        SsSignalCallback,
        SsAudioCallback;

// Layer 2 — Widget-agnostic draw engine (reusable headless / Flame / GPU).
export 'src/internal_player.dart' show SpriteStudioInternalPlayer;
// The player-level flip / offset, resolved in one place and read by both the
// drawing path and the part poses (SpriteStudioPlayer.flipX / flipY / offset are
// the shorthand most callers want).
export 'src/render/root_transform.dart' show SsRootTransform;
export 'src/texture_registry.dart' show TextureRegistry;
export 'src/texture_loader.dart' show SsTextureLoader, TextureLoadReport;
export 'src/instance_loader.dart' show SsInstanceLoader, InstancePackLoadResult;
export 'src/ssab_info.dart' show SsAnimeInfo, SsPassedEvents;
// Render helpers — reusable SoA→Vertices bake + blend mapping.
export 'src/render/geometry_builder.dart'
    show
        GeometryBuilder,
        DrawFrame,
        MeshBuffers,
        MeshGeometry,
        PartColorQuad,
        ShapeBuffers;
export 'src/render/blend.dart'
    show
        BlendPass,
        BlendPassSource,
        blendModeFor,
        blendPassesFor,
        effectBlendModeFor,
        partColorCoef;
export 'src/render/effect.dart' show EffectPart, EffectSlots;
export 'src/render/instance.dart'
    show InstanceChild, InstancePart, InstanceSlot, InstanceSlots;
export 'src/render/part_color.dart' show PartColor, PartColorCorner;
// Integration shaders (`SHDR`) — the built-in `ss-*` effect catalog and the
// per-part attribute reader. The programs themselves live in shaders/.
export 'src/render/part_shader.dart' show PartShader, SsShaderId;
// Part overrides — the enums and the part-name table the by-name
// overrides resolve through. The calls themselves live on the L2/L3 players.
export 'src/render/part_override.dart'
    show SsBlendOp, SsCornerColors, SsOverridePriority, PartNameTable, packRgba;
export 'src/render/mask.dart'
    show
        MaskBits,
        MaskComposition,
        MaskPartFlags,
        MaskPlan,
        MaskWriter,
        kMaxMaskWriters,
        noCutoutThreshold;

// Layer 1 — the raw dart:ffi C-API (the "escape hatch") lives in the pure-Dart
// `ssruntime_dart` package as native-assets `@Native` functions. Import it
// directly for low-level access: `package:ssruntime_dart/ssruntime_dart.dart`.

// Web bootstrap: on the web the Brain is a wasm module loaded asynchronously, so
// call `await loadSsRuntime()` once (e.g. in `main`, before `runApp`) before any
// player is created. A no-op on native, where the native asset resolves eagerly.
export 'package:ssruntime_dart/ssruntime_dart.dart' show loadSsRuntime;

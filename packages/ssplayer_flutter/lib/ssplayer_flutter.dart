/// SpriteStudio 7 player for Flutter.
///
/// A dart:ffi "Body" over the SpriteStudio-SDK Rust "Brain" (libssruntime).
/// Layering (design §2, top → bottom): [SpriteStudioView] (L4 adapter) →
/// [SpriteStudioPlayer] (L3 control) → [SpriteStudioInternalPlayer] (L2 draw
/// engine) → [SsRuntimeBindings] (L1 dart:ffi).
library;

// Layer 4 — drawing adapters.
export 'src/render/sprite_studio_view.dart';

// Layer 3 — user-facing controller.
export 'src/player.dart' show SpriteStudioPlayer, SsEventCallback;
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
    show blendModeFor, effectBlendModeFor, partColorCoef;
export 'src/render/effect.dart' show EffectPart, EffectSlots;
export 'src/render/instance.dart'
    show InstanceChild, InstancePart, InstanceSlot, InstanceSlots;
export 'src/render/part_color.dart' show PartColor, PartColorCorner;
export 'src/render/mask.dart'
    show
        MaskBits,
        MaskPartFlags,
        MaskPlan,
        MaskWriter,
        kMaxMaskWriters,
        noCutoutThreshold;

// Layer 1 — the raw dart:ffi C-API (the "escape hatch") lives in the pure-Dart
// `ssruntime_dart` package as native-assets `@Native` functions. Import it
// directly for low-level access: `package:ssruntime_dart/ssruntime_dart.dart`.

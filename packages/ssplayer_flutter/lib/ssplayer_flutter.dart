/// SpriteStudio 7 player for Flutter.
///
/// A dart:ffi "Body" over the SpriteStudio-SDK Rust "Brain" (libssruntime).
/// Layering (design §2, top → bottom): [SpriteStudioView] (L4 adapter) →
/// [SpriteStudioPlayer] (L3 control) → [SpriteStudioInternalPlayer] (L2 draw
/// engine) → [SsRuntimeBindings] (L1 dart:ffi).
library ssplayer_flutter;

// Layer 4 — drawing adapters.
export 'src/render/sprite_studio_view.dart';

// Layer 3 — user-facing controller.
export 'src/player.dart' show SpriteStudioPlayer, SsEventCallback;

// Layer 2 — Widget-agnostic draw engine (reusable headless / Flame / GPU).
export 'src/internal_player.dart'
    show
        SpriteStudioInternalPlayer,
        SsResourceMode,
        SsCoordinateSystem,
        SsOrigin,
        SsUnit;
export 'src/texture_registry.dart' show TextureRegistry;
export 'src/texture_loader.dart' show SsTextureLoader, TextureLoadReport;
export 'src/ssab_info.dart' show SsAnimeInfo;
// Render helpers — reusable SoA→Vertices bake + blend mapping.
export 'src/render/geometry_builder.dart'
    show GeometryBuilder, DrawFrame, PartColorQuad;
export 'src/render/blend.dart' show blendModeFor, partColorCoef;
export 'src/render/part_color.dart' show PartColor, PartColorCorner;

// Layer 1 — raw dart:ffi bindings (the "escape hatch"; use with care).
export 'src/bindings/ssruntime_library.dart' show SsRuntime;
export 'src/bindings/ssruntime_bindings.g.dart'
    show SsRuntimeBindings, SS_RUNTIME_INVALID_HANDLE;

/// Flame adapter for `ssplayer_flutter`.
///
/// Adds a Layer-4 drawing adapter, [SpriteStudioComponent], that plays a
/// SpriteStudio `.ssab` inside a `FlameGame`, and a button made of one,
/// [SpriteStudioButtonComponent]. It reuses the whole
/// `ssplayer_flutter` player (L3 transport + L2 draw engine) in
/// externally-clocked mode, so Flame's game loop supplies the time.
///
/// Everything else — the raw `.ssab` API, `SpriteStudioPlayer`, textures — comes
/// from `package:ssplayer_flutter/ssplayer_flutter.dart`, which this package
/// re-exports for convenience.
library;

export 'package:ssplayer_flutter/ssplayer_flutter.dart';

export 'src/sprite_studio_component.dart' show SpriteStudioComponent;
// A button whose states one animation shows, on the state rule of
// `package:ssplayer_flutter/ui.dart`.
export 'src/sprite_studio_button_component.dart'
    show SpriteStudioButtonComponent;
export 'package:ssplayer_flutter/ui.dart' show SsUiClip, SsUiState;

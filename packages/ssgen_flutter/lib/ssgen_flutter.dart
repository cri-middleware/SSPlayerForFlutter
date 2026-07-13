/// Flutter dev-tooling for SpriteStudio live-reload — a [State] mixin that rides
/// Flutter's own hot reload to rebuild the art and hot-swap it in place.
///
/// See [SsLiveReload]. DEV ONLY — the `ssplayer_flutter` runtime stays
/// converter-free; add this package only in apps that want in-app live-reload.
library;

export 'src/live_reload.dart' show SsLiveReload;

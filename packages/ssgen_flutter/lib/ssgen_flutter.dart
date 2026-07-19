/// Flutter dev-tooling for SpriteStudio live-reload — a [State] mixin that rides
/// Flutter's own hot reload to rebuild the art and hot-swap it in place.
///
/// See [SsLiveReload]. DEV ONLY — the `ssplayer_flutter` runtime stays
/// converter-free; add this package only in apps that want in-app live-reload.
library;

export 'src/live_reload.dart' show SsLiveReload;
// The in-app end of the VM-Service dev push channel (`ext.ssgen.reload`). The
// SsLiveReload mixin auto-registers with it; exposed for apps that wire their
// own live-reload target without the mixin.
export 'src/dev_channel.dart' show SsDevChannel, SsLiveReloadTarget;
// The `--dart-define` key that opts an app into `.ssab` live-reload — apps gate
// their `ssLiveReloadEnabled` on it; `ssdev` injects it.
export 'src/ss_defines.dart' show ssLiveReloadDefine;

/// Flutter dev-tooling for SpriteStudio live-reload — a [State] mixin that joins
/// the VM-Service push channel so the `sswatch` host runner can hot-swap the art
/// in place on save, with no keypress and the IDE debugger left attached.
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
// their `ssLiveReloadEnabled` on it; `sswatch --run` injects it.
export 'src/ss_defines.dart' show ssLiveReloadDefine;

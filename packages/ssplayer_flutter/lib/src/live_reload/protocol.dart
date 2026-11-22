/// The `--dart-define` key that opts an app into SpriteStudio `.ssab`
/// live-reload. `sswatch --run` injects `=true`; the in-app channel
/// (`SsDevChannel`) comes up only in a debug build that carries it, so a plain
/// `flutter run` does normal Dart hot reload without touching the art. Shared by
/// `sswatch` (the injector) and the channel (the reader) so the key can't drift.
const ssLiveReloadDefine = 'SS_LIVE_RELOAD';

/// The `dart:developer` service-extension method the in-app dev push channel
/// (`SsDevChannel`) registers and the host `sswatch` runner calls over the VM
/// Service to hot-swap a pack. Shared here — a plain-Dart const with no imports —
/// so the Flutter-free `sswatch` and the Flutter-side channel can't drift.
/// Must start with `ext.` (the VM Service requires it for custom extensions).
const ssReloadExtensionMethod = 'ext.ssgen.reload';

/// The service-extension the host runner calls to enumerate the app's live
/// reload targets — each enabled target's `{assetDir, pack}`. `sswatch --device`
/// uses it to push a byte blob for **only the pack currently shown** (an
/// embedded `.ssab` is large, so pushing every pack would be wasteful). Shared
/// so the Flutter-free `sswatch` and the channel can't drift.
const ssTargetsExtensionMethod = 'ext.ssgen.targets';

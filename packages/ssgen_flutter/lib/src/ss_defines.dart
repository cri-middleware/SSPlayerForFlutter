/// The `--dart-define` key that opts an app into SpriteStudio `.ssab`
/// live-reload. The `ssdev` runner injects `=true`; [SsLiveReload]'s default
/// `ssLiveReloadEnabled` gates on it, so a plain `flutter run` does normal Dart
/// hot reload without reconverting art. Shared by `ssdev` (the injector) and the
/// mixin (the reader) so the key can't drift.
const ssLiveReloadDefine = 'SS_LIVE_RELOAD';

/// The `dart:developer` service-extension method the in-app dev push channel
/// ([SsDevChannel]) registers and the host `sswatch` runner calls over the VM
/// Service to hot-swap a pack. Shared here — a plain-Dart const with no imports —
/// so the Flutter-free `sswatch` and the Flutter-side channel can't drift.
/// Must start with `ext.` (the VM Service requires it for custom extensions).
const ssReloadExtensionMethod = 'ext.ssgen.reload';

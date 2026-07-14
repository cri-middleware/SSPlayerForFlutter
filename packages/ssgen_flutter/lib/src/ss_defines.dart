/// The `--dart-define` key that opts an app into SpriteStudio `.ssab`
/// live-reload. The `ssdev` runner injects `=true`; [SsLiveReload]'s default
/// `ssLiveReloadEnabled` gates on it, so a plain `flutter run` does normal Dart
/// hot reload without reconverting art. Shared by `ssdev` (the injector) and the
/// mixin (the reader) so the key can't drift.
const ssLiveReloadDefine = 'SS_LIVE_RELOAD';

/// The live-reload wire protocol: the define that opts an app in and the two
/// VM Service extensions the in-app channel registers.
///
/// Flutter-free on purpose, so the host `sswatch` runner (`ssgen_flutter`), a
/// plain Dart program, speaks the same names as the channel in this package.
/// An app never needs it: `package:ssplayer_flutter/ssplayer_flutter.dart`
/// exports the define.
library;

export 'src/live_reload/protocol.dart'
    show ssLiveReloadDefine, ssReloadExtensionMethod, ssTargetsExtensionMethod;

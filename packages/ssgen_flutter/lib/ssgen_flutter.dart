/// Public entry for the `sswatch` live-reload watcher internals (Flutter-free),
/// consumed by `bin/sswatch.dart` and its unit tests. See `src/sswatch.dart`.
library;

export 'package:ssplayer_flutter/live_reload_protocol.dart'
    show ssLiveReloadDefine, ssReloadExtensionMethod;
export 'src/sswatch.dart';

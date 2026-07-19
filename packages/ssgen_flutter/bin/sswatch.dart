// IDE-friendly SpriteStudio live-reload watcher — reconvert on save and push the
// fresh pack to a running app over the VM Service, without owning `flutter run`.
//
//   dart run ssgen_flutter:sswatch --vmservice-uri-file=<path>
//
// Launch the app yourself (IDE Run/Debug, or `flutter run
// --vmservice-out-file=<path> --dart-define=SS_LIVE_RELOAD=true`), then run this
// alongside it. Complements `ssdev` (which OWNS `flutter run`): use `sswatch`
// when you want the IDE debugger; use `ssdev` for a zero-key terminal session.
import 'package:ssgen_flutter/sswatch.dart' show runSsWatch;

Future<void> main(List<String> args) => runSsWatch(args);

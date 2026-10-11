// The SpriteStudio live-reload watcher — reconvert on save and push the fresh
// pack to a running app over the VM Service. The single dev runner.
//
//   dart run ssgen_flutter:sswatch --run -d macos          # own flutter run
//   dart run ssgen_flutter:sswatch --run -d <emu> --device # device (embedded)
//   dart run ssgen_flutter:sswatch --vmservice-uri-file=<path>  # attach (IDE)
//
// `--run` launches `flutter run` for you (one-command session); otherwise launch
// the app yourself (IDE Run/Debug, or `flutter run --vmservice-out-file=<path>
// --dart-define=SS_LIVE_RELOAD=true`) and attach — so the IDE debugger stays.
import 'package:ssgen_flutter/ssgen_flutter.dart' show runSsWatch;

Future<void> main(List<String> args) => runSsWatch(args);

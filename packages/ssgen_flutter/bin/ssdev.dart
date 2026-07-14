// Cross-platform SpriteStudio live-reload dev runner — the "Metro/Vite" for
// SpriteStudio. Replaces `flutter run` for a live session:
//
//   dart run ssgen_flutter:ssdev -d <device> [flutter run args...]
//
// It wraps `flutter run --machine`, watches `SpriteStudio_Source/`, and on save
// reconverts the stale projects (host libssconverter via SsProjectSync) then
// triggers a tool-mediated hot reload over the daemon protocol — so the fresh
// `.ssab` is DevFS-synced to the device and the app's reassemble reloads it.
// Works on Windows (no signals): the reload goes through the flutter tool's
// `app.restart`, which — unlike a raw VM-Service reloadSources — performs the
// DevFS asset sync. Injects `--dart-define=SS_LIVE_RELOAD=true` so the app's
// SsLiveReload activates its `.ssab` reload path.
import 'package:ssgen_flutter/ssdev.dart';

Future<void> main(List<String> argv) => runSsDev(argv);

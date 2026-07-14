import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show CachingAssetBundle, rootBundle;
import 'package:flutter/widgets.dart';
import 'package:ssgen_dart/ssgen_dart.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

import 'ss_defines.dart';

/// Wires SpriteStudio dev live-reload into a [State]: on Flutter's hot reload
/// (`State.reassemble`), rebuild the art and hot-swap it in place — so pressing
/// `r` (or an IDE Dart-save) also picks up SpriteStudio edits.
///
/// **Desktop** (host): reconvert only the STALE `SpriteStudio_Source` projects
/// via the host `libssconverter` ([SsProjectSync]), then reload the current pack
/// from the regenerated assets. One gesture (`r`) does everything.
///
/// **Device** (iOS/Android): the device can't run the host converter, so this
/// only reloads the current pack from `rootBundle`. The developer reconverts on
/// the host — `dart run ssgen_flutter:ssreconvert` — and `r` DevFS-syncs the
/// fresh `.ssab` to the device.
///
/// Implement [ssPlayer], [ssAssetDir], [ssPack]; everything else has a default.
/// The playhead / animation / play state survive the swap
/// ([SpriteStudioPlayer.reload]). Debug-only by construction — `reassemble` only
/// fires on hot reload. Not supported on web (as with the runtime).
///
/// ```dart
/// class _MyPageState extends State<MyPage> with SsLiveReload<MyPage> {
///   @override SpriteStudioPlayer get ssPlayer => _player;
///   @override String get ssAssetDir => 'assets/spritestudio/overall';
///   @override String get ssPack => _pack;
///   @override void ssOnLiveReloaded() => setState(() {});
/// }
/// ```
mixin SsLiveReload<T extends StatefulWidget> on State<T> {
  /// The player to hot-swap.
  SpriteStudioPlayer get ssPlayer;

  /// The current pack's asset directory — the [SsProjectSync] output for the
  /// project, e.g. `assets/spritestudio/overall` (a `rootBundle` key prefix; on
  /// desktop it is resolved under [ssProjectRoot]). Keep it the convention
  /// directory; suspend live-reload via [ssLiveReloadEnabled] for other sources.
  String get ssAssetDir;

  /// The current pack — the `.ssab` stem, e.g. `PartsColor`.
  String get ssPack;

  /// Gate live-reload (default: debug builds launched with the SpriteStudio
  /// live-reload define). `ssdev` injects it; otherwise pass
  /// `--dart-define=SS_LIVE_RELOAD=true`. So a plain `flutter run` does normal
  /// Dart hot reload without reconverting art. Return false to suspend it (e.g.
  /// while a drag-dropped source is shown); override to `kDebugMode` to always
  /// reconvert on hot reload.
  bool get ssLiveReloadEnabled =>
      kDebugMode && const bool.fromEnvironment(ssLiveReloadDefine);

  /// The project root holding `SpriteStudio_Source/` (desktop reconvert).
  /// Defaults to `--dart-define=SS_PROJECT_ROOT` else a walk-up from the
  /// executable (holds for `flutter run` debug builds; a macOS app's
  /// `Directory.current` is its sandbox container, not the project).
  String? get ssProjectRoot => _resolveProjectRoot();

  /// Called after a successful live-reload — e.g. `setState(() {})`.
  void ssOnLiveReloaded() {}

  /// Called when a live-reload throws.
  void ssOnLiveReloadError(Object error) {}

  bool _busy = false;

  @override
  void reassemble() {
    super.reassemble();
    if (!ssLiveReloadEnabled) return;
    if (_isDesktop) {
      _desktopReconvertReload();
    } else if (!kIsWeb) {
      _deviceReload();
    }
  }

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  Future<void> _desktopReconvertReload() async {
    if (_busy) return; // single-flight: don't overlap reload()/load()
    _busy = true;
    try {
      final root = ssProjectRoot;
      if (root == null) return;
      // Reconvert only the stale projects, then reload the current pack from its
      // (possibly regenerated) output under the same convention directory.
      await const SsProjectSync().reconvert(projectRoot: root);
      final dir = '$root/$ssAssetDir';
      final file = File('$dir/$ssPack.ssab');
      if (!file.existsSync()) return;
      await ssPlayer.reload(
        await file.readAsBytes(),
        bundle: _FileBundle(), // fresh instance → no stale cached bytes
        baseAssetDir: dir,
      );
      if (mounted) ssOnLiveReloaded();
    } catch (e) {
      if (mounted) ssOnLiveReloadError(e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _deviceReload() async {
    if (_busy) return;
    _busy = true;
    try {
      final key = '$ssAssetDir/$ssPack.ssab';
      rootBundle.evict(key); // belt-and-braces; Flutter also evicts changed keys
      final data = await rootBundle.load(key);
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await ssPlayer.reload(bytes, bundle: rootBundle, baseAssetDir: ssAssetDir);
      if (mounted) ssOnLiveReloaded();
    } catch (e) {
      if (mounted) ssOnLiveReloadError(e);
    } finally {
      _busy = false;
    }
  }

  static String? _resolveProjectRoot() {
    const sub = SsProjectSyncConfig.defaultSourceSubdir;
    const override = String.fromEnvironment('SS_PROJECT_ROOT');
    if (override.isNotEmpty) {
      return Directory('$override/$sub').existsSync() ? override : null;
    }
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 12; i++) {
      if (Directory('${dir.path}/$sub').existsSync()) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }
}

/// AssetBundle whose keys are absolute filesystem paths (desktop FS reads).
class _FileBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(key).readAsBytes());
}

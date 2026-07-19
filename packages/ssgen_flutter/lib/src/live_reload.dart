import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

import 'dev_channel.dart';
import 'ss_defines.dart';

/// Wires SpriteStudio dev live-reload into a [State] and hot-swaps the current
/// pack in place, with the playhead / animation / play state preserved
/// ([SpriteStudioPlayer.reload]).
///
/// **Desktop** (host): reload is driven by the VM-Service **push channel**
/// ([SsDevChannel]) — run `dart run ssgen_flutter:sswatch` (or `ssdev`)
/// alongside the app. On save it reconverts the stale `SpriteStudio_Source`
/// projects (host `libssconverter`) and pushes the fresh pack straight to this
/// player: no `r`, and it works under an IDE debugger. The mixin just registers
/// this target with the channel — there is no in-process reconvert on
/// `reassemble` anymore.
///
/// **Device** (iOS/Android): the device can't run the host converter and can't
/// read a host path, so device reload still rides Flutter's own hot reload
/// (`State.reassemble`): reconvert on the host with `dart run
/// ssgen_flutter:ssreconvert` (or the `ssdev` device runner) and `r` DevFS-syncs the
/// fresh `.ssab`, which this reloads from `rootBundle`. (A later release moves
/// device onto the push channel too; see the live-reload design doc.)
///
/// Implement [ssPlayer], [ssAssetDir], [ssPack]; everything else has a default.
/// Debug-only by construction (the push channel and `reassemble` only exist in
/// debug). Not supported on web (as with the runtime).
///
/// ```dart
/// class _MyPageState extends State<MyPage> with SsLiveReload<MyPage> {
///   @override SpriteStudioPlayer get ssPlayer => _player;
///   @override String get ssAssetDir => 'assets/spritestudio/overall';
///   @override String get ssPack => _pack;
///   @override void ssOnLiveReloaded() => setState(() {});
/// }
/// ```
mixin SsLiveReload<T extends StatefulWidget> on State<T>
    implements SsLiveReloadTarget {
  /// The player to hot-swap.
  @override
  SpriteStudioPlayer get ssPlayer;

  /// The current pack's asset directory — the reconvert output for the project,
  /// e.g. `assets/spritestudio/overall` (a `rootBundle` key prefix). Keep it the
  /// convention directory; suspend live-reload via [ssLiveReloadEnabled] for
  /// other sources.
  @override
  String get ssAssetDir;

  /// The current pack — the `.ssab` stem, e.g. `PartsColor`.
  @override
  String get ssPack;

  /// Gate live-reload (default: debug builds launched with the SpriteStudio
  /// live-reload define). `ssdev`/`sswatch` inject it; otherwise pass
  /// `--dart-define=SS_LIVE_RELOAD=true`. So a plain `flutter run` does normal
  /// Dart hot reload without touching the art. Return false to suspend it (e.g.
  /// while a drag-dropped source is shown); override to `kDebugMode` to always
  /// accept a live-reload.
  @override
  bool get ssLiveReloadEnabled =>
      kDebugMode && const bool.fromEnvironment(ssLiveReloadDefine);

  /// Called after a successful live-reload — e.g. `setState(() {})`.
  @override
  void ssOnLiveReloaded() {}

  /// Called when a live-reload throws.
  @override
  void ssOnLiveReloadError(Object error) {}

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Join the VM-Service push channel so `sswatch`/`ssdev` can hot-swap this
    // player without `r` — this is the desktop reload path. Inert with no
    // watcher connected.
    SsDevChannel.instance.register(this);
  }

  @override
  void dispose() {
    SsDevChannel.instance.unregister(this);
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    // Desktop reload comes from the push channel (SsDevChannel), not reassemble.
    // On a device, reassemble is still how an `r`-synced `.ssab` is reloaded.
    if (!ssLiveReloadEnabled || kIsWeb || _isDesktop) return;
    _deviceReload();
  }

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  Future<void> _deviceReload() async {
    if (_busy) return; // single-flight: don't overlap reload()/load()
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
}

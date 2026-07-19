import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

import 'dev_channel.dart';
import 'ss_defines.dart';

/// Wires SpriteStudio dev live-reload into a [State]: registers this player's
/// current pack with the VM-Service dev push channel ([SsDevChannel]) so the
/// `sswatch` host runner can hot-swap it in place — playhead / animation / play
/// state preserved ([SpriteStudioPlayer.reload]) — on desktop and device alike,
/// with no `r` and the IDE debugger left attached.
///
/// Run the watcher alongside the app:
/// ```
/// dart run ssgen_flutter:sswatch --run -d macos            # own flutter run
/// dart run ssgen_flutter:sswatch --run -d <emu> --device   # device (embedded)
/// dart run ssgen_flutter:sswatch --vmservice-uri-file=<f>  # attach (IDE)
/// ```
/// On save it reconverts the stale `SpriteStudio_Source` projects (host
/// `libssconverter`) and pushes the fresh pack to this player over the VM
/// Service. The mixin itself only registers/unregisters the target; the reload
/// is delivered by the channel, so a plain `flutter run` without `sswatch` does
/// ordinary Dart hot reload and leaves the art alone.
///
/// Implement [ssPlayer], [ssAssetDir], [ssPack]; the rest has a default.
/// Debug-only by construction (the push channel only exists in debug). Not
/// supported on web (as with the runtime).
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
  /// e.g. `assets/spritestudio/overall` (a `rootBundle` key prefix; also the key
  /// the host uses to route a `file` vs embedded push). Keep it the convention
  /// directory; suspend live-reload via [ssLiveReloadEnabled] for other sources.
  @override
  String get ssAssetDir;

  /// The current pack — the `.ssab` stem, e.g. `PartsColor`.
  @override
  String get ssPack;

  /// Gate live-reload (default: debug builds launched with the SpriteStudio
  /// live-reload define). `sswatch --run` injects it; otherwise pass
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

  @override
  void initState() {
    super.initState();
    // Join the VM-Service push channel so `sswatch` can hot-swap this player
    // (desktop file push / device embedded-bytes push). Inert with no watcher
    // connected; a release build has no VM Service, so this never fires there.
    SsDevChannel.instance.register(this);
  }

  @override
  void dispose() {
    SsDevChannel.instance.unregister(this);
    super.dispose();
  }
}

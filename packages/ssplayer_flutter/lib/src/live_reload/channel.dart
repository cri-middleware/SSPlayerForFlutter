import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../player.dart';
// The `file` source needs `dart:io` (a host filesystem read); the web has none,
// so it swaps in a stub and pushes bytes only. Keeping `dart:io` out of this
// file is what lets the channel compile for the web (`flutter run -d chrome`).
import 'channel_stub.dart' if (dart.library.io) 'channel_io.dart';
import 'protocol.dart';

/// Whether this build takes live-reload pushes: a debug build launched with
/// [ssLiveReloadDefine]. A `const`, so in a profile or release build every
/// branch it guards is compiled out and the channel ships nowhere.
const bool ssLiveReloadActive =
    kDebugMode && bool.fromEnvironment(ssLiveReloadDefine);

/// A live-reload target the [SsDevChannel] can hot-swap: the current pack of one
/// on-screen [SpriteStudioPlayer], with a say in when to take a push and what
/// to do after one. Implemented by the [SsLiveReload] mixin.
///
/// A player loaded with [SpriteStudioPlayer.loadAsset] needs none of this: it
/// joins the channel by itself. A target is for a player whose bytes did not
/// come from an asset key, or a screen that wants to react to the reload.
///
/// The getters are read at PUSH time, not registration time, so they track the
/// widget's current selection (the pack/dir it is showing right now).
abstract interface class SsLiveReloadTarget {
  /// The player whose resource is hot-swapped.
  SpriteStudioPlayer get ssPlayer;

  /// The current pack's asset dir (a `rootBundle` key prefix, e.g.
  /// `assets/spritestudio/overall`). Used to resolve textures for a byte push.
  String get ssAssetDir;

  /// The current pack — the `.ssab` stem, e.g. `PartsColor`.
  String get ssPack;

  /// Whether live-reload is currently active for this target. A push skips
  /// targets that return false (e.g. the `SS_LIVE_RELOAD` gate is off, or a
  /// drag-dropped source is shown).
  bool get ssLiveReloadEnabled;

  /// Invoked after a successful push-reload (e.g. `setState`).
  void ssOnLiveReloaded();

  /// Invoked when a push-reload throws.
  void ssOnLiveReloadError(Object error);
}

/// The in-app end of the SpriteStudio dev push channel.
///
/// It registers a `dart:developer` service extension — **`ext.ssgen.reload`** —
/// that an external host tool (`dart run ssgen_flutter:sswatch`) calls over the
/// VM Service after it reconverts an edited `SpriteStudio_Source` project. The
/// call carries the fresh pack to the running app, which hot-swaps it via
/// [SpriteStudioPlayer.reload] with the playhead preserved.
///
/// Two kinds of player take a push. Every player that loaded its pack with
/// [SpriteStudioPlayer.loadAsset] — so every [SpriteStudioAnimation] — joins by
/// itself, since the asset key already names the pack and its folder. A
/// [SsLiveReloadTarget] joins by [register], for a player the key cannot
/// describe or a screen that wants to hear about the reload; where one names a
/// player that also joined by itself, the target is the one used.
///
/// This is the transport that replaces "ride Flutter's own hot reload":
///   * it needs **no `r`** — the host tool triggers it directly, and
///   * it works while the app runs under an **IDE debugger** (the tool does not
///     own `flutter run`), on desktop and device alike.
///
/// Debug-only by construction: the VM Service (hence any extension) is absent in
/// release, so registration is skipped there. It DOES register on the web in
/// debug (`flutter run -d chrome`, where DWDS routes the extension call), where
/// a push carries bytes since there is no host filesystem to read a `file` push
/// from. The extension is registered lazily on the first [register] or
/// [registerAsset]; further registrants just join.
///
/// ### `ext.ssgen.reload` protocol (all params are strings)
/// | param    | meaning                                                        |
/// |----------|----------------------------------------------------------------|
/// | `source` | `file` (desktop: read from disk) or `bytes` (device/web: base64). Defaults to `file` when `dir` is present, else `bytes`. |
/// | `dir`    | absolute host output dir (a `file` push reads `<dir>/<pack>.ssab`). |
/// | `pack`   | a specific pack stem (a `bytes` push targets exactly this pack). |
/// | `bytes`  | base64 `.ssab` (a `bytes` push).                               |
///
/// A `file` push reloads every enabled target whose current pack exists in
/// `dir` — so the app reloads exactly what it is showing, and a reconvert that
/// touched other packs is a no-op for it. Result: `{"ok":bool, "reloaded":int,
/// "animations":int?, "errors":[String]?}` — `errors` names each target whose
/// reload threw, so the host can say why a push reloaded nothing.
class SsDevChannel {
  SsDevChannel._();

  /// The process-wide channel.
  static final SsDevChannel instance = SsDevChannel._();

  /// The service-extension method name the host tool calls (shared with
  /// `sswatch` via [ssReloadExtensionMethod] so the two can't drift).
  static const extensionMethod = ssReloadExtensionMethod;

  final _targets = <SsLiveReloadTarget>{};

  /// The players that joined by loading an asset, with the key each loaded.
  final _assets = <SpriteStudioPlayer, String>{};
  bool _extensionRegistered = false;

  /// Registers [target] and, on the first call, wires up [extensionMethod].
  /// Safe to call from `State.initState` — the target's getters are only read
  /// when a push arrives. Debug-only: a no-op in profile/release; on the web it
  /// registers in debug (`flutter run -d chrome`, via DWDS).
  void register(SsLiveReloadTarget target) {
    _targets.add(target);
    _ensureExtension();
  }

  /// Removes [target] (e.g. from `State.dispose`). The extension itself stays
  /// registered — there is no unregister API and it is an inert no-op with no
  /// targets.
  void unregister(SsLiveReloadTarget target) => _targets.remove(target);

  /// Joins [player] as the pack it loaded from [assetKey] — what
  /// [SpriteStudioPlayer.loadAsset] does in a live-reload build. An app does not
  /// call this.
  void registerAsset(SpriteStudioPlayer player, String assetKey) {
    _assets[player] = assetKey;
    _ensureExtension();
  }

  /// Takes [player] back out — on its dispose, or when it loads bytes that no
  /// asset key describes.
  void unregisterAsset(SpriteStudioPlayer player) => _assets.remove(player);

  void _ensureExtension() {
    // Registers in debug on native AND on the web (DWDS routes the call);
    // skipped outside debug (profile/release ship a VM Service too, so gate on
    // kDebugMode, not kReleaseMode) — the push channel must never be reachable in
    // a distributed build.
    if (_extensionRegistered || !kDebugMode) return;
    _extensionRegistered = true;
    try {
      developer.registerExtension(extensionMethod, _onReload);
      developer.registerExtension(ssTargetsExtensionMethod, _onTargets);
    } catch (e) {
      // Already registered by another isolate, or the service is unavailable —
      // harmless for a dev-only channel.
      _extensionRegistered = false;
      debugPrint('[ssplayer] could not register dev extensions: $e');
    }
  }

  /// Everything a push can reach, once per player: the registered targets that
  /// are enabled, then each asset-loaded player no target names. A disabled
  /// target still names its player — it is standing that player down, and the
  /// player's own registration must not reload it behind the target's back.
  List<_Reloadable> _reloadables() {
    final out = <_Reloadable>[];
    final claimed = <SpriteStudioPlayer>{};
    for (final t in _targets) {
      claimed.add(t.ssPlayer);
      if (!t.ssLiveReloadEnabled) continue;
      out.add(_Reloadable(t.ssPlayer, t.ssAssetDir, t.ssPack,
          onReloaded: t.ssOnLiveReloaded, onError: t.ssOnLiveReloadError));
    }
    for (final MapEntry(key: player, value: assetKey) in _assets.entries) {
      if (claimed.contains(player)) continue;
      final slash = assetKey.lastIndexOf('/');
      final file = assetKey.substring(slash + 1);
      out.add(_Reloadable(
        player,
        slash < 0 ? '' : assetKey.substring(0, slash),
        file.endsWith('.ssab') ? file.substring(0, file.length - 5) : file,
      ));
    }
    return out;
  }

  /// `ext.ssgen.targets` — reports each enabled target's current pack so the
  /// host can push a byte blob for exactly what is on screen (device mode).
  Future<developer.ServiceExtensionResponse> _onTargets(
    String method,
    Map<String, String> params,
  ) async {
    final targets = [
      for (final r in _reloadables()) {'assetDir': r.assetDir, 'pack': r.pack},
    ];
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'targets': targets}),
    );
  }

  Future<developer.ServiceExtensionResponse> _onReload(
    String method,
    Map<String, String> params,
  ) async =>
      developer.ServiceExtensionResponse.result(
          jsonEncode(await handleReload(params)));

  /// Applies one `ext.ssgen.reload` call and returns its result, the body of
  /// the service extension.
  @visibleForTesting
  Future<Map<String, Object?>> handleReload(Map<String, String> params) async {
    try {
      final dir = params['dir'];
      final pack = params['pack'];
      final source =
          params['source'] ?? (dir != null && dir.isNotEmpty ? 'file' : 'bytes');

      var reloaded = 0;
      int? animations;
      final errors = <String>[];
      for (final target in _reloadables()) {
        final Uint8List bytes;
        final AssetBundle bundle;
        final String baseDir;
        if (source == 'file') {
          // The web has no host filesystem — a web push always carries bytes.
          if (!supportsFilePush || dir == null || dir.isEmpty) continue;
          // Reload only the pack this target is showing, and only if the
          // just-reconverted dir actually holds it.
          final read = await readSsabFile('$dir/${target.pack}.ssab');
          if (read == null) continue;
          bytes = read;
          bundle = filePushBundle();
          baseDir = dir;
        } else {
          // Byte push (device): match the named pack, resolve textures from the
          // bundle (evict the stale key first, belt-and-braces).
          if (pack != null && pack.isNotEmpty && pack != target.pack) continue;
          final b64 = params['bytes'];
          if (b64 == null || b64.isEmpty) continue;
          bytes = base64Decode(b64);
          bundle = rootBundle;
          baseDir = target.assetDir;
          rootBundle.evict('${target.assetDir}/${target.pack}.ssab');
        }

        try {
          await target.player
              .reload(bytes, bundle: bundle, baseAssetDir: baseDir);
          animations = target.player.animationNames.length;
          target.onReloaded?.call();
          reloaded++;
        } catch (e) {
          errors.add('"${target.pack}": $e');
          target.onError?.call(e);
        }
      }

      return {
        'ok': true,
        'reloaded': reloaded,
        'animations': ?animations,
        if (errors.isNotEmpty) 'errors': errors,
      };
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }
}

/// One player a push can reach, and where its pack lives.
class _Reloadable {
  _Reloadable(this.player, this.assetDir, this.pack,
      {this.onReloaded, this.onError});

  final SpriteStudioPlayer player;
  final String assetDir;
  final String pack;
  final VoidCallback? onReloaded;
  final void Function(Object error)? onError;
}

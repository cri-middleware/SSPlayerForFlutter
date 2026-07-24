import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

// The `file` source needs `dart:io` (a host filesystem read); the web has none,
// so it swaps in a stub and pushes bytes only. Keeping `dart:io` out of this
// file is what lets the channel — and the SsLiveReload mixin — compile for the
// web (`flutter run -d chrome`).
import 'dev_channel_stub.dart' if (dart.library.io) 'dev_channel_io.dart';
import 'ss_defines.dart';

/// A live-reload target the [SsDevChannel] can hot-swap: the current pack of one
/// on-screen [SpriteStudioPlayer]. Implemented by the `SsLiveReload` mixin, but
/// any [State] (or holder) exposing these can register with the channel.
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
/// This is the transport that replaces "ride Flutter's own hot reload":
///   * it needs **no `r`** — the host tool triggers it directly, and
///   * it works while the app runs under an **IDE debugger** (the tool does not
///     own `flutter run`), on desktop and device alike.
///
/// Debug-only by construction: the VM Service (hence any extension) is absent in
/// release, so registration is skipped there. It DOES register on the web in
/// debug (`flutter run -d chrome`, where DWDS routes the extension call), where
/// a push carries bytes since there is no host filesystem to read a `file` push
/// from. The extension is registered lazily on the first [register]; further
/// registrants just join the target set.
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
/// "animations":int?}`.
class SsDevChannel {
  SsDevChannel._();

  /// The process-wide channel.
  static final SsDevChannel instance = SsDevChannel._();

  /// The service-extension method name the host tool calls (shared with
  /// `sswatch` via [ssReloadExtensionMethod] so the two can't drift).
  static const extensionMethod = ssReloadExtensionMethod;

  final _targets = <SsLiveReloadTarget>{};
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
      debugPrint('[ssgen] could not register dev extensions: $e');
    }
  }

  /// `ext.ssgen.targets` — reports each enabled target's current pack so the
  /// host can push a byte blob for exactly what is on screen (device mode).
  Future<developer.ServiceExtensionResponse> _onTargets(
    String method,
    Map<String, String> params,
  ) async {
    final targets = [
      for (final t in _targets)
        if (t.ssLiveReloadEnabled)
          {'assetDir': t.ssAssetDir, 'pack': t.ssPack},
    ];
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'targets': targets}),
    );
  }

  Future<developer.ServiceExtensionResponse> _onReload(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final dir = params['dir'];
      final pack = params['pack'];
      final source =
          params['source'] ?? (dir != null && dir.isNotEmpty ? 'file' : 'bytes');

      var reloaded = 0;
      int? animations;
      for (final target in _targets.toList()) {
        if (!target.ssLiveReloadEnabled) continue;

        final Uint8List bytes;
        final AssetBundle bundle;
        final String baseDir;
        if (source == 'file') {
          // The web has no host filesystem — a web push always carries bytes.
          if (!supportsFilePush || dir == null || dir.isEmpty) continue;
          // Reload only the pack this target is showing, and only if the
          // just-reconverted dir actually holds it.
          final read = await readSsabFile('$dir/${target.ssPack}.ssab');
          if (read == null) continue;
          bytes = read;
          bundle = filePushBundle();
          baseDir = dir;
        } else {
          // Byte push (device): match the named pack, resolve textures from the
          // bundle (evict the stale key first, belt-and-braces).
          if (pack != null && pack.isNotEmpty && pack != target.ssPack) continue;
          final b64 = params['bytes'];
          if (b64 == null || b64.isEmpty) continue;
          bytes = base64Decode(b64);
          bundle = rootBundle;
          baseDir = target.ssAssetDir;
          rootBundle.evict('${target.ssAssetDir}/${target.ssPack}.ssab');
        }

        try {
          await target.ssPlayer
              .reload(bytes, bundle: bundle, baseAssetDir: baseDir);
          animations = target.ssPlayer.getAnimations().length;
          target.ssOnLiveReloaded();
          reloaded++;
        } catch (e) {
          target.ssOnLiveReloadError(e);
        }
      }

      return developer.ServiceExtensionResponse.result(jsonEncode({
        'ok': true,
        'reloaded': reloaded,
        'animations': ?animations,
      }));
    } catch (e) {
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'ok': false, 'error': '$e'}),
      );
    }
  }
}

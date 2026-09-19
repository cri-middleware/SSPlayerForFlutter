import 'dart:typed_data';
import 'dart:ui' as ui;

import 'event.dart';
import 'render/part_override.dart' show PartNameTable;
import 'ssab/ssab.g.dart' as ssab;

/// The UserData / Signal / Audio events crossed on one `advance`, decoded from
/// the pack (design §6C). Returned by [SsAnimeInfo.decodePassedEvents] and
/// dispatched per-event by [SpriteStudioPlayer].
typedef SsPassedEvents = ({
  List<SsUserData> userData,
  List<SsSignal> signals,
  List<SsAudioEvent> audios,
});

/// Read-only metadata about a `.ssab` animation pack, parsed directly from the
/// bytes via the Dart FlatBuffers accessors.
///
/// Useful before/after loading: enumerate the animation names to feed
/// [SpriteStudioPlayer.setAnimation], or list cellmaps to prepare textures.
/// (The Brain returns only computed local attributes; structural metadata like
/// names lives in the `.ssab`, per the porting guide.)
class SsAnimeInfo {
  SsAnimeInfo(Uint8List bytes) : _root = ssab.SsAnimeBinary(bytes);

  final ssab.SsAnimeBinary _root;

  /// The animation-pack name.
  String? get packName => _root.name;

  /// Names of the animations in this pack (feed to `setAnimation`).
  List<String> get animationNames =>
      _root.animations
          ?.map((a) => a.name)
          .whereType<String>()
          .toList(growable: false) ??
      const <String>[];

  /// The authored design-canvas size (SpriteStudio `<canvasSize>`) of animation
  /// [name], in player-local pixels, or null when the animation is unknown or
  /// carries no canvas.
  ui.Size? canvasSize(String name) {
    final c = _animationByName(name)?.canvasSize;
    if (c == null) return null;
    return ui.Size(c.v1, c.v2);
  }

  /// Names of the cellmaps referenced by this pack.
  List<String> get cellmapNames =>
      _root.cellmaps
          ?.map((c) => c.name)
          .whereType<String>()
          .toList(growable: false) ??
      const <String>[];

  /// Names of the cells inside [cellmapName] (empty when the pack has no such
  /// cellmap). Together with [cellmapNames] this is the discovery pair a cell
  /// override needs — both names go to `setPartCellOverride` verbatim, and the
  /// cellmap name carries no `.ssce` extension here either.
  List<String> cellNames(String cellmapName) {
    for (final c in _root.cellmaps ?? const <ssab.CellMap>[]) {
      if (c.name != cellmapName) continue;
      return c.cells
              ?.map((cell) => cell.name)
              .whereType<String>()
              .toList(growable: false) ??
          const <String>[];
    }
    return const <String>[];
  }

  /// The texture-registry key for the cellmap named [cellmapName], or null when
  /// the pack has no such cellmap. This is the cellmap's pre-baked name hash —
  /// equal to `DrawBatch.texture_hash` — so a runtime whole-cellmap texture swap
  /// (`player.textures.register(hash, image)`) targets the same key the loader
  /// registered under, without any Dart-side re-hashing (which would risk
  /// diverging from the Brain's FNV-1a).
  int? cellmapTextureHash(String cellmapName) {
    for (final c in _root.cellmaps ?? const <ssab.CellMap>[]) {
      if (c.name == cellmapName) return c.nameHash;
    }
    return null;
  }

  /// Names of the **external textures** — the texture *file* names (WITH
  /// extension, e.g. `common.png`) a TextureChange (`TCHG`) can bind. The
  /// converter fills this with every name a `TCHG` points at, including each
  /// cellmap's own image, so it is a superset. A distinct hash space from
  /// [cellmapNames] (see [textureHashForName]).
  List<String> get externalTextureNames =>
      _root.externalTextures
          ?.map((t) => t.name)
          .whereType<String>()
          .toList(growable: false) ??
      const <String>[];

  /// Every texture name a runtime replacement can target: [cellmapNames] (no
  /// extension) followed by [externalTextureNames] (with extension). Mirrors
  /// ForGodot's `get_cellmap_names`; all are legitimately replaceable via
  /// [SpriteStudioPlayer.setCellmapTexture].
  List<String> get replaceableTextureNames =>
      <String>[...cellmapNames, ...externalTextureNames];

  /// The [textures] registry key for [name], resolving a cellmap name FIRST
  /// (`common`) then an external-texture file name (`common.png`) — the two hash
  /// spaces `texture_hash` spans — or null when neither has it. Generalises
  /// [cellmapTextureHash] across both spaces (ForGodot's `get_cellmap_hash`); the
  /// pre-baked `name_hash` is returned verbatim (never re-hash on the Dart side).
  int? textureHashForName(String name) {
    for (final c in _root.cellmaps ?? const <ssab.CellMap>[]) {
      if (c.name == name) return c.nameHash;
    }
    for (final t in _root.externalTextures ?? const <ssab.ExternalTexture>[]) {
      if (t.name == name) return t.nameHash;
    }
    return null;
  }

  /// Image paths (for reference-mode textures), one per cellmap.
  List<String> get imagePaths =>
      _root.cellmaps
          ?.map((c) => c.imagePath)
          .whereType<String>()
          .toList(growable: false) ??
      const <String>[];

  // --- Events (§6C) --------------------------------------------------------

  // The passed-event indices the Brain reports are relative to the *current*
  // animation's `events()` list, so resolution is per animation. Cache the last
  // lookup: events are polled every frame that carries one, always for the same
  // animation until it is switched.
  String? _lastAnimName;
  ssab.AnimationData? _lastAnim;

  ssab.AnimationData? _animationByName(String name) {
    if (name == _lastAnimName) return _lastAnim;
    ssab.AnimationData? found;
    final anims = _root.animations;
    if (anims != null) {
      for (final a in anims) {
        if (a.name == name) {
          found = a;
          break;
        }
      }
    }
    _lastAnimName = name;
    _lastAnim = found;
    return found;
  }

  /// Decodes the events at [indices] — the raw indices the Brain reported for
  /// [animationName] (see [SpriteStudioInternalPlayer.passedEventIndices]) — into
  /// flat, per-event lists (design §6C). Unknown animations, out-of-range
  /// indices, and inactive signals are dropped. Returns empty lists when there
  /// is nothing to decode.
  SsPassedEvents decodePassedEvents(String animationName, List<int> indices,
      {PartNameTable partNames = PartNameTable.empty}) {
    if (indices.isEmpty) return _emptyEvents;
    final events = _animationByName(animationName)?.events;
    if (events == null) return _emptyEvents;

    final userData = <SsUserData>[];
    final signals = <SsSignal>[];
    final audios = <SsAudioEvent>[];
    for (final idx in indices) {
      if (idx < 0 || idx >= events.length) continue;
      final frame = events[idx];
      final us = frame.users;
      if (us != null) {
        for (final u in us) {
          userData.add(_decodeUser(u, partNames, frame.frameIndex));
        }
      }
      final sigs = frame.signals;
      if (sigs != null) {
        for (final s in sigs) {
          final decoded = _decodeSignal(s, partNames, frame.frameIndex);
          if (decoded != null) signals.add(decoded);
        }
      }
      final auds = frame.audios;
      if (auds != null) {
        for (final a in auds) {
          final decoded = _decodeAudio(a, partNames, frame.frameIndex);
          if (decoded != null) audios.add(decoded);
        }
      }
    }
    return (userData: userData, signals: signals, audios: audios);
  }

  static const SsPassedEvents _emptyEvents = (
    userData: <SsUserData>[],
    signals: <SsSignal>[],
    audios: <SsAudioEvent>[],
  );

  static SsUserData _decodeUser(
      ssab.EventUserData e, PartNameTable partNames, int frameNo) {
    final v = e.value;
    final r = v?.rect;
    final p = v?.point;
    return SsUserData(
      partIndex: e.partIndex,
      partName: partNames.nameAt(e.partIndex),
      frameNo: frameNo,
      integer: v?.integer?.value,
      rect: r == null ? null : ui.Rect.fromLTRB(r.left, r.top, r.right, r.bottom),
      point: p == null ? null : ui.Offset(p.v1, p.v2),
      string: v?.str,
    );
  }

  static SsSignal? _decodeSignal(
      ssab.EventSignal e, PartNameTable partNames, int frameNo) {
    final v = e.value;
    // Match the sibling players: an inactive signal is not surfaced.
    if (v == null || !v.active) return null;
    final params = <SsSignalParam>[];
    final ps = v.params;
    if (ps != null) {
      for (final p in ps) {
        final id = p.paramId;
        if (id == null) continue;
        params.add(SsSignalParam(paramId: id, value: _paramValue(p)));
      }
    }
    return SsSignal(
      partIndex: e.partIndex,
      partName: partNames.nameAt(e.partIndex),
      frameNo: frameNo,
      commandId: v.commandId ?? '',
      params: params,
    );
  }

  // `SignalCommandParam.value` returns the union entry chosen by `valueType`.
  static Object? _paramValue(ssab.SignalCommandParam p) {
    final val = p.value;
    if (val is ssab.BoolValueEntry) return val.value;
    if (val is ssab.IntValueEntry) return val.value;
    if (val is ssab.FloatValueEntry) return val.value;
    if (val is ssab.StringValueEntry) return val.value;
    return null; // None / unset
  }

  static SsAudioEvent? _decodeAudio(
      ssab.EventAudio e, PartNameTable partNames, int frameNo) {
    final v = e.value;
    if (v == null) return null;
    return SsAudioEvent(
      partIndex: e.partIndex,
      partName: partNames.nameAt(e.partIndex),
      frameNo: frameNo,
      soundName: v.soundName,
      soundNameHash: v.soundNameHash,
      soundListNameHash: v.soundListNameHash,
      loopNum: v.loopNum,
    );
  }

  // --- Sound resolution (§6C audio) ----------------------------------------

  Map<int, String>? _soundFilePaths;

  /// The pack-relative file path for the sound with [soundNameHash] (i.e.
  /// [SsAudioEvent.soundNameHash]) — e.g. `sound/foo.mp3` — resolved from the
  /// pack's `SoundList`s, or null if unknown. Lets an app turn an `onAudio`
  /// trigger into a playable file without re-parsing the `.ssab`; playback
  /// itself remains the app's responsibility (design §6C).
  String? soundFilePath(int soundNameHash) =>
      (_soundFilePaths ??= _buildSoundFilePaths())[soundNameHash];

  Map<int, String> _buildSoundFilePaths() {
    final out = <int, String>{};
    for (final list in _root.soundLists ?? const <ssab.SoundList>[]) {
      for (final f in list.tableData ?? const <ssab.SoundFile>[]) {
        final path = f.filePath;
        if (path != null) out[f.nameHash] = path;
      }
    }
    return out;
  }
}

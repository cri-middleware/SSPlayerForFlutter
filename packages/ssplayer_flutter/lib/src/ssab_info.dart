import 'dart:typed_data';

import 'ssab/ssab.g.dart' as ssab;

/// Read-only metadata about a `.ssab` animation pack, parsed directly from the
/// bytes via the Dart FlatBuffers accessors.
///
/// Useful before/after loading: enumerate the animation names to feed
/// [SpriteStudioPlayer.setupAnimation], or list cellmaps to prepare textures.
/// (The Brain returns only computed local attributes; structural metadata like
/// names lives in the `.ssab`, per the porting guide.)
class SsAnimeInfo {
  SsAnimeInfo(Uint8List bytes) : _root = ssab.SsAnimeBinary(bytes);

  final ssab.SsAnimeBinary _root;

  /// The animation-pack name.
  String? get packName => _root.name;

  /// Names of the animations in this pack (feed to `setupAnimation`).
  List<String> get animationNames =>
      _root.animations
          ?.map((a) => a.name)
          .whereType<String>()
          .toList(growable: false) ??
      const <String>[];

  /// Names of the cellmaps referenced by this pack.
  List<String> get cellmapNames =>
      _root.cellmaps
          ?.map((c) => c.name)
          .whereType<String>()
          .toList(growable: false) ??
      const <String>[];

  /// Image paths (for reference-mode textures), one per cellmap.
  List<String> get imagePaths =>
      _root.cellmaps
          ?.map((c) => c.imagePath)
          .whereType<String>()
          .toList(growable: false) ??
      const <String>[];
}

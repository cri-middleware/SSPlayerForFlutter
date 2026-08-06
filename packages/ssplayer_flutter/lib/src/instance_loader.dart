import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'render/instance.dart';

/// The packs an animation's instance parts (§8) need, plus what went missing.
class InstancePackLoadResult {
  const InstancePackLoadResult(this.packs, this.unresolved);

  /// Pack `name_hash` → that pack's `.ssab` bytes, in the shape
  /// `SpriteStudioInternalPlayer.load` wants for `instancePacks`.
  final Map<int, Uint8List> packs;

  /// Asset paths that could not be fetched. Their instance parts simply never
  /// draw, exactly like a slot the Brain reports invisible.
  final List<String> unresolved;

  bool get isComplete => unresolved.isEmpty;
}

/// Fetches the external `.ssab` packs referenced by an animation's instance
/// parts — the async half of the instance path.
///
/// `SpriteStudioInternalPlayer.load` builds instance children synchronously (a
/// child's Context must exist before the first `ss_instance_slot_step`), so the
/// bytes have to be in hand first. This is the [SsTextureLoader] of the instance
/// world, and resolves the same way: `<baseAssetDir>/<packName>.ssab`, which is
/// the asset-bundle analogue of the flagship's `<parent_dir>/<pack>.ssab`
/// filesystem convention and of what `ssconvert` emits (one `.ssab` per
/// `.ssae`, side by side).
///
/// A same-pack sub-animation — an instance part pointing at another animation in
/// its *own* `.ssab`, the common case — needs nothing from here: the ssab's
/// `external_instances` manifest correctly omits it and the player resolves it
/// against its own bytes.
class SsInstanceLoader {
  /// Walks [rootSsab]'s `external_instances` transitively and fetches each pack.
  ///
  /// [provided] short-circuits the bundle for packs the caller already holds
  /// (keyed by pack name) — the escape hatch for bytes that never lived in an
  /// asset bundle. With no [baseAssetDir] and no [provided] entry a pack is
  /// simply unresolved.
  ///
  /// Each pack is fetched at most once, so a pack graph that loops (A → B → A)
  /// terminates here. Expanding those packs into *players* is a separate matter:
  /// like every sibling player, that recursion is unbounded and a genuinely
  /// cyclic `.ssab` would overflow the stack — `.ssab` is trusted input (the
  /// Brain does not validate it either).
  static Future<InstancePackLoadResult> load(
    Uint8List rootSsab, {
    AssetBundle? bundle,
    String? baseAssetDir,
    Map<String, Uint8List>? provided,
  }) async {
    final packs = <int, Uint8List>{};
    final unresolved = <String>[];
    final bnd = bundle ?? rootBundle;

    // Breadth-first: a fetched pack may reference packs of its own. `seen` is
    // plain dedup — a pack is fetched once however many parts reach it — and it
    // also bounds the walk, since a pack that is already in `packs` never
    // re-enters the frontier.
    final seen = <String>{};
    var frontier = <Uint8List>[rootSsab];
    while (frontier.isNotEmpty) {
      final next = <Uint8List>[];
      for (final bytes in frontier) {
        for (final name in InstancePart.externalPackNames(bytes)) {
          if (!seen.add(name)) continue;

          final direct = provided?[name];
          if (direct != null) {
            packs[InstancePart.packHashOf(direct)] = direct;
            next.add(direct);
            continue;
          }
          if (baseAssetDir == null) {
            unresolved.add('$name.ssab');
            continue;
          }

          final path = _joinAsset(baseAssetDir, '$name.ssab');
          try {
            final data = (await bnd.load(path)).buffer.asUint8List();
            // Key by the pack's OWN name_hash, not a hash of the file name: it
            // is what `PartTypeInstance.ref_anime_pack_hash` is compared against.
            packs[InstancePart.packHashOf(data)] = data;
            next.add(data);
          } catch (_) {
            unresolved.add(path);
          }
        }
      }
      frontier = next;
    }

    return InstancePackLoadResult(packs, unresolved);
  }

  static String _joinAsset(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = path.startsWith('/') ? path.substring(1) : path;
    // A derived base is empty for a root-level `.ssab`; joining must not prepend
    // a leading '/', which would miss the asset key.
    return b.isEmpty ? p : '$b/$p';
  }
}

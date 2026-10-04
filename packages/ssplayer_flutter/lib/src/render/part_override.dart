import 'dart:typed_data';
import 'dart:ui' as ui;

import '../ssab/ssab.g.dart' as ssab;

/// Blend operation of a per-part colour override. The four values are
/// the same set the authored PartColor uses, and [value] is the wire encoding
/// the C-API expects — anything ≥ 4 is *rejected* by the Brain rather than
/// clamped to Mix (unlike the keyframe PartColor path, which clamps
/// defensively).
enum SsBlendOp {
  mix(0),
  mul(1),
  add(2),
  sub(3);

  const SsBlendOp(this.value);

  /// Wire value handed to the Brain.
  final int value;
}

/// Keyframe-vs-override precedence for the two attributes that can conflict
/// with the animation — colour and cell.
///
/// Visibility has no priority mode: a force-hide always wins and is always
/// cleared by `setAnimation` (i.e. it behaves like [holdUntilNextAnimation]).
/// The four corner colours of a gradient override, in one value.
///
/// A record rather than four positional parameters: the colour methods then read
/// the same shape as their single-colour siblings, and the Brain's
/// `left-top, right-top, left-bottom, right-bottom` order is carried by the
/// field names instead of by position, where it could be got silently wrong.
typedef SsCornerColors = ({
  ui.Color leftTop,
  ui.Color rightTop,
  ui.Color leftBottom,
  ui.Color rightBottom,
});

enum SsOverridePriority {
  /// SS6 `NON`: the keyframe takes the attribute back on any frame the
  /// animation drives it, so the override only shows on frames the animation
  /// leaves that attribute alone. Cleared by `setAnimation`.
  overwriteOnNextKeyframe(0),

  /// SS6 `NOW_ANIMATION` (the usual choice): the override wins for the whole of
  /// the current animation, and `setAnimation` clears it.
  holdUntilNextAnimation(1),

  /// SS6 `PERMANENT`: the override wins and survives animation changes. Only
  /// within one `.ssab` — re-validated against the new part count, and binding
  /// another pack clears it.
  permanent(2);

  const SsOverridePriority(this.value);

  /// Wire value handed to the Brain.
  final int value;
}

/// Packs a Flutter [ui.Color] into the `0xRRGGBBAA` the override C-API expects.
///
/// The Brain does all its colour maths in 8-bit sRGB integer space and applies
/// no gamma/linear/PMA conversion, so this is a plain component pack — the same
/// space as the authored PartColor. It also pre-multiplies the part's
/// composed alpha at the seam, so callers must NOT fold `PartState.alpha` in.
int packRgba(ui.Color color) {
  int c(double v) => (v.clamp(0.0, 1.0) * 255.0 + 0.5).toInt();
  return (c(color.r) << 24) | (c(color.g) << 16) | (c(color.b) << 8) | c(color.a);
}

/// Pack-level part query table, read once from the `.ssab` `PartData` list:
/// part names ↔ indices, plus the static per-part skinned-mesh flag.
///
/// Part indices are positional over the pack's parts and stable within one
/// `.ssab`, so a name is resolved once here and the index reused. This
/// mirrors ForGodot and ForUnity, which keep the same map (Godot's
/// `_part_name_to_index`, Unity's `_partNameToIndex`); the Brain's own
/// `find_part_index` covers the same space but only after `setAnimation`.
///
/// Duplicate names keep the FIRST index, matching their insert-if-absent
/// map build — SpriteStudio does not guarantee unique part names.
///
/// The skinned-mesh flag ([isSkinnedMeshAt]) rides along because it is the same
/// kind of read — a static per-part fact off `PartData`, done once at load and
/// immutable for the life of the resource. It backs the part-following hint that
/// a bone-bound mesh part is a poor follow target (its own node transform stays
/// near the setup pose while the vertices are drawn by bone skinning); see
/// [SpriteStudioPlayer.isPartSkinnedMesh].
class PartNameTable {
  const PartNameTable._(this._names, this._byName, this._skinnedMesh);

  /// Empty table: every lookup misses. Used for a pack with no parts.
  static const PartNameTable empty =
      PartNameTable._(<String>[], <String, int>{}, <bool>[]);

  final List<String> _names;
  final Map<String, int> _byName;
  final List<bool> _skinnedMesh;

  /// Part names in part-index order. A part with no name in the pack reads as
  /// the empty string so the list stays index-aligned.
  List<String> get names => _names;

  /// Number of parts in the pack.
  int get length => _names.length;

  /// The index of [name], or -1 when the pack has no such part.
  int indexOf(String name) => _byName[name] ?? -1;

  /// The name at [index], or null when out of range.
  String? nameAt(int index) =>
      (index >= 0 && index < _names.length) ? _names[index] : null;

  /// Whether the part at [index] is a **bone-bound (skinned) mesh** — its
  /// `mesh_binding` exists and binds at least one influence bone (`ssab.fbs`
  /// `PartMeshBinding.influence_bone`). False out of range, for a rigid
  /// (deform-only) mesh, and for every non-mesh part.
  ///
  /// The judgment matches every official player (shared `.ssab`, same field):
  /// `is_part_skinned_mesh(part) := mesh_binding present && influence_bone > 0`.
  /// A rigid mesh reads false because its node transform *does* place the drawn
  /// vertices, so it follows correctly; only a skinned mesh diverges.
  bool isSkinnedMeshAt(int index) =>
      (index >= 0 && index < _skinnedMesh.length) && _skinnedMesh[index];

  /// Reads the table out of the `.ssab` `PartData` list (part-index ordered),
  /// the same static block [MaskPartFlags.readAll] walks. Cheap enough to do
  /// once at load; the result is immutable for the life of the resource.
  static PartNameTable readAll(Uint8List ssabBytes) {
    final parts = ssab.SsAnimeBinary(ssabBytes).parts;
    if (parts == null || parts.isEmpty) return empty;
    final names = List<String>.generate(
        parts.length, (i) => parts[i].name ?? '',
        growable: false);
    final skinnedMesh = List<bool>.generate(
        parts.length, (i) {
          final binding = parts[i].meshBinding;
          return binding != null && (binding.influenceBone?.length ?? 0) > 0;
        },
        growable: false);
    final byName = <String, int>{};
    for (var i = 0; i < names.length; i++) {
      final n = names[i];
      if (n.isEmpty) continue;
      byName.putIfAbsent(n, () => i);
    }
    return PartNameTable._(names, byName, skinnedMesh);
  }
}

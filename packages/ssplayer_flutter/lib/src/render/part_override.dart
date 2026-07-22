import 'dart:typed_data';
import 'dart:ui' as ui;

import '../ssab/ssab.g.dart' as ssab;

/// Blend operation of a per-part colour override (§65-3-1). The four values are
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
/// with the animation — colour and cell (§65-1-3).
///
/// Visibility has no priority mode: a force-hide always wins and is always
/// cleared by `setupAnimation` (i.e. it behaves like [holdUntilNextAnimation]).
enum SsOverridePriority {
  /// SS6 `NON`: the keyframe takes the attribute back on any frame the
  /// animation drives it, so the override only shows on frames the animation
  /// leaves that attribute alone. Cleared by `setupAnimation`.
  overwriteOnNextKeyframe(0),

  /// SS6 `NOW_ANIMATION` (the usual choice): the override wins for the whole of
  /// the current animation, and `setupAnimation` clears it.
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
/// space as the authored PartColor (§65-3-1). It also pre-multiplies the part's
/// composed alpha at the seam, so callers must NOT fold `PartState.alpha` in.
int packRgba(ui.Color color) {
  int c(double v) => (v.clamp(0.0, 1.0) * 255.0 + 0.5).toInt();
  return (c(color.r) << 24) | (c(color.g) << 16) | (c(color.b) << 8) | c(color.a);
}

/// Pack-level part names, read once from the `.ssab` `PartData` list.
///
/// Part indices are positional over the pack's parts and stable within one
/// `.ssab` (§65-4), so a name is resolved once here and the index reused. This
/// mirrors the flagship players, which keep the same map (Godot's
/// `_part_name_to_index`, Unity's `_partNameToIndex`); the Brain's own
/// `find_part_index` covers the same space but only after `setupAnimation`.
///
/// Duplicate names keep the FIRST index, matching the flagships' insert-if-absent
/// map build — SS7 does not guarantee unique part names.
class PartNameTable {
  const PartNameTable._(this._names, this._byName);

  /// Empty table: every lookup misses. Used for a pack with no parts.
  static const PartNameTable empty =
      PartNameTable._(<String>[], <String, int>{});

  final List<String> _names;
  final Map<String, int> _byName;

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

  /// Reads the table out of the `.ssab` `PartData` list (part-index ordered),
  /// the same static block [MaskPartFlags.readAll] walks. Cheap enough to do
  /// once at load; the result is immutable for the life of the resource.
  static PartNameTable readAll(Uint8List ssabBytes) {
    final parts = ssab.SsAnimeBinary(ssabBytes).parts;
    if (parts == null || parts.isEmpty) return empty;
    final names = List<String>.generate(
        parts.length, (i) => parts[i].name ?? '',
        growable: false);
    final byName = <String, int>{};
    for (var i = 0; i < names.length; i++) {
      final n = names[i];
      if (n.isEmpty) continue;
      byName.putIfAbsent(n, () => i);
    }
    return PartNameTable._(names, byName);
  }
}

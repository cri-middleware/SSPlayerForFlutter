import 'dart:typed_data';

import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/framedata.dart' as fbs;
import 'package:ssruntime_dart/ssruntime_dart.dart';

import '../ssab/ssab.g.dart' as ssab;

/// A part that hosts a particle effect, as declared in the static `.ssab`.
///
/// Read once at load ([readAll]) — the effect binding never changes per frame.
class EffectPart {
  const EffectPart({required this.partIndex, required this.effectNameHash});

  /// The effect part's index. It doubles as the **slot index** for
  /// `ss_runtime_get_active_effect_event`, because the ssab keys `EventEffect`
  /// by `part_index`.
  final int partIndex;

  /// `PartTypeEffect.ref_effect_name_hash` — the effect to instantiate in
  /// `ss_effect_slot_create`.
  final int effectNameHash;

  /// Every effect-hosting part in the pack, in part-index order (empty when the
  /// animation has no effects, which disables the whole effect path).
  static List<EffectPart> readAll(Uint8List ssabBytes) {
    final parts = ssab.SsAnimeBinary(ssabBytes).parts;
    if (parts == null || parts.isEmpty) return const <EffectPart>[];
    final out = <EffectPart>[];
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      if (p.partTypeType != ssab.PartTypeTypeId.PartTypeEffect) continue;
      final type = p.partType;
      if (type is! ssab.PartTypeEffect) continue;
      out.add(EffectPart(partIndex: i, effectNameHash: type.refEffectNameHash));
    }
    return List<EffectPart>.unmodifiable(out);
  }
}

/// An effect plan's vertex, UV, colour and index vectors as typed views over
/// the plan's own bytes, made once per plan by [EffectSlots.step]. Like the
/// plan, they alias the slot's builder and hold until the slot steps again.
class EffectPlanArrays {
  EffectPlanArrays._(this.verts, this.uvs, this.colors, this.indices);

  final Float32List verts;
  final Float32List uvs;
  final Float32List colors;
  final Int32List indices;

  static final Expando<EffectPlanArrays> _byPlan = Expando<EffectPlanArrays>();

  /// The views [EffectSlots.step] made for [plan]; null for a plan it did not
  /// step, or whose vectors do not sit on a 4-byte boundary.
  static EffectPlanArrays? of(efbs.EffectDrawPlan plan) => _byPlan[plan];

  // Null while each plan is still read both ways, until one holding all four
  // vectors reads the same through the generated accessors; false once one
  // does not, for good.
  static bool? _matchesAccessors;
  static int _length = 0;

  static void _attach(efbs.EffectDrawPlan plan, Uint8List bytes) {
    if (_matchesAccessors == false) return;
    final data = ByteData.sublistView(bytes);
    final verts = _floats(bytes, data, _vertsSlot);
    final uvs = _floats(bytes, data, _uvsSlot);
    final colors = _floats(bytes, data, _colorsSlot);
    final indices = _ints(bytes, data, _indicesSlot);
    if (verts == null || uvs == null || colors == null || indices == null) {
      return;
    }
    if (_matchesAccessors == null) {
      if (!_same(verts, plan.verts) ||
          !_same(uvs, plan.uvs) ||
          !_same(colors, plan.colors) ||
          !_same(indices, plan.indices)) {
        _matchesAccessors = false;
        return;
      }
      if (verts.isNotEmpty &&
          uvs.isNotEmpty &&
          colors.isNotEmpty &&
          indices.isNotEmpty) {
        _matchesAccessors = true;
      }
    }
    _byPlan[plan] = EffectPlanArrays._(verts, uvs, colors, indices);
  }

  // EffectDrawPlan's vtable slots, as in effect_draw_plan.g.dart.
  static const int _vertsSlot = 8, _uvsSlot = 10, _colorsSlot = 12;
  static const int _indicesSlot = 14;

  // Where the root table's vector at vtable [slot] starts, its element count
  // left in [_length]; -1 when it is absent or runs past the buffer.
  static int _vector(ByteData data, int slot) {
    final size = data.lengthInBytes;
    if (size < 4) return -1;
    final table = data.getUint32(0, Endian.little);
    if (table + 4 > size) return -1;
    final vtable = table - data.getInt32(table, Endian.little);
    if (vtable < 0 || vtable + 4 > size) return -1;
    if (slot + 2 > data.getUint16(vtable, Endian.little)) return -1;
    final field = data.getUint16(vtable + slot, Endian.little);
    if (field == 0) return -1;
    final at = table + field;
    if (at + 4 > size) return -1;
    final vector = at + data.getUint32(at, Endian.little);
    if (vector + 4 > size) return -1;
    _length = data.getUint32(vector, Endian.little);
    if (vector + 4 + _length * 4 > size) return -1;
    return vector + 4;
  }

  static Float32List? _floats(Uint8List bytes, ByteData data, int slot) {
    final start = _vector(data, slot);
    if (start < 0) return null;
    final offset = bytes.offsetInBytes + start;
    return offset % 4 == 0 ? bytes.buffer.asFloat32List(offset, _length) : null;
  }

  static Int32List? _ints(Uint8List bytes, ByteData data, int slot) {
    final start = _vector(data, slot);
    if (start < 0) return null;
    final offset = bytes.offsetInBytes + start;
    return offset % 4 == 0 ? bytes.buffer.asInt32List(offset, _length) : null;
  }

  static bool _same(List<num> view, List<num>? generated) {
    if (generated == null || generated.length != view.length) return false;
    for (var i = 0; i < view.length; i++) {
      if (view[i] != generated[i]) return false;
    }
    return true;
  }
}

/// Owns one `EffectSlot` per effect part and their per-frame draw plans.
///
/// Effects are the only kind whose geometry does **not** come from the Brain's
/// per-frame SoA: each slot simulates independently and returns its own
/// `EffectDrawPlan` FlatBuffer from [step]. Stepping needs a delta time, so it
/// happens in the player's `update` (not `paint`); the returned plan stays valid
/// until the same slot is stepped again, which is exactly the update→paint gap.
///
/// The slots borrow the owning player's `resource`, which must outlive them —
/// [dispose] runs before the resource is destroyed.
class EffectSlots {
  EffectSlots(this._resource, this.parts);

  final SsResource _resource;

  /// Every effect-hosting part in the pack ([EffectPart.readAll]).
  final List<EffectPart> parts;

  final Map<int, SsEffectSlot?> _slots = <int, SsEffectSlot?>{};
  final Map<int, efbs.EffectDrawPlan> _plans = <int, efbs.EffectDrawPlan>{};

  /// True when the pack hosts no effects at all — the caller then skips the
  /// whole effect path.
  bool get isEmpty => parts.isEmpty;

  /// Whether any slot runs on its own clock, going by the last key each one saw.
  bool get anyIndependent => _slots.values.any(
      (slot) => slot != null && ssRuntime.effectSlotIsIndependent(slot));

  /// The plan for [partIndex] as of the last [step], or null when that slot was
  /// invisible (dead, not yet started, or out of its lifetime) or its part
  /// hidden.
  efbs.EffectDrawPlan? planFor(int partIndex) => _plans[partIndex];

  /// Advances every slot one frame.
  ///
  /// [parentFrame] must stay a **raw float** — rounding it would freeze slow
  /// effects (the SDK calls this out explicitly). [deltaSeconds] and [fps] only
  /// matter for `independent` slots, which run on their own clock and ignore
  /// [parentFrame]; synced slots are the reverse. [parentLooped] is the parent's
  /// loop **edge** for this update (`ss_runtime_just_looped` is reset at the top of
  /// each update), which re-arms a synced effect so it re-fires next cycle.
  ///
  /// [frame] is the `FrameData` at [parentFrame], which says which effect parts
  /// `paint` will draw. A hidden one is still stepped, or an independent effect
  /// would freeze while hidden, but builds no particles; shown again, it draws
  /// what it would have had it never been hidden. With null, every slot steps
  /// as drawn.
  void step(
    SsContext context, {
    required double parentFrame,
    required double deltaSeconds,
    required double fps,
    required bool parentLooped,
    required fbs.FrameData? frame,
  }) {
    final states = frame?.parts;
    for (final part in parts) {
      final slot = _slotFor(part);
      if (slot == null) continue;

      final result = ssRuntime.stepEffectSlot(
        slot,
        context,
        part.partIndex,
        parentFrame: parentFrame,
        deltaSeconds: deltaSeconds,
        fps: fps,
        parentLooped: parentLooped,
        yFlip: true, // Flutter is Y-Down; the Brain mirrors the particles once
        vertStride: 2, // (x, y) pairs — read plan.vertStride back to be sure
        draw: _drawn(states, part.partIndex),
      );

      final plan = result.drawPlan;
      if (plan != null) {
        // Zero-copy view over the slot's builder; invalid once this slot steps
        // again, so it is only read during the paint that follows this update.
        final view = efbs.EffectDrawPlan(plan);
        EffectPlanArrays._attach(view, plan);
        _plans[part.partIndex] = view;
      } else {
        _plans.remove(part.partIndex);
      }
    }
  }

  /// Rewinds every slot's "last started key" memory (`ss_effect_slot_reset`).
  ///
  /// Must run on an explicit head-out — `play()` or a new `setAnimation` —
  /// or the debounce swallows the first key and a replayed animation never
  /// re-fires its effect. Emitter caches and the resource binding survive.
  void reset() {
    for (final slot in _slots.values) {
      if (slot != null) ssRuntime.resetEffectSlot(slot);
    }
    _plans.clear();
  }

  // Whether effect part [partIndex] is in the frame's draw order, which leaves
  // out exactly the hidden ones. `parts` comes in part-index order; a part not
  // found where its index says steps as drawn, which costs only particles
  // nobody draws.
  static bool _drawn(List<fbs.PartState>? states, int partIndex) {
    if (states == null || partIndex >= states.length) return true;
    final state = states[partIndex];
    return state.partIndex != partIndex || !state.$hide;
  }

  SsEffectSlot? _slotFor(EffectPart part) =>
      _slots.putIfAbsent(part.partIndex, () {
        // Seed = part_index ^ effect_name_hash, ForGodot's exact formula:
        // deterministic (no clock, no RNG) yet different per part, so two parts
        // playing the SAME effect don't emit in visual lockstep. The runtime
        // overrides it entirely for effects authored with `is_lock_rand_seed`.
        final seed = (part.partIndex ^ part.effectNameHash) & 0xFFFFFFFF;
        // A null return (bad effect data) is cached too — do not retry per frame.
        return ssRuntime.createEffectSlot(_resource, part.effectNameHash, seed);
      });

  void dispose() {
    for (final slot in _slots.values) {
      if (slot != null) ssRuntime.destroyEffectSlot(slot);
    }
    _slots.clear();
    _plans.clear();
  }
}

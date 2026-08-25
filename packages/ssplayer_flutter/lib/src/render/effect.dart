import 'dart:typed_data';

import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/ssruntime_dart.dart';

import '../ssab/ssab.g.dart' as ssab;

/// A part that hosts a particle effect (§8), as declared in the static `.ssab`.
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

/// Owns one `EffectSlot` per effect part (§8) and their per-frame draw plans.
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

  /// The plan for [partIndex] as of the last [step], or null when that slot was
  /// invisible (dead, not yet started, or out of its lifetime).
  efbs.EffectDrawPlan? planFor(int partIndex) => _plans[partIndex];

  /// Advances every slot one frame.
  ///
  /// [parentFrame] must stay a **raw float** — rounding it would freeze slow
  /// effects (the SDK calls this out explicitly). [deltaSeconds] and [fps] only
  /// matter for `independent` slots, which run on their own clock and ignore
  /// [parentFrame]; synced slots are the reverse. [parentLooped] is the parent's
  /// loop **edge** for this update (`ss_runtime_is_looped` is reset at the top of
  /// each update), which re-arms a synced effect so it re-fires next cycle.
  void step(
    SsContext context, {
    required double parentFrame,
    required double deltaSeconds,
    required double fps,
    required bool parentLooped,
  }) {
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
      );

      final plan = result.drawPlan;
      if (plan != null) {
        // Zero-copy view over the slot's builder; invalid once this slot steps
        // again, so it is only read during the paint that follows this update.
        _plans[part.partIndex] = efbs.EffectDrawPlan(plan);
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

  SsEffectSlot? _slotFor(EffectPart part) =>
      _slots.putIfAbsent(part.partIndex, () {
        // Seed = part_index ^ effect_name_hash, the flagship's exact formula:
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

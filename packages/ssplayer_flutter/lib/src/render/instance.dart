import 'dart:typed_data';

import 'package:ssruntime_dart/ssruntime_dart.dart';

import '../ssab/ssab.g.dart' as ssab;

/// A part that plays another animation in-place, as declared in the static
/// `.ssab`.
///
/// Read once at load ([readAll]) — the binding never changes per frame. The
/// *playback* parameters (start/end labels, loop count, speed, reverse,
/// pingpong, independent) are deliberately absent: they live on the animation's
/// `EventInstance` keys and are consumed **inside the Brain** by
/// `ss_instance_slot_step`. The Body must never read or interpret them.
class InstancePart {
  const InstancePart({
    required this.partIndex,
    required this.packName,
    required this.packNameHash,
    required this.animeName,
    required this.animeNameHash,
  });

  /// The instance part's index. It doubles as the **slot index** for
  /// `ss_runtime_get_active_event_instance`, because the ssab keys
  /// `EventInstance` by `part_index` (the flagship passes `p_idx` straight in).
  final int partIndex;

  /// `PartTypeInstance.ref_anime_pack` — the pack holding the child animation.
  /// May name this player's own pack (a same-file sub-animation, the common
  /// case) or an external sibling listed in `external_instances`.
  final String packName;
  final int packNameHash;

  /// `PartTypeInstance.ref_anime_name` — the animation to select on the child.
  final String animeName;
  final int animeNameHash;

  /// Every instance-hosting part in the pack, in part-index order (empty when
  /// the animation has none, which disables the whole instance path).
  static List<InstancePart> readAll(Uint8List ssabBytes) {
    final parts = ssab.SsAnimeBinary(ssabBytes).parts;
    if (parts == null || parts.isEmpty) return const <InstancePart>[];
    final out = <InstancePart>[];
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      if (p.partTypeType != ssab.PartTypeTypeId.PartTypeInstance) continue;
      final type = p.partType;
      if (type is! ssab.PartTypeInstance) continue;
      final pack = type.refAnimePack;
      final anime = type.refAnimeName;
      // A binding with no target is authored garbage; skip it rather than
      // spawning a child that can never resolve.
      if (pack == null || anime == null) continue;
      out.add(InstancePart(
        partIndex: i,
        packName: pack,
        packNameHash: type.refAnimePackHash,
        animeName: anime,
        animeNameHash: type.refAnimeNameHash,
      ));
    }
    return List<InstancePart>.unmodifiable(out);
  }

  /// This pack's own `SsAnimeBinary.name_hash` — the identity [resolvePack]
  /// compares a reference against to spot a same-file sub-animation, and the key
  /// a host files the pack under in `instancePacks`.
  static int packHashOf(Uint8List ssabBytes) =>
      ssab.SsAnimeBinary(ssabBytes).nameHash;

  /// The pack names this `.ssab` reaches through `external_instances` — the set
  /// a host must fetch before [readAll]'s parts can be bound.
  ///
  /// This is the ssab's own manifest, not a scan of the parts: the converter
  /// emits one entry per referenced *external* pack, so a same-file
  /// sub-animation is (correctly) absent.
  static List<String> externalPackNames(Uint8List ssabBytes) {
    final ext = ssab.SsAnimeBinary(ssabBytes).externalInstances;
    if (ext == null || ext.isEmpty) return const <String>[];
    final seen = <String>{};
    for (final e in ext) {
      final name = e.animePackName;
      if (name != null && name.isNotEmpty) seen.add(name);
    }
    return List<String>.unmodifiable(seen);
  }

  /// Resolves the `.ssab` bytes holding this part's child animation (ports the
  /// flagship `_resolve_ssab_by_hash`).
  ///
  /// External packs win over the own pack, then the own binary is the fallback
  /// — matching the flagship's order. [ownPackHash] is the parent's
  /// `SsAnimeBinary.name_hash`; a `packNameHash` of 0 means the author left the
  /// reference pack-less, which also resolves to the own binary.
  static Uint8List? resolvePack(
    InstancePart part, {
    required Uint8List ownBytes,
    required int ownPackHash,
    Map<int, Uint8List>? packs,
  }) {
    final external = packs?[part.packNameHash];
    if (external != null) return external;
    if (part.packNameHash == 0 || part.packNameHash == ownPackHash) {
      return ownBytes;
    }
    return null;
  }
}

/// The child-player surface [InstanceSlots] drives.
///
/// Implemented by `SpriteStudioInternalPlayer`. It exists so this file does not
/// import the player back (the slot logic sits *below* L2, like every other
/// `render/` helper) and so the slot lifecycle can be exercised against a fake
/// child in tests.
abstract class InstanceChild {
  /// The child's runtime Context. `ss_instance_slot_step` steps **this**, while
  /// the `EventInstance` is resolved against the *parent's* context.
  SsContext get instanceContext;

  /// Starts the child from its (just-configured) start frame — what the Brain
  /// requires on a transition edge.
  ///
  /// `ss_instance_slot_step` configures the child's section, direction and loop
  /// count — which already puts it on its first frame — but deliberately does
  /// **not** start it. Skip this and an independent child never plays at all:
  /// its per-tick `Context::update` silently no-ops on a stopped controller,
  /// freezing the child forever.
  void instancePlay();

  /// Re-arms the child's own slot debounces (recursively), without touching its
  /// playback — the head-out half of [instancePlay].
  void instanceResetSlots();

  /// Drives the child's own per-frame slots (its effects and nested instances)
  /// at the frame the Brain just stepped it to. The child's *animation* clock is
  /// owned by `ss_instance_slot_step`, so this must NOT call `ss_runtime_update`.
  void instanceStepSlots(double childFrame, double deltaMs, bool childLooped);

  /// Stops the child's own clock. Called once at setup: a child must not
  /// self-advance before its `EventInstance` ever fires.
  void instanceStop();

  void instanceDispose();
}

/// One instance part's live state: its Brain-side slot and the child player it
/// drives.
class InstanceSlot<T extends InstanceChild> {
  InstanceSlot({required this.slot, required this.child});

  /// The opaque `InstanceSlot` from `ss_instance_slot_create()`. Unlike an
  /// effect slot it binds no resource at construction — `step` takes the child
  /// context per call.
  final SsInstanceSlot slot;
  final T child;

  /// The frame the last [InstanceSlots.step] left the child on — what `paint`
  /// draws (rounded there).
  double childFrame = 0.0;

  /// Whether the Brain says this child is live this frame. Invisible is the
  /// fail-safe: every path that does not explicitly draw leaves it hidden.
  bool visible = false;

  /// Whether the Brain is running this child on its own real-time clock rather
  /// than the parent's frame.
  ///
  /// Only meaningful once the slot has seen its `EventInstance` (i.e. after the
  /// first [InstanceSlots.step] that reaches the key). The Body does not need
  /// this to *drive* the slot — we hand every slot a delta every tick regardless
  /// — it is a query, and it is how the flagship decides whether it may skip
  /// ticks at all.
  ///
  /// Known SDK limitation: independent playback is undefined under reverse
  /// playback and seek (a monotonic real-time clock cannot rewind).
  bool get isIndependent => ssRuntime.instanceSlotIsIndependent(slot);
}

/// Owns one `InstanceSlot` + child player per instance part.
///
/// The division of labour is unusually lopsided and worth stating: **every**
/// playback attribute — start/end labels, loop count, speed, reverse, pingpong,
/// independent — is resolved inside `ss_instance_slot_step`. The Body's whole
/// job is to hand it a child Context and then draw the child at the frame it
/// reports. We never read `PartAttributeInstance`, and never branch on
/// `ev.is_synthetic_default` (the SDK calls that out explicitly).
///
/// Slots are stepped from the player's `update` (where the delta is), never from
/// `paint` — the same rule as [EffectSlots].
class InstanceSlots<T extends InstanceChild> {
  InstanceSlots(this.parts, this._slots);

  /// Builds the slots, spawning one child per instance part via [childFor].
  ///
  /// [childFor] returns null when the part's pack cannot be resolved (a missing
  /// external `.ssab`); that part is then simply never drawn, which is the same
  /// fail-safe as an invisible slot.
  factory InstanceSlots.build(
    List<InstancePart> parts,
    T? Function(InstancePart part) childFor,
  ) {
    final slots = <int, InstanceSlot<T>>{};
    for (final part in parts) {
      final child = childFor(part);
      if (child == null) continue;
      final slot = ssRuntime.createInstanceSlot();
      if (slot == null) {
        child.instanceDispose();
        continue;
      }
      slots[part.partIndex] = InstanceSlot<T>(slot: slot, child: child);
    }
    return InstanceSlots<T>(parts, slots);
  }

  /// Every instance-hosting part in the pack ([InstancePart.readAll]).
  final List<InstancePart> parts;

  final Map<int, InstanceSlot<T>> _slots;

  /// True when the pack hosts no instances at all — the caller then skips the
  /// whole instance path.
  bool get isEmpty => _slots.isEmpty;

  /// The live slot for [partIndex], or null when that part has no child.
  InstanceSlot<T>? slotFor(int partIndex) => _slots[partIndex];

  /// Every live slot, in no particular order.
  Iterable<InstanceSlot<T>> get slots => _slots.values;

  /// Advances every slot one tick.
  ///
  /// [parentContext] is the **parent's** context — the `EventInstance` is
  /// resolved against it, while `step` receives the *child's*. [parentLooped] is
  /// the parent's loop **edge** for this update; without it a loop boundary is
  /// invisible to the Brain (the `EventInstance` identity is unchanged) and a
  /// finite-loop independent child freezes at its end frame.
  void step(
    SsContext parentContext, {
    required double parentFrame,
    required double deltaMs,
    required bool parentLooped,
  }) {
    final deltaSeconds = deltaMs / 1000.0;
    for (final entry in _slots.entries) {
      final state = entry.value;
      // Slot index == part index: the ssab keys EventInstance by part_index. The
      // backend fetches the active EventInstance against the parent context and
      // steps the child in one call ([SsRuntime.stepInstanceSlot]).
      final r = ssRuntime.stepInstanceSlot(
        state.slot,
        parentContext,
        entry.key,
        state.child.instanceContext,
        parentFrame: parentFrame,
        deltaSeconds: deltaSeconds,
        parentLooped: parentLooped,
      );

      // A transition means a new EventInstance edge. `step` has configured the
      // child's section/direction/loop but left it stopped, so starting it is
      // the host's job and is NOT optional — see [InstanceChild.instancePlay].
      if (r.transitioned) {
        state.child.instancePlay();
        // play() snaps the clock to the section start. An independent child was
        // already there; a synced one was at its parent-relative frame, and goes
        // back to it so the child's clock and the frame drawn below agree.
        if (!state.isIndependent) {
          ssRuntime.seek(state.child.instanceContext, r.childFrameNo);
        }
      }

      state.visible = r.visible;
      if (!r.visible) continue;

      // The step's frame, the transition tick included — the frame the child's
      // clock was just put back on above.
      final childFrame = r.childFrameNo;
      state.childFrame = childFrame;
      // The child's animation clock is the Brain's; its effects and nested
      // instances still need their own tick, at the frame it was just moved to.
      state.child.instanceStepSlots(childFrame, deltaMs, r.childLooped);
    }
  }

  /// Rewinds every slot's "last started key" memory and its child's clock.
  ///
  /// Must run on an explicit head-out — `play()` or a new `setAnimation` — or
  /// the debounce swallows the first key and a replayed animation never
  /// re-fires its instance. Recurses into children, like the flagship's
  /// `_reset_slots_playback_state`.
  ///
  /// This re-arms *memory* only. The child is stopped rather than replayed: the
  /// next `step` will see the re-armed slot, report a transition, and start it
  /// from the right place.
  void reset() {
    for (final state in _slots.values) {
      ssRuntime.resetInstanceSlot(state.slot);
      state.childFrame = 0.0;
      state.visible = false;
      state.child.instanceStop();
      state.child.instanceResetSlots();
    }
  }

  void dispose() {
    for (final state in _slots.values) {
      // The child borrows nothing from the slot, but mirror the flagship's
      // order anyway: player first, then the slot that drove it.
      state.child.instanceDispose();
      ssRuntime.destroyInstanceSlot(state.slot);
    }
    _slots.clear();
  }
}

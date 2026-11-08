import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:ssruntime_dart/ssruntime_dart.dart';

import 'render/effect.dart';
import 'render/instance.dart';
import 'render/mask.dart';
import 'render/part_override.dart';
import 'ssab/ssab.g.dart' as asset;

/// One `.ssab` as every player reading it shares it: the runtime's parse of it,
/// and the static tables this layer reads out of it once.
///
/// The runtime only reads a resource, and any number of contexts may bind one,
/// yet most of what a player costs lives there — the decoded keys, and every
/// played animation's part caches and setup poses, built the first time a
/// context sets that animation up. So players handed the same bytes, a pack
/// drawn several times or an instance child playing from its parent's own pack,
/// bind one pack instead of each parsing their own.
///
/// Packs are matched on their bytes, and the pack reads the first holder's
/// buffer for as long as it is open, so bytes handed to a load must not change
/// afterwards. Different bytes, a live reload's included, get a pack of their
/// own; a player bound to the old one keeps it until it lets go.
final class SsabPack {
  SsabPack._(
    this.bytes,
    this.resource,
    this.maskFlags,
    this.partNames,
    this.effectParts,
    this.instanceParts,
    this.packHash,
  ) {
    // Backstop for holders dropped without [close]: once none of them can
    // reach this pack, the runtime's parse goes with it. The table below
    // holds packs weakly so as not to keep one alive by itself.
    ssRuntime.registerForGc(this, resource: resource);
  }

  /// Open packs by byte length, the cheap test before comparing bytes.
  static final Map<int, List<WeakReference<SsabPack>>> _open =
      <int, List<WeakReference<SsabPack>>>{};

  /// The bytes the pack was parsed from: the first holder's buffer.
  final Uint8List bytes;

  /// The runtime's parse, bound by every holder's context.
  final SsResource resource;

  final List<MaskPartFlags> maskFlags;
  final PartNameTable partNames;
  final List<EffectPart> effectParts;
  final List<InstancePart> instanceParts;

  /// This pack's own `SsAnimeBinary.name_hash` ([InstancePart.packHashOf]).
  final int packHash;

  int _holders = 0;

  /// Takes a hold on the pack for [ssab], parsing it if no open pack has the
  /// same bytes. Every [open] needs one [close].
  ///
  /// Throws when the bytes are not a `.ssab` the runtime reads.
  static SsabPack open(Uint8List ssab) {
    final candidates = _open[ssab.length];
    if (candidates != null) {
      for (var i = candidates.length - 1; i >= 0; i--) {
        final pack = candidates[i].target;
        if (pack == null) {
          candidates.removeAt(i);
        } else if (_sameBytes(pack.bytes, ssab)) {
          pack._holders++;
          return pack;
        }
      }
    }

    // The Dart-side tables first: they are bounds-checked FlatBuffers reads
    // that throw on a corrupt pack, so a malformed one fails here, before the
    // runtime allocates anything.
    final maskFlags = MaskPartFlags.readAll(ssab);
    final partNames = PartNameTable.readAll(ssab);
    final effectParts = EffectPart.readAll(ssab);
    final instanceParts = InstancePart.readAll(ssab);
    final packHash = InstancePart.packHashOf(ssab);

    // Copy mode: the runtime keeps its own copy of the bytes. It is the only
    // mode on the web, where its memory is not this isolate's. Rejects a
    // non-`.ssab` header.
    final resource = ssRuntime.createResourceCopy(ssab);
    if (resource == null) {
      final reads = ssRuntime.ssabSchemaVersion;
      final version = asset.SsAnimeBinary(ssab).version;
      throw StateError(reads != null && version != reads
          ? 'This .ssab has schema version $version and this runtime reads '
              'version $reads: the converter and the player are from '
              'different releases.'
          : 'The runtime could not read this .ssab.');
    }
    final pack = SsabPack._(ssab, resource, maskFlags, partNames, effectParts,
        instanceParts, packHash)
      .._holders = 1;
    (_open[ssab.length] ??= <WeakReference<SsabPack>>[])
        .add(WeakReference<SsabPack>(pack));
    return pack;
  }

  /// Lets go of one [open]. The last one frees the runtime's parse, so close
  /// only once nothing of the holder's still borrows [resource] — its effect
  /// slots, for one.
  void close() {
    assert(_holders > 0, 'SsabPack closed more often than it was opened');
    if (--_holders > 0) return;
    _open[bytes.length]?.removeWhere((w) {
      final pack = w.target;
      return pack == null || identical(pack, this);
    });
    if (_open[bytes.length]?.isEmpty ?? false) _open.remove(bytes.length);
    ssRuntime.unregisterFromGc(this);
    ssRuntime.destroyResource(resource);
  }

  /// How many packs are open, for tests.
  @visibleForTesting
  static int get debugOpenCount {
    var n = 0;
    for (final list in _open.values) {
      for (final w in list) {
        if (w.target != null) n++;
      }
    }
    return n;
  }

  /// How many holders the pack has, for tests.
  @visibleForTesting
  int get debugHolders => _holders;

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

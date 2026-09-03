// Skinned-mesh part query (the part-following "poor target" hint). Pure — no
// host Brain: a synthetic `.ssab` is built with the generated ObjectBuilders so
// the judgment is pinned independently of the runtime and of any deployed asset.
//
// The rule mirrors every official player (shared `.ssab`, same field):
//   is_part_skinned_mesh(part) := mesh_binding present && influence_bone > 0
// A rigid (deform-only) mesh — binding present but no influence bones — reads
// false because its own node transform *does* place the drawn vertices, so it
// follows correctly. Only a bone-bound (skinned) mesh diverges from its node.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// Re-exports the .ssab readers and adds back the flatc write-side classes,
// which live outside lib/ (see scripts/strip_fbs_builders.dart).
import 'support/ssab_builders.g.dart' as ssab;

/// A pack whose parts, in index order, cover every case the judgment must split:
///   0 `root`         — a NULL part, no mesh_binding                → false
///   1 `normal`       — a Normal part, no mesh_binding              → false
///   2 `rigid_null`   — Mesh, mesh_binding present, influence_bone omitted → false
///   3 `rigid_empty`  — Mesh, mesh_binding present, influence_bone []      → false
///   4 `skinned`      — Mesh, mesh_binding present, influence_bone [0, 1]  → true
Uint8List _buildSsab() {
  return ssab.SsAnimeBinaryObjectBuilder(
    name: 'pack',
    parts: [
      ssab.PartDataObjectBuilder(
        name: 'root',
        partTypeType: ssab.PartTypeTypeId.PartTypeNull,
      ),
      ssab.PartDataObjectBuilder(
        name: 'normal',
        partTypeType: ssab.PartTypeTypeId.PartTypeNormal,
      ),
      ssab.PartDataObjectBuilder(
        name: 'rigid_null',
        partTypeType: ssab.PartTypeTypeId.PartTypeMesh,
        meshBinding: ssab.PartMeshBindingObjectBuilder(),
      ),
      ssab.PartDataObjectBuilder(
        name: 'rigid_empty',
        partTypeType: ssab.PartTypeTypeId.PartTypeMesh,
        meshBinding: ssab.PartMeshBindingObjectBuilder(influenceBone: <int>[]),
      ),
      ssab.PartDataObjectBuilder(
        name: 'skinned',
        partTypeType: ssab.PartTypeTypeId.PartTypeMesh,
        meshBinding:
            ssab.PartMeshBindingObjectBuilder(influenceBone: <int>[0, 1]),
      ),
    ],
  ).toBytes();
}

void main() {
  group('PartNameTable.isSkinnedMeshAt', () {
    late PartNameTable table;
    setUp(() => table = PartNameTable.readAll(_buildSsab()));

    test('only a bone-bound mesh reads true', () {
      expect(table.isSkinnedMeshAt(table.indexOf('skinned')), isTrue);
    });

    test('a NULL / Normal part with no binding reads false', () {
      expect(table.isSkinnedMeshAt(table.indexOf('root')), isFalse);
      expect(table.isSkinnedMeshAt(table.indexOf('normal')), isFalse);
    });

    test('a rigid mesh (binding present, no influence bones) reads false', () {
      // Both the omitted-list and the empty-list encodings are rigid: the mesh
      // deforms but is not skinned, so its node transform still places it.
      expect(table.isSkinnedMeshAt(table.indexOf('rigid_null')), isFalse);
      expect(table.isSkinnedMeshAt(table.indexOf('rigid_empty')), isFalse);
    });

    test('out-of-range indices read false, never throw', () {
      expect(table.isSkinnedMeshAt(-1), isFalse);
      expect(table.isSkinnedMeshAt(table.length), isFalse);
      expect(table.isSkinnedMeshAt(9999), isFalse);
    });

    test('the empty table reads false everywhere', () {
      expect(PartNameTable.empty.isSkinnedMeshAt(0), isFalse);
    });
  });
}

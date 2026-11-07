// A pack is parsed once however many players read it: players handed the same
// bytes, and the instance children of one pack, bind one SsabPack, and its
// atlases are decoded once for all of them. Runs against real converter output
// and skips when the example assets have not been prepared.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show ByteData, CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
import 'package:ssplayer_flutter/src/ssab_pack.dart';
import 'package:ssruntime_dart/ssruntime_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ringo = _asset('Ringo/Ringo.ssab');
  final basic = _asset('overall/Basic.ssab');
  final instance = _asset('overall/Instance.ssab');
  final instanceChild = _asset('overall/Instance_SourceAnime.ssab');

  test('players of the same bytes share one pack', () {
    if (ringo == null) {
      markTestSkipped('Ringo.ssab missing — run deploy-examples.sh');
      return;
    }
    final open = SsabPack.debugOpenCount;
    // Two buffers, as two asset loads hand over: equal bytes, not one object.
    final a = SpriteStudioInternalPlayer.load(Uint8List.fromList(ringo));
    final b = SpriteStudioInternalPlayer.load(Uint8List.fromList(ringo));
    expect(b.pack, same(a.pack));
    expect(a.pack.debugHolders, 2);
    expect(SsabPack.debugOpenCount, open + 1);

    a.dispose();
    // The pack outlives the player that let go of it.
    expect(b.setupAnimation('wait1'), isTrue);
    b.play();
    b.updateMs(100);
    expect(b.getFrameData(b.frameNo), isNotNull);

    b.dispose();
    expect(SsabPack.debugOpenCount, open);
  });

  test('different bytes get packs of their own', () {
    if (ringo == null || basic == null) {
      markTestSkipped('Ringo.ssab / Basic.ssab missing');
      return;
    }
    final a = SpriteStudioInternalPlayer.load(ringo);
    final b = SpriteStudioInternalPlayer.load(basic);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    expect(b.pack, isNot(same(a.pack)));
  });

  test('a shared pack plays what a parse of its own does', () {
    if (ringo == null) {
      markTestSkipped('Ringo.ssab missing');
      return;
    }
    // The runtime builds an animation's caches on the resource the first time
    // any context sets it up, so the second player's animation must not see
    // what the first one's left there.
    final first = SpriteStudioInternalPlayer.load(ringo);
    final shared = SpriteStudioInternalPlayer.load(ringo);
    addTearDown(first.dispose);
    addTearDown(shared.dispose);
    expect(first.setupAnimation('wait1'), isTrue);
    expect(shared.setupAnimation('attack1'), isTrue);
    first.play();
    shared.play();

    final resource = ssRuntime.createResourceCopy(ringo)!;
    final context = ssRuntime.createContext()!;
    addTearDown(() {
      ssRuntime.destroyContext(context);
      ssRuntime.destroyResource(resource);
    });
    expect(ssRuntime.bindResource(context, resource), isTrue);
    ssRuntime.setRenderMode(context, 0);
    ssRuntime.setCoordinateSystem(context, 1);
    expect(ssRuntime.setupAnimation(context, 'attack1'), isTrue);
    ssRuntime.play(context);

    for (var i = 0; i < 40; i++) {
      first.updateMs(1000 / 60);
      shared.updateMs(1000 / 60);
      ssRuntime.update(context, 1000 / 60);
      expect(shared.frameNo, ssRuntime.frameNo(context));

      expect(shared.getFrameData(shared.frameNo), isNotNull);
      final world = Float32List.fromList(shared.worldMatrices());
      final local = Float32List.fromList(shared.localVertices());
      final meshX = Float32List.fromList(shared.meshVerticesX());
      expect(ssRuntime.getFrameData(context, ssRuntime.frameNo(context)),
          isNotNull);
      expect(world, ssRuntime.worldMatrices(context), reason: 'frame $i');
      expect(local, ssRuntime.localVertices(context), reason: 'frame $i');
      expect(meshX, ssRuntime.meshVerticesX(context), reason: 'frame $i');
    }
  });

  test('the instance children of one pack share it', () {
    if (instance == null || instanceChild == null) {
      markTestSkipped('Instance.ssab missing');
      return;
    }
    final open = SsabPack.debugOpenCount;
    SpriteStudioInternalPlayer load() => SpriteStudioInternalPlayer.load(
          Uint8List.fromList(instance),
          instancePacks: <int, Uint8List>{
            InstancePart.packHashOf(instanceChild):
                Uint8List.fromList(instanceChild),
          },
        );
    final a = load();
    final b = load();

    final children = <SpriteStudioInternalPlayer>[
      for (final p in [a, b])
        for (final part in p.instanceParts)
          if (p.instanceSlotFor(part.partIndex) case final slot?) slot.child,
    ];
    expect(children, isNotEmpty);
    // Instance.ssab and Instance_SourceAnime.ssab, once each, for two players
    // and every child they play.
    expect(SsabPack.debugOpenCount, open + 2);
    expect(b.pack, same(a.pack));
    for (final child in children) {
      expect(child.pack, same(children.first.pack));
    }
    expect(children.first.pack.debugHolders, children.length);

    a.dispose();
    b.dispose();
    expect(SsabPack.debugOpenCount, open);
  });

  test('players of one pack share its decoded atlases', () async {
    final root = _assetRoot();
    if (root == null) {
      markTestSkipped('example assets missing — run deploy-examples.sh');
      return;
    }
    final bundle = _DiskBundle(root);
    final a = SpriteStudioPlayer();
    final b = SpriteStudioPlayer();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await Future.wait([
      a.loadAsset('Ringo/Ringo.ssab', bundle: bundle),
      b.loadAsset('Ringo/Ringo.ssab', bundle: bundle),
    ]);
    expect(a.lastTextureReport!.isComplete, isTrue);
    final hash = a.cellmapTextureHash('Ringo')!;
    final atlas = a.textures.imageFor(hash);
    expect(atlas, isNotNull);
    expect(b.textures.imageFor(hash), same(atlas));
    // Each player keeps a registry of its own, so a replacement does not
    // reach the other.
    expect(b.textures, isNot(same(a.textures)));
  });

  test('a pack of another schema version says which versions differ', () {
    if (basic == null) {
      markTestSkipped('Basic.ssab missing — run scripts/deploy-examples.sh');
      return;
    }
    // `version` is the root table's first field.
    final other = Uint8List.fromList(basic);
    final data = ByteData.sublistView(other);
    final table = data.getUint32(0, Endian.little);
    final vtable = table - data.getInt32(table, Endian.little);
    final field = data.getUint16(vtable + 4, Endian.little);
    data.setUint32(table + field, 999, Endian.little);

    final open = SsabPack.debugOpenCount;
    expect(
        () => SsabPack.open(other),
        throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('999'),
                contains('version ${ssRuntime.ssabSchemaVersion}')))));
    expect(SsabPack.debugOpenCount, open);
  });

  test('a pack that fails to load leaves nothing open', () {
    final open = SsabPack.debugOpenCount;
    expect(() => SpriteStudioInternalPlayer.load(Uint8List(64)),
        throwsA(anything));
    expect(SsabPack.debugOpenCount, open);
  });
}

Uint8List? _asset(String path) {
  final root = _assetRoot();
  if (root == null) return null;
  final f = File('$root/$path');
  return f.existsSync() ? Uint8List.fromList(f.readAsBytesSync()) : null;
}

String? _assetRoot() {
  for (final root in const [
    'examples/overall/assets/spritestudio',
    '../../examples/overall/assets/spritestudio',
  ]) {
    if (Directory(root).existsSync()) return root;
  }
  return null;
}

/// Serves asset keys from the example assets on disk.
class _DiskBundle extends CachingAssetBundle {
  _DiskBundle(this.root);

  final String root;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File('$root/$key').readAsBytes());
}

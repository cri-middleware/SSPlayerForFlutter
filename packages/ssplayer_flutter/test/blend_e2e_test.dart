// End-to-end guard for the framebuffer blend paths, on the real `BlendMode` pack
// (`overall/BlendMode.ssab`) through the real Canvas backend.
//
// The pack is built for exactly this: a 16-tile `BG` group, then one Normal
// part per blend mode over it — `MIX`, `MUL`, `ADD`, `SUB`, `AMUL` (Mulalpha),
// `SCR`, `EXCL`, `INV`. The BG is opaque in one half and half transparent
// (α 128) in the other, and every test part straddles both. Over the opaque
// half every mode is in the regime the reference GL state defines, so the
// checks below read only the pixels the BG left opaque, and per-mode
// invariants are checkable without knowing the geometry: render the BG alone,
// render the BG plus one test part, and compare.
//
// `blend_pixel_test.dart` proves the per-pixel maths; this proves the *plumbing*
// — that `blendPassesFor`'s multi-pass plan survives the peel/run logic, the
// z-order and the real textures. The `SUB` case guards one thing: SpriteStudio's
// Sub can only ever darken an opaque backdrop, where a single-pass `difference`
// would brighten it wherever the sprite was the brighter of the two.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
import 'package:ssplayer_flutter/src/ssab/ssab.g.dart' as ssab;

const int _w = 320, _h = 320; // the pack's own canvas size

/// The pack's test parts, by the blend mode each one carries.
const Map<String, ssab.BlendType> _testParts = <String, ssab.BlendType>{
  'MIX': ssab.BlendType.Mix,
  'MUL': ssab.BlendType.Mul,
  'ADD': ssab.BlendType.Add,
  'SUB': ssab.BlendType.Sub,
  'AMUL': ssab.BlendType.Mulalpha,
  'SCR': ssab.BlendType.Screen,
  'EXCL': ssab.BlendType.Exclusion,
  'INV': ssab.BlendType.Invert,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpriteStudioInternalPlayer player;
  late ssab.SsAnimeBinary anime;

  setUp(() async {
    final path = _firstExisting(<String>[
      'examples/overall/assets/spritestudio/overall/BlendMode.ssab',
      '../../examples/overall/assets/spritestudio/overall/BlendMode.ssab',
    ]);
    if (path == null) return;
    final dir = path.substring(0, path.lastIndexOf('/'));
    final bytes = Uint8List.fromList(File(path).readAsBytesSync());
    player = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(player.dispose);
    anime = ssab.SsAnimeBinary(bytes);
    for (final cellmap in anime.cellmaps ?? const <ssab.CellMap>[]) {
      final image = cellmap.imagePath;
      if (image == null) continue;
      final file = File('$dir/$image');
      if (!file.existsSync()) continue;
      player.textures.register(cellmap.nameHash,
          await SsTextureLoader.decodeImage(
              Uint8List.fromList(file.readAsBytesSync())));
    }
    expect(player.setupAnimation(anime.animations!.first.name!), isTrue);
  });

  test('the pack really does carry every mode this test claims', () {
    if (!_ready()) return;
    final byName = <String, ssab.BlendType>{};
    for (final part in anime.parts ?? const <ssab.PartData>[]) {
      final name = part.name;
      if (name != null && _testParts.containsKey(name)) {
        byName[name] = part.blendType;
      }
    }
    // If SpriteStudio-SDK's fixture pack changes, the invariants below silently
    // stop testing what they say they test — so pin the mapping.
    expect(byName, _testParts);
  });

  test('SUB only ever darkens the opaque BG (never brightens it)', () async {
    if (!_ready()) return;
    final backdrop = await _render(player, only: null);
    final withSub = await _render(player, only: 'SUB');

    var covered = 0, changed = 0;
    for (var i = 0; i + 3 < backdrop.lengthInBytes; i += 4) {
      if (backdrop.getUint8(i + 3) != 255) continue; // only over the opaque BG
      covered++;
      // Sub is `max(0, Cb - Cs)`: every channel is ≤ the backdrop, and the
      // backdrop's own coverage survives (a mode that ate alpha would punch a
      // transparent hole here instead of darkening).
      expect(withSub.getUint8(i + 3), 255,
          reason: 'SUB must not punch a hole in the opaque BG (byte $i)');
      for (var c = 0; c < 3; c++) {
        expect(withSub.getUint8(i + c), lessThanOrEqualTo(backdrop.getUint8(i + c)),
            reason: 'SUB brightened the BG at byte ${i + c} — the hallmark of '
                'the single-pass `difference` approximation');
      }
      if (withSub.getUint32(i) != backdrop.getUint32(i)) changed++;
    }
    expect(covered, greaterThan(1000), reason: 'expected an opaque BG to compare against');
    expect(changed, greaterThan(100), reason: 'the SUB part must actually draw');
  });

  test('every mode draws something and leaves the opaque BG opaque', () async {
    if (!_ready()) return;
    final backdrop = await _render(player, only: null);
    for (final name in _testParts.keys) {
      final rendered = await _render(player, only: name);
      var changed = 0, holes = 0;
      for (var i = 0; i + 3 < backdrop.lengthInBytes; i += 4) {
        if (backdrop.getUint8(i + 3) != 255) continue;
        if (rendered.getUint8(i + 3) != 255) holes++;
        if (rendered.getUint32(i) != backdrop.getUint32(i)) changed++;
      }
      expect(holes, 0, reason: '$name turned opaque BG pixels transparent');
      expect(changed, greaterThan(100), reason: '$name drew nothing');
    }
  });
}

/// Renders one frame with every test part hidden except [only] (all of them when
/// [only] is null), so the difference against the BG-only render isolates that
/// one part's blend.
Future<ByteData> _render(SpriteStudioInternalPlayer player,
    {required String? only}) async {
  for (final name in _testParts.keys) {
    player.setPartVisibilityOverride(name, name != only);
  }
  // Re-evaluate the frame under the new overrides, then draw it. Frame 5 is
  // mid-animation, where the pack has all its parts on screen.
  player.seek(5);
  player.update(Duration.zero);
  final recorder = ui.PictureRecorder();
  player.paint(ui.Canvas(recorder),
      dst: const ui.Rect.fromLTWH(0, 0, _w * 1.0, _h * 1.0),
      sourceSize: const ui.Size(_w * 1.0, _h * 1.0));
  final picture = recorder.endRecording();
  final image = await picture.toImage(_w, _h);
  final bytes = await image.toByteData(); // premultiplied RGBA8888
  picture.dispose();
  image.dispose();
  return bytes!;
}

bool _ready() {
  final path = _firstExisting(<String>[
    'examples/overall/assets/spritestudio/overall/BlendMode.ssab',
    '../../examples/overall/assets/spritestudio/overall/BlendMode.ssab',
  ]);
  if (path == null) {
    markTestSkipped('BlendMode.ssab missing — run deploy-examples.sh');
    return false;
  }
  return true;
}

String? _firstExisting(List<String> paths) {
  for (final path in paths) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

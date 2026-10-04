// Part overrides (Override Layer) — the imperative "make this part this
// colour / cell / hidden now" layer that wins over both keyframes and blend.
//
// The pure pieces (RGBA packing, the part-name table) run everywhere. The rest
// drives a real Brain against Ringo.ssab and skips when the example assets have
// not been deployed (`scripts/deploy-examples.sh`).
//
// What is deliberately NOT asserted here: that an override *changed pixels*.
// The Brain applies it at a seam inside its own pipeline, so the observable
// Body-side effects — `draw_order` losing a
// force-hidden part, `local_uvs` moving to the swapped cell — are
// what these tests check. Shader output is only verifiable in examples/overall.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('packRgba', () {
    test('packs to 0xRRGGBBAA, not Flutter ARGB', () {
      // Opaque red: R in the top byte, A in the bottom one. Getting this
      // backwards silently tints everything with the alpha channel.
      expect(packRgba(const ui.Color(0xFFFF0000)), 0xFF0000FF);
      expect(packRgba(const ui.Color(0xFF00FF00)), 0x00FF00FF);
      expect(packRgba(const ui.Color(0xFF0000FF)), 0x0000FFFF);
      expect(packRgba(const ui.Color(0x00000000)), 0x00000000);
      expect(packRgba(const ui.Color(0xFFFFFFFF)), 0xFFFFFFFF);
    });

    test('half alpha survives the round trip to 8-bit', () {
      // 0x80 = 128; the round half-up must not drop it to 127.
      expect(packRgba(const ui.Color(0x80FFFFFF)) & 0xFF, 0x80);
    });
  });

  group('SsBlendOp / SsOverridePriority wire values', () {
    test('match the C-API encoding', () {
      // These are the numbers that cross the FFI boundary; a reorder of the
      // enum would silently change every caller's blend mode.
      expect(SsBlendOp.mix.value, 0);
      expect(SsBlendOp.mul.value, 1);
      expect(SsBlendOp.add.value, 2);
      expect(SsBlendOp.sub.value, 3);
      expect(SsOverridePriority.overwriteOnNextKeyframe.value, 0);
      expect(SsOverridePriority.holdUntilNextAnimation.value, 1);
      expect(SsOverridePriority.permanent.value, 2);
    });
  });

  group('PartNameTable', () {
    test('empty table misses every lookup', () {
      expect(PartNameTable.empty.length, 0);
      expect(PartNameTable.empty.indexOf('apple'), -1);
      expect(PartNameTable.empty.nameAt(0), isNull);
    });

    test('reads Ringo\'s parts index-aligned and resolves both ways', () {
      final bytes = _ringo();
      if (bytes == null) return;
      final table = PartNameTable.readAll(bytes);

      expect(table.length, greaterThan(1));
      expect(table.names.first, 'root', reason: 'part 0 is the root');

      final apple = table.indexOf('apple');
      expect(apple, greaterThanOrEqualTo(0));
      // The two directions must agree — that is the whole contract callers
      // rely on when they cache an index and later log its name.
      expect(table.nameAt(apple), 'apple');

      expect(table.indexOf('no-such-part'), -1);
      expect(table.nameAt(-1), isNull);
      expect(table.nameAt(table.length), isNull);
    });
  });

  group('SsAnimeInfo.cellNames', () {
    test('lists the cells of a cellmap and nothing for an unknown one', () {
      final bytes = _ringo();
      if (bytes == null) return;
      final info = SsAnimeInfo(bytes);

      expect(info.cellmapNames, contains('Ringo'));
      final cells = info.cellNames('Ringo');
      expect(cells, contains('apple'));
      expect(cells, contains('effect3'));
      expect(info.cellNames('Ringo.ssce'), isEmpty,
          reason: 'the cellmap name carries no .ssce extension');
      expect(info.cellNames('nope'), isEmpty);
    });
  });

  group('SpriteStudioInternalPlayer overrides (real Brain)', () {
    test('every override fails until setAnimation has run', () {
      final p = _load(setup: false);
      if (p == null) return;
      addTearDown(p.dispose);

      // The Brain sizes its per-part override table inside setup_animation
      // (bind_resource empties it), so before that every index is out of range.
      // The name table is read from the pack, so it resolves either way — which
      // is precisely how a caller ends up holding a valid index and a failing
      // set, and why this is asserted.
      final apple = p.findPartIndex('apple');
      expect(apple, greaterThanOrEqualTo(0),
          reason: 'the name table does not depend on setup');
      expect(p.setPartColorOverrideByIndex(apple, _blue, blendOp: SsBlendOp.mix), isFalse);
      expect(p.setPartVisibilityOverrideByIndex(apple, true), isFalse);
      expect(p.setPartCellOverrideByIndex(apple, 'Ringo', 'effect3'), isFalse);

      // ...and start working the moment an animation is selected.
      expect(p.setupAnimation(_animations().first), isTrue);
      expect(p.setPartColorOverrideByIndex(apple, _blue, blendOp: SsBlendOp.mix), isTrue);
    });

    test('rejects a negative part index without touching the Brain', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);

      // -1 is what an unknown name resolves to, so every entry point has to
      // absorb it rather than pass it to the Brain as a huge uint32.
      expect(p.setPartVisibilityOverrideByIndex(-1, true), isFalse);
      expect(p.clearPartVisibilityOverrideByIndex(-1), isFalse);
      expect(p.setPartColorOverrideByIndex(-1, _blue, blendOp: SsBlendOp.mix), isFalse);
      expect(p.clearPartColorOverrideByIndex(-1), isFalse);
      expect(p.setPartCellOverrideByIndex(-1, 'Ringo', 'effect3'), isFalse);
      expect(p.clearPartCellOverrideByIndex(-1), isFalse);
    });

    test('by-name calls on an unknown part are a no-op returning false', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);

      expect(p.findPartIndex('no-such-part'), -1);
      expect(p.setPartVisibilityOverride('no-such-part', true), isFalse);
      expect(p.setPartColorOverride('no-such-part', _blue, blendOp: SsBlendOp.mix),
          isFalse);
      expect(p.setPartCellOverride('no-such-part', 'Ringo', 'effect3'),
          isFalse);
      expect(p.clearPartColorOverride('no-such-part'), isFalse);
    });

    test('colour override is accepted for every priority mode', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');

      for (final priority in SsOverridePriority.values) {
        expect(p.setPartColorOverrideByIndex(apple, _blue, blendOp: SsBlendOp.mul,
                priority: priority),
            isTrue,
            reason: 'priority $priority should be accepted');
      }
      for (final op in SsBlendOp.values) {
        expect(p.setPartColorOverrideByIndex(apple, _blue, blendOp: op), isTrue,
            reason: 'blend op $op should be accepted');
      }
      expect(p.clearPartColorOverrideByIndex(apple), isTrue);
    });

    test('a colour override on a non-Normal part still succeeds (ignored at '
        'the seam, not rejected)', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);

      // The part-type guard runs when the override is APPLIED, so the
      // set call itself returns true. Callers must not read the return value as
      // "this will be visible". `root` is a Null part.
      final root = p.findPartIndex('root');
      expect(root, greaterThanOrEqualTo(0));
      expect(p.setPartColorOverrideByIndex(root, _blue, blendOp: SsBlendOp.mix), isTrue);
    });

    test('four-corner colour override takes exactly four corners', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');

      expect(
          p.setPartColorOverrideCornersByIndex(
              apple,
              (leftTop: _blue, rightTop: _red, leftBottom: _red, rightBottom: _blue),
              blendOp: SsBlendOp.mix),
          isTrue);
      expect(p.clearPartColorOverrideByIndex(apple), isTrue);
    });

    test('cell override resolves at set time — an unknown cell fails then and '
        'there', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');

      // Resolution happens once, in `set`, so a bad name is caught
      // immediately rather than costing a lookup every frame.
      expect(p.setPartCellOverrideByIndex(apple, 'Ringo', 'effect3'), isTrue);
      expect(p.setPartCellOverrideByIndex(apple, 'Ringo', 'no-such-cell'), isFalse);
      expect(p.setPartCellOverrideByIndex(apple, 'no-such-cellmap', 'effect3'), isFalse);
      // The `.ssce` extension is NOT part of the cellmap name.
      expect(p.setPartCellOverrideByIndex(apple, 'Ringo.ssce', 'effect3'), isFalse);
    });

    test('cell override changes the UVs the Body reads', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');

      // Direct render mode does not put `cells` in FrameData, so the
      // observable proof of a cell swap is the UV SoA — read it before and
      // after. `getFrameData` must precede the SoA getters.
      p.setupAnimation(_animations().first);
      p.update(const Duration(milliseconds: 16));
      final before = _uvsOf(p, apple);

      expect(p.setPartCellOverrideByIndex(apple, 'Ringo', 'effect3'), isTrue);
      p.update(const Duration(milliseconds: 16));
      final after = _uvsOf(p, apple);

      expect(after, isNot(equals(before)),
          reason: 'swapping to another cell must move the UVs');

      // (0, 0) — two empty names — is the documented revert sentinel.
      expect(p.setPartCellOverrideByIndex(apple, '', ''), isTrue);
      p.update(const Duration(milliseconds: 16));
      expect(_uvsOf(p, apple), equals(before),
          reason: 'reverting must restore the animation\'s own cell');
    });

    test('force-hide drops the part from draw_order; clearing brings it back',
        () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');

      p.setupAnimation(_animations().first);
      p.update(const Duration(milliseconds: 16));
      expect(_drawnParts(p), contains(apple),
          reason: 'the body should draw before anything is overridden');

      expect(p.setPartVisibilityOverrideByIndex(apple, true), isTrue);
      p.update(const Duration(milliseconds: 16));
      expect(_drawnParts(p), isNot(contains(apple)));

      expect(p.clearPartVisibilityOverrideByIndex(apple), isTrue);
      p.update(const Duration(milliseconds: 16));
      expect(_drawnParts(p), contains(apple));
    });

    // NB: `force = 2` (force-visible) is reserved by the Brain and always
    // fails. L2 takes a `bool hide`, so it is unreachable from this API by
    // construction — there is nothing to assert here, only a reason not to
    // widen the parameter later.

    test('cascade hides the descendants too', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);

      // `head` has a subtree; `nose` sits under it. A cascading force-hide takes
      // the descendants with it — this propagation is the OVERRIDE's, not the
      // keyframe `hide`'s, which stays strictly per-part.
      final head = p.findPartIndex('head');
      final nose = p.findPartIndex('nose');
      expect(head, greaterThanOrEqualTo(0));
      expect(nose, greaterThanOrEqualTo(0));

      p.setupAnimation(_animations().first);
      p.update(const Duration(milliseconds: 16));
      expect(_drawnParts(p), containsAll(<int>[head, nose]));

      expect(p.setPartVisibilityOverrideByIndex(head, true, cascade: true), isTrue);
      p.update(const Duration(milliseconds: 16));
      final drawn = _drawnParts(p);
      expect(drawn, isNot(contains(head)));
      expect(drawn, isNot(contains(nose)),
          reason: 'cascade must reach the descendant');
    });

    test('without cascade only the named part hides', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final head = p.findPartIndex('head');
      final nose = p.findPartIndex('nose');

      p.setupAnimation(_animations().first);
      expect(p.setPartVisibilityOverrideByIndex(head, true), isTrue);
      p.update(const Duration(milliseconds: 16));
      final drawn = _drawnParts(p);
      expect(drawn, isNot(contains(head)));
      expect(drawn, contains(nose),
          reason: 'a non-cascading hide must leave descendants alone');
    });

    test('clearAllPartOverrides wipes every attribute at once', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');
      final heta = p.findPartIndex('heta');

      p.setupAnimation(_animations().first);
      p.setPartVisibilityOverrideByIndex(apple, true);
      p.setPartVisibilityOverrideByIndex(heta, true);
      p.setPartColorOverrideByIndex(apple, _blue, blendOp: SsBlendOp.mix);
      p.setPartCellOverrideByIndex(apple, 'Ringo', 'effect3');
      p.update(const Duration(milliseconds: 16));
      expect(_drawnParts(p), isNot(contains(apple)));

      expect(p.clearAllPartOverrides(), isTrue);
      p.update(const Duration(milliseconds: 16));
      final drawn = _drawnParts(p);
      expect(drawn, contains(apple));
      expect(drawn, contains(heta));
    });

    test('setAnimation clears a hold-until-next override but keeps a '
        'permanent one', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');
      final anims = _animations();
      if (anims.length < 2) {
        markTestSkipped('Ringo should ship more than one animation');
        return;
      }

      // A cell override is the one whose effect is directly
      // observable from the Body (the UVs), so it stands in for the pair.
      p.setupAnimation(anims[0]);
      p.update(const Duration(milliseconds: 16));
      final animCell = _uvsOf(p, apple);

      p.setPartCellOverrideByIndex(apple, 'Ringo', 'effect3',
          priority: SsOverridePriority.holdUntilNextAnimation);
      p.update(const Duration(milliseconds: 16));
      final overridden = _uvsOf(p, apple);
      expect(overridden, isNot(equals(animCell)));

      p.setupAnimation(anims[1]);
      p.update(const Duration(milliseconds: 16));
      expect(_uvsOf(p, apple), isNot(equals(overridden)),
          reason: 'holdUntilNextAnimation must not survive setAnimation');

      // Permanent survives the same transition.
      p.setupAnimation(anims[0]);
      p.setPartCellOverrideByIndex(apple, 'Ringo', 'effect3',
          priority: SsOverridePriority.permanent);
      p.update(const Duration(milliseconds: 16));
      final permanent = _uvsOf(p, apple);
      p.setupAnimation(anims[1]);
      p.update(const Duration(milliseconds: 16));
      expect(_uvsOf(p, apple), equals(permanent),
          reason: 'permanent must survive setAnimation');
    });

    test('a permanent COLOUR override survives setupAnimation, a '
        'hold-until-next one does not', () {
      // ForGodot lost exactly this: its `setAnimation` re-created and
      // re-BOUND the resource handle, and `bind_resource` clears the Brain's
      // whole override table (new pack == new part identities), so a Permanent
      // colour went with it. This Body binds once, at load
      // (`SpriteStudioInternalPlayer.load`), and `setupAnimation` never
      // re-binds — which is what leaves the Brain's own
      // `retain_permanent_overrides_on_setup` something to retain. Asserted on
      // the COLOUR attribute specifically: the sibling test above stands in for
      // the pair with a cell override, and the two clear through different
      // Brain-side paths.
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');
      final anims = _animations();
      if (anims.length < 2) {
        markTestSkipped('Ringo should ship more than one animation');
        return;
      }

      p.setupAnimation(anims[0]);
      p.setPartColorOverrideByIndex(apple, _blue,
          blendOp: SsBlendOp.mix, priority: SsOverridePriority.permanent);
      p.update(const Duration(milliseconds: 16));
      // Overriding a part the animation gave no PartColor makes the Brain emit
      // one — so its mere presence, with the override's RGB, is the proof.
      expect(_colorRgbOf(p, apple), _isColor(_blue),
          reason: 'the override must reach FrameData.parts_color');

      p.setupAnimation(anims[1]);
      p.update(const Duration(milliseconds: 16));
      expect(_colorRgbOf(p, apple), _isColor(_blue),
          reason: 'a permanent colour override must survive setupAnimation');

      // The other priority clears on the same transition, so the assertion
      // above is about the priority and not about colour overrides at large.
      p.setupAnimation(anims[0]);
      p.clearAllPartOverrides();
      p.setPartColorOverrideByIndex(apple, _red,
          blendOp: SsBlendOp.mix, priority: SsOverridePriority.holdUntilNextAnimation);
      p.update(const Duration(milliseconds: 16));
      expect(_colorRgbOf(p, apple), _isColor(_red));

      p.setupAnimation(anims[1]);
      p.update(const Duration(milliseconds: 16));
      expect(_colorRgbOf(p, apple), isNot(_isColor(_red)),
          reason: 'holdUntilNextAnimation must not survive setupAnimation');
    });
  });

  group('SpriteStudioPlayer (L3) overrides', () {
    test('are a safe no-op before load rather than a throw', () async {
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);

      // Transport throws before load; overrides must not — a UI that fires one
      // while the pack is still loading is not a bug.
      expect(player.partNames.length, 0);
      expect(player.findPartIndex('apple'), -1);
      expect(player.setPartVisibilityOverride('apple', true), isFalse);
      expect(player.clearAllPartOverrides(), isFalse);
    });

    test('a successful override notifies listeners so a paused player '
        'repaints', () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);

      // An override changes the pose without changing
      // the frame number, so nothing would redraw unless L3 says so.
      var notifications = 0;
      player.addListener(() => notifications++);

      expect(player.setPartVisibilityOverride('apple', true), isTrue);
      expect(notifications, 1);

      expect(player.clearAllPartOverrides(), isTrue);
      expect(notifications, 2);
    });

    test('a rejected override does not notify', () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);

      var notifications = 0;
      player.addListener(() => notifications++);

      expect(player.setPartVisibilityOverride('no-such-part', true),
          isFalse);
      expect(player.setPartCellOverride('apple', 'Ringo', 'no-such-cell'),
          isFalse);
      expect(notifications, 0,
          reason: 'nothing changed, so nothing should repaint');
    });

    test('delegates by index and by name to the same part', () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);

      final apple = player.findPartIndex('apple');
      expect(apple, greaterThanOrEqualTo(0));
      expect(player.partNames.nameAt(apple), 'apple');
      expect(player.setPartColorOverrideByIndex(apple, _blue, blendOp: SsBlendOp.mul), isTrue);
      expect(player.setPartColorOverride('apple', _blue, blendOp: SsBlendOp.mul),
          isTrue);
      expect(player.clearPartColorOverride('apple'), isTrue);
    });
  });
}

const ui.Color _blue = ui.Color(0xBF0033FF);
const ui.Color _red = ui.Color(0xFFFF0000);

/// Ringo's bytes, or null (with the test marked skipped) when the example
/// assets have not been deployed.
Uint8List? _ringo() {
  for (final p in const <String>[
    'examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
    '../../examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
  ]) {
    final f = File(p);
    if (f.existsSync()) return f.readAsBytesSync();
  }
  markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
  return null;
}

/// A loaded Ringo player. [setup] selects the first animation, which the
/// override table's existence depends on — pass false only to test that
/// precondition itself.
SpriteStudioInternalPlayer? _load({bool setup = true}) {
  final bytes = _ringo();
  if (bytes == null) return null;
  final p = SpriteStudioInternalPlayer.load(bytes,
      backend: SpriteStudioBackend.canvas);
  if (setup) p.setupAnimation(SsAnimeInfo(bytes).animationNames.first);
  return p;
}

/// Ringo's animation names, in pack order. L2 has no animation list of its own
/// (names live in the `.ssab`, not the Brain), so they come from the bytes.
List<String> _animations() =>
    SsAnimeInfo(_ringo() ?? Uint8List(0)).animationNames;

/// The part indices the Brain actually plans to draw this frame. A force-hidden
/// part is dropped from `draw_order` upstream of the Body, which is what makes
/// this a clean observation point.
Set<int> _drawnParts(SpriteStudioInternalPlayer p) {
  final frame = p.getFrameData(p.frameNo);
  final order = frame?.drawOrder;
  return order == null ? <int>{} : order.toSet();
}

/// The `lt` corner RGB of the PartColor the Brain emitted for [partIndex] this
/// frame, or null when it emitted none.
///
/// Only the RGB: the corner alpha carries the part's hierarchical opacity
/// pre-folded by the Brain, which legitimately differs between two animations,
/// and `rate` is the blend strength — neither says anything about *which*
/// colour survived.
List<double>? _colorRgbOf(SpriteStudioInternalPlayer p, int partIndex) {
  final fd = p.getFrameData(p.frameNo);
  final parts = fd?.parts;
  if (fd == null || parts == null || partIndex < 0 || partIndex >= parts.length) {
    return null;
  }
  final pc = PartColor.read(fd.partsColor, parts[partIndex]);
  if (pc == null) return null;
  return <double>[pc.lt.r, pc.lt.g, pc.lt.b];
}

/// Matches [_colorRgbOf] against an 8-bit sRGB [ui.Color] (1/255 tolerance).
Matcher _isColor(ui.Color c) => pairwiseCompare<double, double>(
      <double>[c.r, c.g, c.b],
      (expected, actual) => (expected - actual).abs() <= 1 / 255,
      'matches the override colour',
    );

/// The 10-float UV slice (lt, rt, lb, rb, center — texture PIXELS) of one part.
List<double> _uvsOf(SpriteStudioInternalPlayer p, int partIndex) {
  // getFrameData must run before the SoA getters (the Brain fills them there).
  p.getFrameData(p.frameNo);
  final uvs = p.localUvs();
  const stride = 10;
  final start = partIndex * stride;
  if (start + stride > uvs.length) return const <double>[];
  return uvs.sublist(start, start + stride);
}

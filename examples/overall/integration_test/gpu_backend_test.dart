import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

// On-device pixel verification of the flutter_gpu render backend. The headless
// flutter_tester has no Impeller context, so this can only run on a real target:
//
//   cd examples/overall && flutter test integration_test/gpu_backend_test.dart -d macos
//
// For each pack it renders the SAME frame through both backends and checks that
// the GPU round-trip produces non-blank output that matches the Canvas reference
// (coverage, orientation and colour) — the things a headless build can't confirm.

const int _w = 256;
const int _h = 256;

// Packs exercising the kinds implemented on the GPU backend so far. Each should
// reach pixel parity with Canvas; a kind not yet on GPU (Effect/Instance) or a
// peeled part (PartColor/mask Normal) would diverge and is kept out of these.
// Packs that must be byte-exact vs Canvas. BlendMode exercises the SS blend
// modes; it reaches parity because fixed-function covers Mix/Add/Sub/Screen and
// Multiply-over-opaque (Exclusion / Invert / Multiply-over-transparency would
// need a framebuffer-read shader, but this pack does not diverge on them).
const List<String> _packs = <String>[
  'Basic',
  'Mesh',
  'Shape',
  'Effect',
  'PartsColor',
  'Mask',
  'Instance',
  'BlendMode',
];

// A subset for the reload regression — the heaviest GPU resource sets: Basic
// (sprite pipeline + atlas texture), PartsColor (partcolor pipeline + per-part
// UBO + coverage texture). Enough to prove the backend rebuilds cleanly after a
// live-reload's dispose→recreate without re-running the whole matrix.
const List<String> _reloadPacks = <String>['Basic', 'PartsColor'];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final pack in _packs) {
    testWidgets('flutter_gpu parity vs Canvas: $pack', (tester) async {
      await loadSsRuntime();
      await _gate(tester, pack);
    });
  }

  // A dev-time live-reload disposes the internal player AND its GPU backend
  // (dropping `_gpuTextures` / `_frameCoverages` / pipelines) then rebuilds a
  // fresh one for the new bytes, with the playhead preserved. Verify the GPU
  // path still produces correct pixels after that teardown — a stale/leaked
  // texture or an un-rebuilt pipeline would show up as divergence from Canvas.
  for (final pack in _reloadPacks) {
    testWidgets('flutter_gpu survives reload: $pack', (tester) async {
      await loadSsRuntime();
      final key = 'assets/spritestudio/overall/$pack.ssab';
      final canvasPx =
          await _rgba(await _render(SpriteStudioBackend.canvas, key));
      final gpuPx =
          await _rgba(await _renderReloaded(SpriteStudioBackend.gpu, key));
      final gpuOpaque = _opaqueCount(gpuPx);
      final rgbDiff = _rgbMeanDiff(gpuPx, canvasPx);
      debugPrint('[gpu-reload:$pack] gpuOpaque=$gpuOpaque '
          'rgbDiff=${rgbDiff.toStringAsFixed(2)}');
      expect(gpuOpaque, greaterThan(200),
          reason: '[$pack] flutter_gpu produced a (near) blank frame after '
              'reload — backend rebuild dropped its textures');
      expect(rgbDiff, lessThan(6.0),
          reason: '[$pack] GPU colours diverge from Canvas after reload — the '
              'backend teardown/rebuild lost state');
    });
  }
}

Future<void> _gate(WidgetTester tester, String pack) async {
  final key = 'assets/spritestudio/overall/$pack.ssab';
  final canvasPx = await _rgba(await _render(SpriteStudioBackend.canvas, key));
  final gpuPx = await _rgba(await _render(SpriteStudioBackend.gpu, key));

  final canvasOpaque = _opaqueCount(canvasPx);
  final gpuOpaque = _opaqueCount(gpuPx);
  final matchDirect = _alphaMatch(gpuPx, canvasPx, flip: false);
  final matchFlip = _alphaMatch(gpuPx, canvasPx, flip: true);
  final rgbDiff = _rgbMeanDiff(gpuPx, canvasPx);

  debugPrint('[gpu-gate:$pack] canvasOpaque=$canvasOpaque gpuOpaque=$gpuOpaque '
      'matchDirect=${matchDirect.toStringAsFixed(3)} '
      'matchFlip=${matchFlip.toStringAsFixed(3)} '
      'rgbMeanDiff=${rgbDiff.toStringAsFixed(2)}');

  // The harness itself must be sane: Canvas renders content.
  expect(canvasOpaque, greaterThan(200),
      reason: '[$pack] Canvas reference is (near) blank — bad pack/harness');
  // The GPU round-trip must produce output.
  expect(gpuOpaque, greaterThan(200),
      reason: '[$pack] flutter_gpu produced a (near) blank frame');
  // Orientation: GPU should line up with Canvas, not its vertical mirror. `>=`
  // (not `>`) because a fully-opaque frame has uniform alpha coverage, so the
  // flip check ties at 1.0 — there the byte-exact rgbDiff below is what proves a
  // flipped frame would fail (its colours would be mirrored).
  expect(matchDirect, greaterThanOrEqualTo(matchFlip),
      reason: '[$pack] GPU output looks vertically flipped — flip _kNdcYSign');
  expect(matchDirect, greaterThan(0.9),
      reason: '[$pack] GPU/Canvas coverage disagrees beyond a Y-flip');
  // Colour parity — the backend's whole justification.
  expect(rgbDiff, lessThan(6.0),
      reason: '[$pack] GPU colours diverge from Canvas (premult/upload/blend)');
}

/// Renders [pack] frame-by-frame through [backend] into an offscreen image,
/// looping so the GPU backend's async texture uploads land before the capture.
Future<ui.Image> _render(SpriteStudioBackend backend, String assetKey) async {
  final player = SpriteStudioPlayer(backend: backend);
  await player.loadAsset(assetKey);
  _home(player);
  final img = await _captureLooping(player);
  player.dispose();
  return img;
}

/// Like [_render], but live-swaps the same bytes mid-way — the dev-time reload
/// path. A warm-up render first (so backend #1 has actually uploaded textures /
/// built pipelines), then [SpriteStudioPlayer.reloadAsset] disposes it and
/// builds a fresh backend for the re-read bytes. Transport is re-homed after the
/// reload so the captured frame lands on the SAME playhead as [_render]'s
/// reference, making the two directly comparable.
Future<ui.Image> _renderReloaded(
    SpriteStudioBackend backend, String assetKey) async {
  final player = SpriteStudioPlayer(backend: backend);
  await player.loadAsset(assetKey);
  _home(player);
  await _captureLooping(player); // warm backend #1; the reload then discards it
  await player.reloadAsset(assetKey);
  _home(player);
  final img = await _captureLooping(player);
  player.dispose();
  return img;
}

/// Selects the first animation and head-outs to its start, so two renders are
/// compared at the same playhead.
void _home(SpriteStudioPlayer player) {
  final anims = player.getAnimations();
  if (anims.isNotEmpty) player.setupAnimation(anims.first);
  player.play();
}

/// Advances + captures for a fixed number of frames, returning the last frame.
/// The loop's pacing lets the GPU backend's async texture uploads land.
Future<ui.Image> _captureLooping(SpriteStudioPlayer player) async {
  const rect = ui.Rect.fromLTWH(0, 0, _w * 1.0, _h * 1.0);
  const size = ui.Size(_w * 1.0, _h * 1.0);
  ui.Image? img;
  for (var i = 0; i < 20; i++) {
    player.advance(const Duration(milliseconds: 33));
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    player.internal!.paint(canvas, dst: rect, sourceSize: size);
    final pic = recorder.endRecording();
    img?.dispose();
    img = await pic.toImage(_w, _h);
    pic.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return img!;
}

/// The image's raw RGBA bytes (`_w*_h*4`, row-major, top-to-bottom).
Future<Uint8List> _rgba(ui.Image img) async {
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

int _opaqueCount(Uint8List rgba) {
  var n = 0;
  for (var i = 0; i < _w * _h; i++) {
    if (rgba[i * 4 + 3] > 16) n++;
  }
  return n;
}

/// Fraction of pixels whose opaque/transparent classification agrees between
/// [gpu] and [canvas] (optionally vertically flipped). Robust to colour/premult
/// differences — it only compares coverage, which is what a Y-flip perturbs.
double _alphaMatch(Uint8List gpu, Uint8List canvas, {required bool flip}) {
  var agree = 0;
  for (var y = 0; y < _h; y++) {
    final cy = flip ? (_h - 1 - y) : y;
    for (var x = 0; x < _w; x++) {
      final g = gpu[(y * _w + x) * 4 + 3] > 16;
      final c = canvas[(cy * _w + x) * 4 + 3] > 16;
      if (g == c) agree++;
    }
  }
  return agree / (_w * _h);
}

/// Mean per-channel absolute RGB difference (0..255) over pixels opaque in both
/// images — the colour-parity metric.
double _rgbMeanDiff(Uint8List gpu, Uint8List canvas) {
  var sum = 0;
  var n = 0;
  for (var i = 0; i < _w * _h; i++) {
    final o = i * 4;
    if (gpu[o + 3] > 16 && canvas[o + 3] > 16) {
      sum += (gpu[o] - canvas[o]).abs() +
          (gpu[o + 1] - canvas[o + 1]).abs() +
          (gpu[o + 2] - canvas[o + 2]).abs();
      n++;
    }
  }
  return n == 0 ? 0.0 : sum / (n * 3);
}

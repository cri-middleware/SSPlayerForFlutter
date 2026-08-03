// Smoke test for the generated write-side shims in `test/support/`, which
// scripts/strip_fbs_builders.dart splits out of `lib/` (nothing there writes a
// FlatBuffer). `test/support/**` is excluded from analysis, and the ssqb shim
// has no caller at all until sequence playback lands, so without this a broken
// regeneration would sit unnoticed until someone reached for it. Each case
// builds a buffer and reads it back through the re-exported reader, which pins
// both halves of the shim: the builders, and the `export` that lets a test swap
// only its import URI.
import 'package:flutter_test/flutter_test.dart';

import 'support/effect_draw_plan_builders.g.dart' as efbs;
import 'support/framedata_builders.g.dart' as fbs;
import 'support/ssab_builders.g.dart' as ssab;
import 'support/ssqb_builders.g.dart' as ssqb;

void main() {
  test('the ssab shim round-trips a buffer through the re-exported reader', () {
    final bytes = ssab.RectObjectBuilder(x1: 1, y1: 2, x2: 3, y2: 4).toBytes();
    expect(ssab.Rect(bytes).x1, 1);
    expect(ssab.Rect(bytes).y2, 4);
  });

  test('the ssqb shim round-trips a buffer through the re-exported reader', () {
    // No production caller yet — `.ssqb` sequence playback is still roadmap.
    final bytes = ssqb.SequenceItemObjectBuilder(
      refAnimePackHash: 7,
      repeatCount: 3,
    ).toBytes();
    expect(ssqb.SequenceItem(bytes).refAnimePackHash, 7);
    expect(ssqb.SequenceItem(bytes).repeatCount, 3);
  });

  test('the framedata shim round-trips a buffer through the re-exported reader', () {
    final bytes = fbs.FrameDataObjectBuilder(
      cells: [fbs.PartAttributeCellObjectBuilder(nameHash: 9, cellmapNameHash: 5)],
    ).toBytes();
    expect(fbs.FrameData(bytes).cells!.single.nameHash, 9);
  });

  test('the effect_draw_plan shim round-trips a buffer through the re-exported reader', () {
    final bytes = efbs.EffectDrawPlanObjectBuilder(
      vertStride: 10,
      commands: [
        efbs.EffectDrawCommandObjectBuilder(
          cellmapHash: 1,
          quadCount: 2,
          particleOffset: 3,
          blend: 0,
        ),
      ],
    ).toBytes();
    expect(efbs.EffectDrawPlan(bytes).vertStride, 10);
    expect(efbs.EffectDrawPlan(bytes).commands!.single.quadCount, 2);
  });
}

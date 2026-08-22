// Smoke test: the example app builds its game page without throwing.
//
// The example is primarily manual dogfooding (Flame owns a game loop that never
// settles, and the Ringo pack is deployed by scripts/deploy-examples.sh), so
// this only confirms the widget tree constructs and the GameWidget mounts. The
// adapter itself is unit-tested in the ssplayer_flame package.
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssplayer_flame_example/main.dart';

void main() {
  testWidgets('FlameExampleApp builds its game page', (tester) async {
    await tester.pumpWidget(const FlameExampleApp());
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(GameWidget<SpriteStudioGame>), findsOneWidget);
  });
}

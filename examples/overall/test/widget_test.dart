// Smoke test: the example app builds its player page without throwing.
//
// The example is primarily manual dogfooding (it drives an FFI player + an
// infinite ticker animation, so a full pumpAndSettle never settles); this just
// confirms the widget tree constructs. The live-reload / sswatch logic is
// unit-tested in the ssgen_flutter package.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssplayer_flutter_example/main.dart';

void main() {
  testWidgets('ExampleApp builds its player page', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(PlayerPage), findsOneWidget);
  });
}

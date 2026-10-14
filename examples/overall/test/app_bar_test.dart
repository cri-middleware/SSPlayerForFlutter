// The app bar on a phone in portrait (a Pixel 6a), once all three menus are
// up: an overflow fails the test on its own.
//
// In a file of its own: widget_test.dart ends before its pack's atlas has
// decoded, and the decode it leaves half done in the shared image cache is one
// a later load of the same bytes in that isolate would wait on forever.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssplayer_flutter_example/main.dart';

void main() {
  testWidgets('the app bar fits a phone in portrait', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ExampleApp());
    // The anime menu appears once the first pack has loaded, which takes real
    // I/O: let it run, then pump what it scheduled.
    for (var i = 0; i < 100 && find.text('anime:').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.text('anime:'), findsOneWidget);
  });
}

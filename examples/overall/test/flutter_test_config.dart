import 'dart:async';

// ignore: implementation_imports
import 'package:desktop_drop/src/native_transport.dart';

// ExampleApp's DropTarget opens desktop_drop's native transport, which looks
// its symbols up in the running process (`DynamicLibrary.process()` on macOS).
// A `flutter test` host does not link the plugin, so that lookup throws while
// the page builds. The package's own test hook stands in for it here, as its
// tests do: the view binds, and no drop ever arrives.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  NativeTransport.debugOverride = NativeTransport.testing()
    ..invokeHandler = (call) async => {
      'view': (call.arguments as Map)['view'],
      'generation': 1,
    };
  await testMain();
}

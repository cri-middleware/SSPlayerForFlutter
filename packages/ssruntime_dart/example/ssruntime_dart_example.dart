// Steps an animation with no renderer and prints what each frame would draw.
//
//   dart run example/ssruntime_dart_example.dart <pack.ssab> <animation>

import 'dart:io';

import 'package:ssruntime_dart/framedata.dart';
import 'package:ssruntime_dart/ssruntime_dart.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart run example/ssruntime_dart_example.dart <pack.ssab> <animation>',
    );
    exitCode = 64;
    return;
  }

  // On the web the runtime is a wasm module loaded here; a no-op on native.
  await loadSsRuntime();

  final resource = ssRuntime.createResourceCopy(
    File(args[0]).readAsBytesSync(),
  );
  if (resource == null) {
    stderr.writeln(
      '${args[0]}: not a pack of schema '
      '${ssRuntime.ssabSchemaVersion}, the one this runtime reads',
    );
    exitCode = 1;
    return;
  }
  final context = ssRuntime.createContext()!;

  if (ssRuntime.bindResource(context, resource) &&
      ssRuntime.setupAnimation(context, args[1])) {
    ssRuntime.play(context);
    final frameMs = 1000 / ssRuntime.frameRate(context);
    for (var i = 0; i < 5; i++) {
      final frame = ssRuntime.update(context, frameMs);
      // Every buffer is valid only until the next update: read it now.
      final bytes = ssRuntime.getFrameData(context, frame);
      if (bytes == null) continue;
      final data = FrameData(bytes);
      print(
        'frame ${frame.toStringAsFixed(1)}: '
        '${data.drawOrder?.length ?? 0} parts in '
        '${data.drawBatches?.length ?? 0} draw batches',
      );
    }
  } else {
    stderr.writeln(ssRuntime.lastErrorMessage(context));
    exitCode = 1;
  }

  ssRuntime.destroyContext(context);
  ssRuntime.destroyResource(resource);
}

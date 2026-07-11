// FFI plugin registrar stub. `ssplayer_flutter` is a dart:ffi plugin: all
// logic is in Dart and the native Brain is loaded via DynamicLibrary. This
// empty registrar exists only to satisfy CocoaPods' source_files requirement
// and Flutter's macOS plugin registration.
import FlutterMacOS
import Foundation

public class SsplayerFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}

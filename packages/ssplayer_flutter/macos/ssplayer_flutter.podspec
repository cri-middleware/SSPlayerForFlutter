#
# ssplayer_flutter — macOS plugin podspec.
#
# Ships the PREBUILT dynamic Brain wrapped as libssruntime.framework, produced
# by `scripts/build-runtime.sh platform=macos` under ../native/libs/macos/.
# CocoaPods embeds + codesigns it via `vendored_frameworks` into the app's
# Frameworks, so DynamicLibrary.open('libssruntime.framework/libssruntime')
# resolves it at runtime via @rpath. (A bare .dylib via vendored_libraries is
# linked but NOT embedded for runtime dlopen — hence the framework wrapper.)
#
# NOTE: this is an FFI plugin (no Dart platform-interface, no Swift/ObjC).
#
Pod::Spec.new do |s|
  s.name             = 'ssplayer_flutter'
  s.version          = '0.1.0'
  s.summary          = 'SpriteStudio 7 player for Flutter (macOS).'
  s.description      = 'dart:ffi Body over the SpriteStudio-SDK Rust Brain.'
  s.homepage         = 'https://github.com/cri-middleware/SSPlayerForFlutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CRI Middleware' => 'https://www.cri-mw.co.jp/' }
  s.source           = { :path => '.' }

  # A source file is required by CocoaPods even for FFI plugins.
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  # Bundle the prebuilt Brain framework (must live at/below this podspec dir so
  # CocoaPods globs it). scripts/build-runtime.sh mirrors it into macos/Frameworks.
  s.vendored_frameworks = 'Frameworks/libssruntime.framework'
end

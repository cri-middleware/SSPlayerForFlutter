#
# ssplayer_flutter — macOS plugin podspec.
#
# Ships the PREBUILT dynamic Brain as a versioned libssruntime.framework, built by
# SpriteStudio-SDK's release-macos.sh (universal) — or wrapped from a host dylib by
# `scripts/build-runtime.sh platform=macos` (fast debug) — under ../native/libs/macos/.
# CocoaPods embeds + codesigns it via `vendored_frameworks` into the app's Frameworks,
# so DynamicLibrary.open('libssruntime.framework/libssruntime') resolves it at runtime
# via @rpath. (A bare .dylib via vendored_libraries is linked but NOT embedded for
# runtime dlopen — hence the framework.)
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

  # Bundle the prebuilt Brain framework. CocoaPods only EMBEDS a vendored framework
  # that lives at/below the podspec dir (a `../native/...` path is recorded but not
  # copied into the app's Frameworks — verified: the app then has no libssruntime),
  # so build-runtime.sh / download-sdk.sh symlink the single native/libs/macos copy
  # in here. `install_framework` resolves the symlink at embed time.
  s.vendored_frameworks = 'Frameworks/libssruntime.framework'
end

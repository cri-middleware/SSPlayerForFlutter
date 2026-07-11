#
# ssplayer_flutter — iOS plugin podspec.
#
# Ships the PREBUILT dynamic xcframework produced by
# `scripts/build-runtime.sh platform=ios` under
# ../native/libs/ios/libssruntime.xcframework. CocoaPods embeds it via
# `vendored_frameworks`; dyld loads it at launch so DynamicLibrary.process()
# (see ssruntime_library.dart) resolves the Brain's symbols.
#
Pod::Spec.new do |s|
  s.name             = 'ssplayer_flutter'
  s.version          = '0.1.0'
  s.summary          = 'SpriteStudio 7 player for Flutter (iOS).'
  s.description      = 'dart:ffi Body over the SpriteStudio-SDK Rust Brain.'
  s.homepage         = 'https://github.com/cri-middleware/SSPlayerForFlutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CRI Middleware' => 'https://www.cri-mw.co.jp/' }
  s.source           = { :path => '.' }

  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  # Bundle the prebuilt Brain. Run scripts/build-runtime.sh platform=ios first.
  s.vendored_frameworks = '../native/libs/ios/libssruntime.xcframework'
end

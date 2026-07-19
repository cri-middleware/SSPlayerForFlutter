# Third-Party Notices

This file contains the license notices for third-party components used in **SpriteStudioPlayer for
Flutter**.

We would like to thank the authors and contributors of these open-source projects.

---

## SpriteStudio-SDK (`libssruntime` / `libssconverter`)

This project integrates the SpriteStudio-SDK native libraries via `dart:ffi` `@Native` bindings.
`libssruntime` (the runtime "Brain") is bundled into every app by `ssruntime_dart`; the host
`libssconverter` is bundled by `ssconverter_dart` (desktop-only).

Copyright (c) CRI Middleware Co., Ltd. All rights reserved.

`SpriteStudio-SDK` is licensed under the BSD-3-Clause License.

### Rust Runtime Dependencies

`libssruntime` and `libssconverter` are written in Rust and depend on various third-party open-source
crates.

**License Location:**
Because the native binaries are generated artifacts and not checked into this repository, the
corresponding license documents for the Rust dependencies are downloaded/placed during the
build/setup process. After running `scripts/build-runtime.*` (or after the build hook downloads the
prebuilt libraries), you can find them under each binding package's `native/libs/` directory:

- `packages/ssruntime_dart/native/libs/THIRD-PARTY-LICENSES.ssruntime.md`
- `packages/ssruntime_dart/native/libs/LICENSE.md`
- `packages/ssconverter_dart/native/libs/THIRD-PARTY-LICENSES.ssconverter.md`
- `packages/ssconverter_dart/native/libs/LICENSE.md`

**Distribution Note:**
Official release bundles include these third-party license files alongside the native libraries. If
you redistribute an application that embeds `libssruntime` (or a build that embeds `libssconverter`),
keep the corresponding `THIRD-PARTY-LICENSES.*.md` and `LICENSE.md` files alongside your distribution
to comply with the open-source licenses of the underlying Rust crates.

---

## FlatBuffers

This project depends on FlatBuffers for binary (de)serialization of the `.ssab` asset format and the
runtime `FrameData` / effect draw-plan buffers. The flatc-generated Dart accessors are committed in
`packages/ssplayer_flutter/lib/src/ssab/` and `packages/ssruntime_dart/lib/src/fbs/`.

Copyright (c) 2014 Google Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

---

## Dart & Flutter package dependencies

Each package in this monorepo declares its runtime dependencies in its `pubspec.yaml` (e.g. `ffi`,
and — for the optional Flame adapter — `flame`). Those packages are distributed via pub.dev under
their own licenses. To review the full resolved dependency licenses for a package, run
`dart pub deps` (or `flutter pub deps`) in that package and consult each dependency's page on
[pub.dev](https://pub.dev/).

# Third-Party Notices

This project uses third-party open-source components. The authoritative list is
[`THIRD_PARTY_NOTICES.md`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/THIRD_PARTY_NOTICES.md)
at the repository root, covering:

- **SpriteStudio-SDK** native libraries (`libssruntime` / `libssconverter`) and their Rust crate
  dependencies (BSD-3-Clause).
- **FlatBuffers** (Apache-2.0) — used for the `.ssab` asset format and runtime `FrameData` buffers.
- The **Dart / Flutter package dependencies** — distributed via pub.dev under their own licenses.

The prebuilt native libraries bundle their own crate license notices, placed after a source build or
download:

- `packages/ssruntime_dart/native/libs/THIRD-PARTY-LICENSES.ssruntime.md`
- `packages/ssconverter_dart/native/libs/THIRD-PARTY-LICENSES.ssconverter.md`

If you redistribute an application that embeds these native libraries, keep the corresponding notices
alongside your distribution. For the project and SDK licenses themselves, see [License](index.md).

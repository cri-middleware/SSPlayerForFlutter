# 📱 SpriteStudio Player for Flutter

Play **SpriteStudio** animations (`.ssab`) natively in Flutter — rigged by
an artist in a dedicated editor, drawn through Flutter's own renderer, with no animation code to
hand-write. Playback runs through `libssruntime` provided by
[SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK).

!!! tip "New to SpriteStudio?"
    [SpriteStudio](https://www.webtech.co.jp/eng/spritestudio/) is a professional 2D animation
    editor: bone rigs, mesh deformation, and particle effects applied to **raster** (PNG) sprite
    art. Your artist authors the motion visually; this player plays the finished file. It is
    lighter than shipping a `.gif` or `.mp4`.
    You do not need data of your own to start: the
    [official sample data](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/) works as-is
    ([Ringo](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#ringo) for a character,
    [Particle](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#Perticle_sample) for effects),
    though that page is Japanese only. To make your own, you use SpriteStudio itself — see
    [its site](https://www.webtech.co.jp/eng/spritestudio/).

!!! example "Try it in a browser"
    Two [**live Web demos**](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) are published beside these pages: the `examples/overall`
    app driving the `ssplayer_flutter` widget, and the `examples/flame` one driving
    `ssplayer_flame`, both built for the web. The Web target is a developer preview; see
    [Limitations & Scope](limitations.md).

## Table of Contents

- **Setup**
    - [Installation](guide/install.md)
- **Workflow**
    - [Quick Start](guide/quickstart.md)
    - [Playback & Events](guide/playback.md)
    - [Motion Blending](guide/motion-blending.md)
    - [Part Following](guide/part-following.md)
    - [Part Overrides](guide/part-overrides.md)
    - [Buttons & UI States](guide/buttons.md)
    - [Texture Replacement](guide/textures.md)
    - [Flame Integration](guide/flame.md)
    - [Preparing Assets (`.sspj` → `.ssab`)](guide/conversion.md)
    - [Live Reload](guide/live-reload.md)
- [**API Reference**](api.md)
- [**Limitations & Scope**](limitations.md)
- **For Player & SDK Developers**
    - [Build Guide](development/build.md)
    - [How the Player Is Put Together](development/architecture.md)
    - [Native Runtime](development/native-runtime.md)
- [**Packages**](packages.md)

## Key Features

- **Bring your sprites — and whole screens — to life.** Breathing and blinking, swaying hair and clothes, flashy slash and magic effects, even an animated HUD or splash screen: the motion is built visually in a dedicated editor (SpriteStudio) and `SpriteStudioAnimation` just plays it. Bone rigs, mesh deformation and particles are all handled for you, so there is no animation code to write.
- **Raster art, drawn natively — not vector, not video.** It animates **raster** (bitmap/PNG) sprite art, so painted illustrations and rich textures move exactly as drawn — a different fit from vector animation tools. Unlike a `.gif` or an `.mp4`, it scales freely, loops seamlessly and reacts to your app, and Flutter's own renderer draws it via `dart:ffi` and native assets — no WebView, no video decoding, and no manual native linking.
- **A widget like any other — and a [Flame](guide/flame.md) component.** Position, size, transform and clip it like any other widget. Keys the artist placed on the timeline — user data, signals, audio cues — arrive as callbacks ([Playback & Events](guide/playback.md)), per-part overrides recolour, hide or swap a part at runtime ([Part Overrides](guide/part-overrides.md)), and [`setCellmapTexture()`](guide/textures.md) swaps textures for skins and costumes. Making a game? `ssplayer_flame` drops the same animation into a `FlameGame`.
- **Smooth motion — between frames and between animations.** **Sub-frame interpolation** renders each frame at the exact display time, so motion follows your display's refresh rate and playback speed instead of the authored fps. Set `transition` and a change of `animation` [crossfades](guide/motion-blending.md) instead of cutting, and further tracks lay a blink or an aim over what is playing.
- **A seamless edit-to-runtime loop.** [Live reload](guide/live-reload.md) watches `SpriteStudio_Source/` while the app runs: save in SpriteStudio and only the changed project is re-converted and pushed into the running app — no manual export step.

## Supported Versions

- **Flutter / Dart**: the minimum is on [Installation](./guide/install.md); `flutter pub get` fails if yours is older.
- **Platforms**: macOS, Windows, Linux, iOS, Android, and Web (developer preview).

## Samples

Sample apps live under the `examples/` folder in the repository; running one from a checkout is in the [Build Guide](development/build.md#running-from-a-checkout).

- [overall](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/overall) — comprehensive validation app.
- [flame](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/flame) — a `FlameGame` playing an animation via `ssplayer_flame`.
- [part_following](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/part_following) — a widget pinned to a part with `SpriteStudioPartAnchor`.

## Related Repositories

- [SpriteStudio Docs](https://cri-middleware.github.io/SpriteStudio-Docs/) — the documentation portal for the SDK and its official players.
- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — the SDK itself, providing `libssruntime` / `libssconverter`.
- [SSConverterGUI](https://github.com/cri-middleware/SSConverterGUI) — a standalone desktop GUI for converting `.sspj` without a player.

## License

See [License](license/index.md) for the full text and its Japanese reference translation, and
[Third-Party Notices](license/third-party.md) for the libraries it ships with (such as FlatBuffers and the
SpriteStudio-SDK's dependencies).

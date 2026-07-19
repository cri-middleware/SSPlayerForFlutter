# Customization & Automation

This section is for readers who go beyond "play a prebuilt `.ssab`". If you author your own
SpriteStudio projects, run conversion in a build pipeline, control how the native runtime is
delivered, or want a live edit-to-runtime loop, you are in the right place.

| I want to… | Go to |
|---|---|
| Prepare my own `.sspj` as a runtime `.ssab` — via a GUI, the browser, a CLI, or auto-import on save | [**Preparing Assets (`.sspj` → `.ssab`)**](conversion.md) |
| Understand / override how `libssruntime` reaches my app, or use the runtime from plain Dart | [**Native Runtime**](native-runtime.md) |
| See edits appear live while the app runs | [**Live Reload**](live-reload.md) |

!!! tip "Just embedding an animation?"
    If you only want to play an animation in an app, you can stay in the
    [For Users](../guide/install.md) section — none of the material here is required.

Everything in this section is desktop-tooling or build-time work; it does not add weight to your
shipped app. The player runtime itself stays converter-free.

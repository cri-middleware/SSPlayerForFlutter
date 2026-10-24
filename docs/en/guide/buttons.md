# 🔘 Buttons & UI States

Put an animation inside a Flutter button and have it show what the button is doing — hovered, pressed,
disabled, focused — and, for an irregular shape, take pointers on the artwork only. The widgets live in
their own library, so an app that only plays animations pays nothing for them:

```dart
import 'package:ssplayer_flutter/ui.dart';

final states = WidgetStatesController();

SpriteStudioHitRegion(              // optional: pointers on the `face` part only
  player: _player,
  parts: const ['face'],
  child: InkWell(
    statesController: states,
    onTap: _start,
    child: SpriteStudioStateView(
      player: _player,
      statesController: states,
      semanticLabel: 'Start',
    ),
  ),
)
```

Give the view the `statesController` the button takes — `InkWell` and every `ButtonStyleButton`
(`ElevatedButton`, `FilledButton`, …) accept one. The button keeps its role, its gestures and its
focus; the view only draws.

## Authoring the states

In one animation, put a label named after each state: `normal`, `hover`, `pressed`, `disabled`,
`focused` — lower case, matched exactly. A state plays from its label to the frame before the next
label (or to the end of the animation), looping.

| Button state (`WidgetState`) | Plays | Without that label |
|---|---|---|
| none of the below | `normal` | the whole animation |
| `hovered` | `hover` | `normal` |
| `pressed` | `pressed` | `hover`, then `normal` |
| `disabled` | `disabled` | `normal` |
| `focused` | `focused` | `normal` |

When several hold at once, one is shown: `disabled`, then `pressed`, `hover`, `focused`, and `normal`
when none does. `selected` and the other `WidgetState`s are not read. A change shows at once: the new
section starts from its first frame, and the section that was playing is dropped.

The labels are read from the animation the player has selected — load it with `animationName:`, or
name another with `animation:`.

## Using animations you already have

`clips` replaces the label of a state. States that fall back to it take the replacement too.

```dart
SpriteStudioStateView(
  player: _player,
  statesController: states,
  clips: const {
    SsUiState.normal: SsUiClip(animation: 'idle'),                 // the whole animation
    SsUiState.hover: SsUiClip(label: 'over'),                      // a label of the animation
    SsUiState.pressed: SsUiClip(animation: 'push', label: 'down'), // a label of another one
  },
)
```

A section a clip names runs to the frame before the next label as well. A clip naming an animation or a
label the pack does not have is reported once in the log, and the state plays as if it had no clip.

## Reduced motion

`reducedMotion` follows the platform's setting (`MediaQuery.disableAnimationsOf`) unless you pass it.
While it is on, each state holds the first frame of its section, and no user data, signal or audio
event fires.

If the animation has a `reduced_motion` label, `normal` — and the states that fall back to it — plays
that section instead, looping and with its events: a calm idle in place of a still one.

## Taking pointers on the artwork only

A button takes a pointer anywhere in its box, whatever its child does, so the narrowing goes **around
the button**: `SpriteStudioHitRegion` lets a tap or a hover through only where the player draws one of
`parts`, or any part when `parts` is null. It finds the view of that player below it and maps the point
into it, so the padding of an `ElevatedButton` does not throw it off.

What counts as a part's area is its outline as drawn — see
[A part's outline](part-following.md#a-parts-outline). Only pointers are narrowed: keyboard focus and a
screen reader's activation reach the button as before.

## Screen readers

Without a `semanticLabel` the view is decoration and adds nothing to the semantics tree. With one it is
read as an image with that label, as `Image.semanticLabel` is. The role and the action are the button's.

## The player

The view takes its player's playback over while it is mounted: it selects animations, sets the section
and the loop count, and plays and stops. Give each view a player of its own, as for `SpriteStudioView`.
Load the player as usual; the view shows the state once the pack is in, and again after a reload.

`SsUiStateDriver` is the same rule without the widget, for code outside the widget tree:

```dart
final driver = SsUiStateDriver(player);
driver.show(SsUiState.of(hovered: true));
driver.show(SsUiState.normal, reducedMotion: true);
```

## See also

- [Part Following](part-following.md) — the outlines the hit region tests, and the poses beside them
- [Playback & Events](playback.md) — playback sections, by frame and by label

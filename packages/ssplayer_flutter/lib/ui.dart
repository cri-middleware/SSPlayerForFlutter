/// SpriteStudio animations inside Flutter's buttons: a view that plays the
/// state of the button it sits in, and a region that lets the button take
/// pointers only on the artwork.
///
/// A separate library, so an app that only plays animations imports none of
/// it and pays nothing for it.
library;

export 'src/ui/hit_region.dart' show SpriteStudioHitRegion;
export 'src/ui/state_view.dart' show SpriteStudioStateView;
// The state rule depends on no widget, for an adapter outside the widget tree.
export 'src/ui/ui_state.dart' show SsUiClip, SsUiState, SsUiStateDriver;

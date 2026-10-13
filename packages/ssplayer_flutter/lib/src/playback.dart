/// Playback-shape enums shared by Layer 2 and Layer 3.
///
/// They live here rather than on the player so both layers can name them
/// without L2 having to import L3. Values match the Brain's wire numbers.
library;

/// Which way the playhead walks the animation.
enum SsPlaybackDirection {
  forward(0),
  backward(1);

  const SsPlaybackDirection(this.value);

  /// Wire value handed to the Brain.
  final int value;

  /// Resolves a Brain-supplied wire value, defaulting to [forward] for anything
  /// unrecognised (a newer Brain must not crash an older Body).
  static SsPlaybackDirection fromValue(int value) =>
      value == 1 ? backward : forward;
}

/// What happens when the playhead reaches the far end of the range.
enum SsPlaybackStyle {
  /// Jump back to the start (or stop, per the loop count).
  normal(0),

  /// Turn around and walk back, so one "loop" is a full round trip.
  pingPong(1);

  const SsPlaybackStyle(this.value);

  /// Wire value handed to the Brain.
  final int value;

  /// See [SsPlaybackDirection.fromValue].
  static SsPlaybackStyle fromValue(int value) =>
      value == 1 ? pingPong : normal;
}

/// How a track folds onto the pose the tracks below it produced.
enum SsTrackBlend {
  /// Lerp toward the track's pose by its alpha.
  mix(0),

  /// Add the track's offset from the setup pose, leaving what is below showing
  /// through — a breath or a recoil laid over any motion.
  additive(1);

  const SsTrackBlend(this.value);

  /// Wire value handed to the Brain.
  final int value;

  /// See [SsPlaybackDirection.fromValue].
  static SsTrackBlend fromValue(int value) => value == 1 ? additive : mix;
}

/// Where the animations laid on a track start.
enum SsTrackSync {
  /// From the head of their section.
  free(0),

  /// At the phase track 0's animation stands at, so a run laid over a walk
  /// keeps its stride. Matched once, when the animation is laid.
  start(1);

  const SsTrackSync(this.value);

  /// Wire value handed to the Brain.
  final int value;

  /// See [SsPlaybackDirection.fromValue].
  static SsTrackSync fromValue(int value) => value == 1 ? start : free;
}

/// Frame-accurate timeline events surfaced from the `.ssab` while playing
/// (design §6C). The Brain reports *which* events a frame crossed; the Body
/// decodes them from the pack and [SpriteStudioPlayer] dispatches each one to
/// `onUserData` / `onSignal` / `onAudio`.
///
/// These are the sibling players' `user_data` / `signal` / `audio` callbacks
/// (Godot / Unity), decoded into plain Dart so the FlatBuffers wire types never
/// leak into the public API.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// A **UserData** marker the animator placed on a part's timeline, surfaced as
/// playback crosses its frame. Every payload field is optional — a marker
/// carries whichever ones were authored (an integer, a rectangle, a point, a
/// string, or any combination).
@immutable
class SsUserData {
  const SsUserData({
    required this.partIndex,
    this.partName,
    this.frameNo = 0,
    this.integer,
    this.rect,
    this.point,
    this.string,
  });

  /// Index of the part carrying the marker (into the pack's `parts`).
  final int partIndex;

  /// Name of that part, or null when the pack has no name for it.
  final String? partName;

  /// The frame the key is **authored** on — not necessarily the frame it was
  /// noticed on, since one [SpriteStudioPlayer.advance] can step across several
  /// and fires every key in between.
  final int frameNo;

  /// The integer payload, or null if none was authored.
  final int? integer;

  /// The rectangle payload, or null if none was authored.
  final ui.Rect? rect;

  /// The point payload, or null if none was authored.
  final ui.Offset? point;

  /// The string payload, or null if none was authored.
  final String? string;

  @override
  String toString() => 'SsUserData(part: $partIndex, int: $integer, '
      'rect: $rect, point: $point, str: $string)';
}

/// A **Signal** event (SpriteStudio v7+) — a named command with typed
/// parameters. Only *active* signals are surfaced (an inactive one is skipped,
/// matching the sibling players).
@immutable
class SsSignal {
  const SsSignal({
    required this.partIndex,
    this.partName,
    this.frameNo = 0,
    required this.commandId,
    required this.params,
  });

  /// Index of the part carrying the signal.
  final int partIndex;

  /// Name of that part, or null when the pack has no name for it.
  final String? partName;

  /// The frame the key is **authored** on — not necessarily the frame it was
  /// noticed on, since one [SpriteStudioPlayer.advance] can step across several
  /// and fires every key in between.
  final int frameNo;

  /// The command identifier (empty string if the pack omitted it).
  final String commandId;

  /// The command parameters, in authored order.
  final List<SsSignalParam> params;

  @override
  String toString() =>
      'SsSignal(part: $partIndex, command: "$commandId", params: $params)';
}

/// One parameter of an [SsSignal]. [value] is the decoded union payload —
/// a `bool`, `int`, `double`, `String`, or null for a valueless parameter.
@immutable
class SsSignalParam {
  const SsSignalParam({required this.paramId, required this.value});

  /// The parameter identifier.
  final String paramId;

  /// The decoded value: `bool` | `int` | `double` | `String` | `null`.
  final Object? value;

  @override
  String toString() => 'SsSignalParam($paramId: $value)';
}

/// An **Audio** trigger. SpriteStudio audio is *trigger-only*: this hands you
/// the sound to play (by name and/or hash) plus its loop count, and your app
/// plays it with whatever audio stack it likes — the player never produces
/// sound itself (design §6C / §11).
@immutable
class SsAudioEvent {
  const SsAudioEvent({
    required this.partIndex,
    this.partName,
    this.frameNo = 0,
    required this.soundName,
    required this.soundNameHash,
    required this.soundListNameHash,
    required this.loopNum,
  });

  /// Index of the part carrying the audio trigger.
  final int partIndex;

  /// Name of that part, or null when the pack has no name for it.
  final String? partName;

  /// The frame the key is **authored** on — not necessarily the frame it was
  /// noticed on, since one [SpriteStudioPlayer.advance] can step across several
  /// and fires every key in between.
  final int frameNo;

  /// The sound's name, or null if the pack referenced it only by hash.
  final String? soundName;

  /// FNV hash of the sound name (0 if unset). Matches a `SoundList` entry.
  final int soundNameHash;

  /// FNV hash of the owning sound-list name (0 if unset).
  final int soundListNameHash;

  /// The **play count**: how many times to play the sound (`>= 1`).
  /// SpriteStudio audio has no infinite-loop concept — despite the name, this is
  /// a repeat count, not a loop flag (SDK `40_components/90_audio`). Playback is
  /// the app's job; honour this count in your own audio stack.
  final int loopNum;

  @override
  String toString() => 'SsAudioEvent(part: $partIndex, sound: "$soundName" '
      '(#$soundNameHash), loop: $loopNum)';
}

/// Signature for [SpriteStudioPlayer.onUserData].
typedef SsUserDataCallback = void Function(SsUserData userData);

/// Signature for [SpriteStudioPlayer.onSignal].
typedef SsSignalCallback = void Function(SsSignal signal);

/// Signature for [SpriteStudioPlayer.onAudio].
typedef SsAudioCallback = void Function(SsAudioEvent audio);

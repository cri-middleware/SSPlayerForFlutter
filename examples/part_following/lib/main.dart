import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

/// Part-following demo.
///
/// A marker widget is stuck to a part of the **Ringo** character with
/// [SpriteStudioPartAnchor], so it tracks that part's position / rotation /
/// scale every frame while the character moves. The player never owns the
/// marker: the app authors it (constraint-style), the player only supplies the
/// pose.
///
/// **The teaching point — skinned mesh parts are poor follow targets.** Ringo is
/// a rig with SKINNED (bone-bound) mesh parts: its hands, legs, ears and tail.
/// A skinned part's own transform stays near the character root while its art is
/// drawn by bone skinning, so following one snaps the marker to the root rather
/// than onto the visible mesh. In the follow-target picker,
/// skinned parts are listed but **disabled (dimmed)** so they
/// can't be picked by accident — yet a name typed by hand is still accepted (and
/// flagged with a non-blocking warning). The default target, `bone_14`, is a bone in the
/// right-hand chain — a bone / joint / NULL part is the recommended kind.
///
/// The one rule that makes it line up: the anchor must live in the SAME
/// coordinate space as the [SpriteStudioView] — here both sit inside one
/// transformed [Stack], so any nudge/scale moves them together.
///
/// API used (all on [SpriteStudioPlayer], read side of part overrides):
/// ```
///   partTransform(name) -> Matrix4?   // the widget SpriteStudioPartAnchor drives
///   isPartHidden(name)      -> bool
///   isPartSkinnedMesh(name) -> bool   // true for a bone-bound mesh part
///   findPartIndex(name)     -> int
///   partNames.names         -> List<String>   // every part in the pack
/// ```
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On the web the Brain is a wasm module fetched at runtime; await it before
  // the player is created. A no-op on native.
  await loadSsRuntime();
  runApp(const PartFollowingApp());
}

class PartFollowingApp extends StatelessWidget {
  const PartFollowingApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Part following',
        theme: ThemeData.dark(useMaterial3: true),
        home: const PartFollowingPage(),
      );
}

/// The Ringo pack — one `.ssab` holding every animation, plus its reference PNG.
/// Deployed (not committed) by `scripts/deploy-examples.sh`.
const String kPack = 'Ringo';

/// The part the marker sticks to on start. A bone in the right-hand chain — a
/// bone / joint / NULL part is the recommended kind of follow target (its node
/// moves with the art, unlike a skinned mesh).
const String kDefaultPart = 'bone_14';

/// Animations inside Ringo.ssab, offered as motion buttons (a curated subset of
/// the pack's many clips).
const List<String> kMotions = <String>[
  'wait1',
  'run',
  'attack1',
  'dance',
  'walk',
  'jump',
];

class PartFollowingPage extends StatefulWidget {
  const PartFollowingPage({super.key});

  @override
  State<PartFollowingPage> createState() => _PartFollowingPageState();
}

class _PartFollowingPageState extends State<PartFollowingPage>
    with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player;
  final TextEditingController _typed = TextEditingController(text: kDefaultPart);

  bool _loaded = false;
  String _error = '';

  // Follow state, re-applied to the anchor on every change.
  String _followPart = kDefaultPart;
  bool _attached = true;
  bool _driveScale = true; // follow scale too (else position + rotation only)
  SpriteStudioAnchorHidden _onHide = SpriteStudioAnchorHidden.followAlways;

  /// The live player — exposed so the widget test can query the pack.
  @visibleForTesting
  SpriteStudioPlayer get player => _player;

  @override
  void initState() {
    super.initState();
    _player = SpriteStudioPlayer(vsync: this);
    unawaited(_boot());
  }

  @override
  void dispose() {
    _typed.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      await _player.loadAsset('assets/spritestudio/$kPack/$kPack.ssab');
      if (!mounted) return;
      _player.setAnimation(kMotions.first);
      _player
        ..loopCount = -1
        ..play();
      setState(() => _loaded = true);
    } catch (e, st) {
      // ignore: avoid_print
      print('[part_following] FAILED: $e\n$st');
      if (mounted) setState(() => _error = '$e');
    }
  }

  bool get _known => _player.findPartIndex(_followPart) >= 0;
  bool get _skinned => _player.isPartSkinnedMesh(_followPart);

  void _setFollowPart(String name) {
    name = name.trim();
    if (name.isEmpty) return;
    setState(() => _followPart = name);
    if (_typed.text != name) _typed.text = name;
  }

  void _setMotion(String name) {
    _player
      ..setAnimation(name)
      ..play();
    setState(() {}); // refresh the active-button highlight
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12233B),
      body: _error.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Failed to start:\n$_error',
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            )
          : Stack(
              children: [
                // Clear of the readout above and the controls below, so the
                // fitted canvas lands between them.
                Positioned.fill(top: 140, bottom: 90, child: _stage()),
                _statusReadout(),
                if (_loaded) _picker(),
                if (_loaded) _controls(),
              ],
            ),
    );
  }

  /// The animation and the follower share ONE coordinate space: both are
  /// children of the same [Stack]. `StackFit.expand` makes the view fill, and
  /// it fits Ringo's canvas into that box; the anchor covers the same box via
  /// `Positioned.fill`, so it follows the part at the fitted size.
  Widget _stage() => Stack(
        fit: StackFit.expand,
        children: [
          SpriteStudioView(player: _player),
          if (_loaded && _attached)
            Positioned.fill(
              child: SpriteStudioPartAnchor(
                player: _player,
                partName: _followPart,
                scale: _driveScale,
                onHidden: _onHide,
                child: const _FollowMarker(),
              ),
            ),
        ],
      );

  // --- Status (top-left): what we are doing + the equivalent call + a live pull
  // read of the followed part's position, to show the read API directly. --------
  Widget _statusReadout() {
    final axes =
        _driveScale ? 'position + rotation + scale' : 'position + rotation';
    final step = !_loaded
        ? 'Loading…'
        : _attached
            ? 'Marker follows "$_followPart" — $kPack'
            : 'Detached — marker hidden ($kPack)';
    final call = _attached
        ? "SpriteStudioPartAnchor(partName: '$_followPart',\n"
            "  scale: $_driveScale, onHidden: ${_onHide.name})   // drives $axes"
        : '// no anchor mounted';

    return Positioned(
      left: 16,
      top: 16,
      right: 16,
      child: IgnorePointer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(step,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black)])),
            const SizedBox(height: 6),
            _pill(call),
            const SizedBox(height: 6),
            // The PULL side of the same API: re-read the pose each frame. The
            // player is a ChangeNotifier, so a ListenableBuilder rebuilds this
            // line right after every advance, when the world matrices are final.
            ListenableBuilder(
              listenable: _player,
              builder: (context, _) {
                final m = _player.partTransform(_followPart);
                final text = m == null
                    ? "partTransform('$_followPart') = null"
                    : "partTransform('$_followPart') @ "
                        '(${m.storage[12].toStringAsFixed(1)}, '
                        '${m.storage[13].toStringAsFixed(1)})';
                return _pill(text);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 13, color: Colors.white)),
      );

  // --- Follow-target picker (top-right). Skinned parts are listed but disabled,
  // a soft filter; the text box accepts any name. --------------------------------
  Widget _picker() {
    final names = _player.partNames.names.where((n) => n.isNotEmpty).toList();
    // The dropdown value must match one item; a hand-typed skinned part is still
    // in the list (as a disabled item), so it shows selected-but-dimmed.
    final value = names.contains(_followPart) ? _followPart : null;

    return Positioned(
      top: 16,
      right: 16,
      width: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Text('Follow target',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    isDense: true,
                    value: value,
                    underline: const SizedBox.shrink(),
                    dropdownColor: const Color(0xFF1B2C44),
                    hint: const Text('(typed)'),
                    items: [
                      for (final name in names)
                        _partItem(name, _player.isPartSkinnedMesh(name)),
                    ],
                    onChanged: (v) {
                      if (v != null) _setFollowPart(v);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _typed,
            textAlign: TextAlign.end,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Colors.black.withValues(alpha: 0.55),
              hintText: 'or type any part name',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
            ),
            onSubmitted: _setFollowPart,
          ),
          const SizedBox(height: 8),
          _warning(),
        ],
      ),
    );
  }

  DropdownMenuItem<String> _partItem(String name, bool skinned) =>
      DropdownMenuItem<String>(
        value: name,
        enabled: !skinned,
        child: Text(
          skinned ? '$name  (skinned — poor target)' : name,
          style: TextStyle(
              color: skinned ? Colors.white38 : Colors.white, fontSize: 13),
        ),
      );

  /// Non-blocking warning for a skinned part typed by hand.
  Widget _warning() {
    String? msg;
    if (!_known) {
      msg = '⚠ "$_followPart" is not a part of this pack — '
          'the marker is hidden until it resolves.';
    } else if (_skinned) {
      msg = '⚠ "$_followPart" is a skinned (bone-bound) mesh. Its transform '
          'stays near the character root, so the marker will not sit on the '
          'visible art. Follow a NULL / bone / joint part at that spot instead.';
    }
    if (msg == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x99502800),
        border: Border.all(color: const Color(0x66FFC864)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(msg,
          style: const TextStyle(
              color: Color(0xFFFFDF7E), fontSize: 12, height: 1.35)),
    );
  }

  // --- Controls (bottom): the same toggles the Web demo carries, plus the
  // motion buttons. No play/pause — the character always loops the motion. ------
  Widget _controls() {
    return Positioned(
      left: 16,
      bottom: 16,
      right: 16,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _toggle('Attach', _attached,
              () => setState(() => _attached = !_attached)),
          _toggle('Scale follow', _driveScale,
              () => setState(() => _driveScale = !_driveScale)),
          _toggle('onHide: hide',
              _onHide == SpriteStudioAnchorHidden.hideChild, () {
            setState(() => _onHide =
                _onHide == SpriteStudioAnchorHidden.followAlways
                    ? SpriteStudioAnchorHidden.hideChild
                    : SpriteStudioAnchorHidden.followAlways);
          }),
          const SizedBox(width: 8),
          for (final m in kMotions)
            _toggle(m, _player.currentAnimation == m, () => _setMotion(m)),
        ],
      ),
    );
  }

  Widget _toggle(String label, bool active, VoidCallback onTap) =>
      FilledButton.tonal(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor:
              active ? const Color(0x5978C8FF) : Colors.black.withValues(alpha: 0.4),
          foregroundColor: Colors.white,
          side: BorderSide(
              color: active ? const Color(0xCC78C8FF) : Colors.white24),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        child: Text(label),
      );
}

/// A little badge pinned to the part. Its own centre is placed on the part's
/// origin (the anchor pins the child's top-left, so shift it back by half).
class _FollowMarker extends StatelessWidget {
  const _FollowMarker();

  @override
  Widget build(BuildContext context) {
    return FractionalTranslation(
      translation: const Offset(-0.5, -0.5),
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x33FFC107),
          border: Border.all(color: const Color(0xFFFFC107), width: 3),
        ),
        child: const Icon(Icons.star, color: Color(0xFFFFC107), size: 22),
      ),
    );
  }
}

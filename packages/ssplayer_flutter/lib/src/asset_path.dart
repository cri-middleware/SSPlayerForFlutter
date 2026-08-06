/// Path joining for the two loaders that turn a `.ssab`'s own file references
/// into asset-bundle keys ([SsTextureLoader], [SsInstanceLoader]).
library;

/// Joins a reference authored *inside* a `.ssab` ([path] — a `cellmap.image_path`,
/// an instance pack name) onto an asset [base], producing the key the bundle is
/// asked for.
///
/// **Why the separators are folded.** ssconverter stores the file references
/// written in the `.sspj`/`.ss*e` **exactly as written** — no case and no
/// separator normalization (the SDK's `libs/ssruntime/docs/30_core/
/// 10_initialization.md` §3.0 states this as the contract every Body implements
/// against, so it is the Body's job, not the Brain's). A project authored with
/// Windows separators therefore hands us `image\body.png`, while Flutter asset
/// keys are forward-slash on *every* platform — they are `pubspec` entries
/// surfaced through `AssetManifest`, so a key holding a backslash matches
/// nothing, on Windows included. Unfolded, such a cellmap resolves to no
/// texture and the part simply stops drawing: a missing texture is collected
/// into a [TextureLoadReport], never thrown, so nothing says why.
///
/// **Why [base] is left alone.** It is the caller's own namespace rather than
/// pack-authored text, and for a dev-time file push (`ssgen_flutter`) or a
/// dropped folder it is a real host path whose backslashes — a UNC `\\host\share`
/// prefix above all — must survive intact. The mixed result that yields is fine:
/// `dart:io` on Windows takes either separator, and an asset-key base never
/// holds a backslash to begin with.
///
/// **Nothing here is re-hashed.** Embedded assets are matched on the Brain's
/// `cellmap.image_path_hash`, taken over the RAW text; fold on the way to a
/// bundle key only, or every embedded pack stops resolving.
String joinAssetPath(String base, String path) {
  final folded = path.replaceAll('\\', '/');
  final p = folded.startsWith('/') ? folded.substring(1) : folded;
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  // A derived base is empty for a root-level `.ssab`; joining must not prepend
  // a leading '/', which would miss the asset key.
  return b.isEmpty ? p : '$b/$p';
}

/// Parent directory of an asset key (`a/b/c.ssab` → `a/b`); `''` for a bare key
/// or one anchored at the root (`/c.ssab`).
///
/// Accepts either separator so a *host* path fed to a `dart:io`-backed bundle (a
/// dropped folder, a file picker returning a native path) still derives its own
/// folder instead of silently falling back to the bundle root — which would send
/// every sibling texture lookup somewhere else entirely. The separator found is
/// preserved in the result: this is the caller's namespace, so it stays a valid
/// host path (see [joinAssetPath] on why a base is never folded).
String assetDirOf(String assetKey) {
  final slash = assetKey.lastIndexOf('/');
  final backslash = assetKey.lastIndexOf('\\');
  final cut = slash > backslash ? slash : backslash;
  return cut <= 0 ? '' : assetKey.substring(0, cut);
}

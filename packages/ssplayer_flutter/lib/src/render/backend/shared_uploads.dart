/// What backends upload from an image, made once for every backend that draws
/// that image.
///
/// Players of one pack draw the same decoded atlas (`SharedImages`), yet every
/// backend read it back and uploaded a copy of its own: a 2 MB texture per
/// player for Ringo's atlas. Keyed on the image itself, the upload is shared,
/// and an image that changes — a runtime replacement, an atlas decoded afresh
/// after a reload — is another key with an upload of its own, so there is
/// nothing to evict when a registry starts handing out a different image.
///
/// An upload lives as long as its image object can be reached. Generic over
/// what an upload makes, so the sharing is testable without a GPU context, as
/// `TargetRing` and `UploadRing` are.
class SharedUploads<T extends Object> {
  final Expando<_Upload<T>> _uploads = Expando<_Upload<T>>('upload');

  /// What [key] uploaded to, or null while that is in flight. The first ask
  /// starts [upload]; once it lands, [onReady] runs for every distinct callback
  /// that asked in the meantime, so a backend that drew without it can draw
  /// again. An upload that fails or makes nothing is forgotten, and the next
  /// ask starts another.
  T? lookup(Object key, Future<T?> Function() upload, void Function() onReady) {
    final pending = _uploads[key];
    if (pending != null) {
      final made = pending.made;
      if (made == null) pending.waiters.add(onReady);
      return made;
    }
    final started = _Upload<T>()..waiters.add(onReady);
    _uploads[key] = started;
    upload().then((made) {
      if (made == null) {
        _uploads[key] = null;
        return;
      }
      started.made = made;
      final waiters = started.waiters.toList();
      started.waiters.clear();
      for (final ready in waiters) {
        ready();
      }
    }, onError: (Object _) {
      _uploads[key] = null;
    });
    return null;
  }
}

class _Upload<T extends Object> {
  T? made;
  final Set<void Function()> waiters = <void Function()>{};
}

import 'dart:typed_data';

/// The 4-byte FlatBuffers `file_identifier` the SDK converter stamps into every
/// `.ssab` (schema `file_identifier "SSAB"`). A finished, non-size-prefixed
/// FlatBuffers buffer stores it at bytes 4..8, right after the 4-byte root
/// offset.
const String ssabFileIdentifier = 'SSAB';

/// True when [bytes] begins with a well-formed `.ssab` FlatBuffers header: a
/// 4-byte root offset followed by the `"SSAB"` file identifier at bytes 4..8.
///
/// This mirrors Rust's `flatbuffers::buffer_has_identifier(buf, "SSAB", false)`
/// / the C++ `SsAnimeBinaryBufferHasIdentifier` — a reader-side helper the Dart
/// `flat_buffers` package does not provide, and `flatc` does not generate for
/// Dart, so it is implemented here.
///
/// It is a cheap *identify* check, NOT a structural validator: it rejects
/// truncated data, an empty buffer, and the wrong format (a `.ssqb` sequence
/// pack, a `.sspj`, a PNG, JSON) before they reach the Brain. It does **not**
/// prove the buffer is internally consistent — a pack that passes this check can
/// still be corrupt. See [assertSsabIdentifier] and the note on
/// `SsRuntime.createResourceCopy`.
bool hasSsabIdentifier(Uint8List bytes) {
  // 4 bytes root offset + 4 bytes identifier.
  if (bytes.length < 8) return false;
  for (var i = 0; i < 4; i++) {
    if (bytes[4 + i] != ssabFileIdentifier.codeUnitAt(i)) return false;
  }
  return true;
}

/// Throws a [FormatException] when [bytes] is not a `.ssab` FlatBuffers buffer
/// (see [hasSsabIdentifier]); returns normally otherwise.
///
/// The Brain parses `.ssab` **unchecked** and has documented undefined
/// behaviour on malformed input, so this guard runs before the bytes are handed
/// over. It only catches the common accidental cases (a truncated download, the
/// wrong file); it is not a defence against a deliberately-crafted malicious
/// pack — treat `.ssab` from untrusted sources as unsafe regardless.
void assertSsabIdentifier(Uint8List bytes) {
  if (!hasSsabIdentifier(bytes)) {
    throw FormatException(
      'not a .ssab buffer: expected the "$ssabFileIdentifier" FlatBuffers file '
      'identifier at bytes 4..8 (got ${bytes.length} bytes). The .ssab may be '
      'truncated, the wrong file, or a different format.',
    );
  }
}

import 'dart:convert';

/// A portable basename for files received from another device.
String safeFileName(String fileName) {
  final parts =
      fileName.split(RegExp(r'[\\/]+')).where((part) => part.trim().isNotEmpty);
  var name = parts.isEmpty
      ? 'file'
      : parts.last
          .replaceAll(RegExp(r'[<>:"|?*\x00-\x1F\x7F]'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = 'file';
  // Windows reserves these names even when they have an extension.
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)',
          caseSensitive: false)
      .hasMatch(name)) {
    name = '_$name';
  }
  // A byte limit also supports multibyte names on Linux/Android filesystems.
  const maxBytes = 180;
  if (utf8.encode(name).length <= maxBytes) return name;
  final dot = name.lastIndexOf('.');
  final extension = dot > 0 ? name.substring(dot) : '';
  if (extension.isNotEmpty && utf8.encode(extension).length <= 40) {
    return '${_truncateUtf8(name.substring(0, dot), maxBytes - utf8.encode(extension).length)}$extension';
  }
  return _truncateUtf8(name, maxBytes).replaceAll(RegExp(r'[. ]+$'), '');
}

String _truncateUtf8(String text, int maxBytes) {
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    bytes += utf8.encode(character).length;
    if (bytes > maxBytes) break;
    buffer.write(character);
  }
  return buffer.toString();
}

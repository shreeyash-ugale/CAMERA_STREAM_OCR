import 'dart:io';

/// Returns the first non-loopback IPv4 address found, or `null` if none.
Future<String?> detectLocalIp() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }
  } catch (_) {}
  return null;
}

/// Escapes newlines so SSE `data:` lines are not broken.
String sseEscape(String text) => text
    .replaceAll('\r\n', r'\n')
    .replaceAll('\r', r'\n')
    .replaceAll('\n', r'\n');

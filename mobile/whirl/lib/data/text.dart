import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Small text helpers shared by the screens (src/text.js in Dart), and dates in Algiers time.

/// Markdown down to one plain line, for the idea card.
String plainText(String? markdown) => (markdown ?? '')
    .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
    .replaceAll(RegExp(r'^\s*(#{1,6}|[-*+]|\d+\.)\s+', multiLine: true), '')
    .replaceAll(RegExp(r'[*_`]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// "now", "5h", "3d", "2mo", "1y" since [iso].
String relativeAge(String? iso, DateTime now) {
  final t = iso == null ? null : DateTime.tryParse(iso);
  if (t == null) return 'now';
  final minutes = now.difference(t).inSeconds / 60;
  if (minutes < 60) return 'now';
  if (minutes < 60 * 24) return '${(minutes / 60).floor()}h';
  if (minutes < 60 * 24 * 30) return '${(minutes / (60 * 24)).floor()}d';
  if (minutes < 60 * 24 * 365) return '${(minutes / (60 * 24 * 30)).floor()}mo';
  return '${(minutes / (60 * 24 * 365)).floor()}y';
}

/// Only web and mail links can be opened, so a stored "javascript:" can't do anything.
String? safeUrl(String url) {
  final u = url.trim();
  return RegExp(r'^(https?://|mailto:)', caseSensitive: false).hasMatch(u) ? u : null;
}

/// One link per line.
List<String> splitLinks(String? text) =>
    (text ?? '').split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

/// Every date is shown in Algiers time, whatever the phone is set to.
final tz.Location algiers = () {
  tzdata.initializeTimeZones();
  return tz.getLocation('Africa/Algiers');
}();

String _two(int n) => n.toString().padLeft(2, '0');

/// "17/11/2026 10:30", 24-hour, Algiers time. Empty when [iso] is not a date.
String formatDateTime(String? iso) {
  final t = iso == null ? null : DateTime.tryParse(iso);
  if (t == null) return '';
  final d = tz.TZDateTime.from(t, algiers);
  return '${_two(d.day)}/${_two(d.month)}/${d.year} ${_two(d.hour)}:${_two(d.minute)}';
}

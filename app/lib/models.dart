import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

/// Device id sent to the laptop. Conflicts are resolved by (updatedAt, device),
/// so it must match what the server compares against.
const kDevice = 'phone';

enum ItemKind { event, task, note }

final _dateFmt = DateFormat('yyyy-MM-dd');

String dateKey(DateTime d) => _dateFmt.format(d);
DateTime parseDateKey(String s) => DateTime.parse(s);

class Item {
  Item({
    String? id,
    required this.kind,
    this.title = '',
    this.body = '',
    this.date,
    this.startTime,
    this.endTime,
    this.done = false,
    this.color,
    this.remind,
    this.series,
    int? updatedAt,
    this.deleted = false,
    this.device = kDevice,
  })  : id = id ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  final ItemKind kind;
  String title;
  String body;
  String? date; // yyyy-MM-dd, null for notes
  String? startTime; // HH:mm
  String? endTime; // HH:mm
  bool done;
  String? color;
  int? remind; // minutes before startTime, null = no reminder
  String? series; // shared id of a repeating event's occurrences
  int updatedAt;
  bool deleted;
  String device;

  /// What lists show: the title, or the first line of the body when the title is empty.
  String get displayTitle {
    if (title.isNotEmpty) return title;
    final first = body.split('\n').first.trim();
    return first.isEmpty ? 'Без названия' : first;
  }

  /// Body text left after [displayTitle] took its first line.
  String get displaySubtitle => title.isNotEmpty ? body : body.split('\n').skip(1).join(' ').trim();

  /// True when this version should win over [other] (same rule as plannerd).
  bool isNewerThan(Item other) {
    if (updatedAt != other.updatedAt) return updatedAt > other.updatedAt;
    return device.compareTo(other.device) > 0;
  }

  void touch() {
    updatedAt = DateTime.now().millisecondsSinceEpoch;
    device = kDevice;
  }

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        id: j['id'] as String,
        kind: ItemKind.values.byName(j['kind'] as String),
        title: (j['title'] ?? '') as String,
        body: (j['body'] ?? '') as String,
        date: j['date'] as String?,
        startTime: j['start_time'] as String?,
        endTime: j['end_time'] as String?,
        done: j['done'] == true || j['done'] == 1,
        color: j['color'] as String?,
        remind: (j['remind'] as num?)?.toInt(),
        series: j['series'] as String?,
        updatedAt: (j['updated_at'] as num).toInt(),
        deleted: j['deleted'] == true || j['deleted'] == 1,
        device: (j['device'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'body': body,
        'date': date,
        'start_time': startTime,
        'end_time': endTime,
        'done': done,
        'color': color,
        'remind': remind,
        'series': series,
        'updated_at': updatedAt,
        'deleted': deleted,
        'device': device,
      };

  Map<String, Object?> toRow({required bool dirty}) => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'body': body,
        'date': date,
        'start_time': startTime,
        'end_time': endTime,
        'done': done ? 1 : 0,
        'color': color,
        'remind': remind,
        'series': series,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
        'device': device,
        'dirty': dirty ? 1 : 0,
      };

  Item copyWith({String? id, String? date, String? series}) => Item(
        id: id ?? this.id,
        kind: kind,
        title: title,
        body: body,
        date: date ?? this.date,
        startTime: startTime,
        endTime: endTime,
        done: done,
        color: color,
        remind: remind,
        series: series ?? this.series,
        updatedAt: updatedAt,
        deleted: deleted,
        device: device,
      );

  factory Item.fromRow(Map<String, Object?> r) => Item.fromJson(r.cast<String, dynamic>());
}

enum RepeatUnit { week, month }

/// [date] shifted by [steps] weeks or months; months clamp to the month's last day
/// (31 Jan + 1 month = 28/29 Feb). Same rule as plannerd.
String shiftDate(String date, RepeatUnit unit, int steps) {
  final d = parseDateKey(date);
  if (unit == RepeatUnit.week) {
    return dateKey(DateTime(d.year, d.month, d.day + 7 * steps));
  }
  final firstOfTarget = DateTime(d.year, d.month + steps, 1);
  final lastDay = DateTime(firstOfTarget.year, firstOfTarget.month + 1, 0).day;
  return dateKey(DateTime(firstOfTarget.year, firstOfTarget.month, d.day > lastDay ? lastDay : d.day));
}

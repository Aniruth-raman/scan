/// One entry in the scan history, mirroring Office Lens's `RecentEntry`.
class ScanEntry {
  const ScanEntry({
    this.id,
    required this.title,
    required this.kind,
    required this.filePath,
    this.thumbPath,
    required this.createdAt,
  });

  /// Row id from storage; null only before the entry is persisted.
  final int? id;

  /// Display name, e.g. "Scan 24 Oct 2026, 10:32".
  final String title;

  /// Either `image` or `pdf`.
  final String kind;

  /// Absolute path of the saved file.
  final String filePath;

  /// Absolute path of a small JPEG thumbnail, when one could be generated.
  final String? thumbPath;

  /// When the scan was captured/saved.
  final DateTime createdAt;

  bool get isPdf => kind == 'pdf';

  ScanEntry copyWith({int? id, String? title}) => ScanEntry(
        id: id ?? this.id,
        title: title ?? this.title,
        kind: kind,
        filePath: filePath,
        thumbPath: thumbPath,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'title': title,
        'kind': kind,
        'file_path': filePath,
        'thumb_path': thumbPath,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory ScanEntry.fromMap(Map<String, Object?> map) => ScanEntry(
        id: map['id'] as int?,
        title: map['title'] as String,
        kind: map['kind'] as String,
        filePath: map['file_path'] as String,
        thumbPath: map['thumb_path'] as String?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      );
}
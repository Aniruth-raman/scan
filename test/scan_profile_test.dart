import 'package:flutter_test/flutter_test.dart';
import 'package:scan/services/native_image_kit.dart';

void main() {
  test('the profile starts on the values Lens ships with', () {
    const profile = ScanProfile();
    // MediaCompression.low == 0.75, used as (int)(compression * 100).
    expect(profile.jpegQuality, 75);
    expect(profile.dpi, 300);
    expect(profile.pdfQuality, PdfQuality.high);
    expect(profile.filter, ScanFilter.none);
  });

  test('filter ids are the channel contract: stable, unique, in range', () {
    final ids = ScanFilter.values.map((filter) => filter.id).toList();
    expect(ids, <int>[0, 1, 2, 3, 4, 5, 6]);
    expect(ids.toSet().length, ids.length);
    // FILTER_* in ScanImageKit.kt only switches on 1..6.
    for (final id in ids) {
      expect(id, inInclusiveRange(0, 6));
    }
  });
}

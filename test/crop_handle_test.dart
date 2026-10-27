import 'package:flutter_test/flutter_test.dart';
import 'package:scan/screens/adjust_screen.dart';

void main() {
  // A square page, corners clockwise from top-left.
  const corners = <Offset>[
    Offset(0, 0),
    Offset(100, 0),
    Offset(100, 100),
    Offset(0, 100),
  ];

  test('a touch on a corner grabs that corner', () {
    expect(
      classifyDragHandle(corners, const Offset(0, 0)),
      (index: 0, isEdge: false),
    );
    expect(
      classifyDragHandle(corners, const Offset(100, 100)),
      (index: 2, isEdge: false),
    );
  });

  test('a touch on an edge midpoint grabs that whole edge', () {
    expect(
      classifyDragHandle(corners, const Offset(50, 0)),
      (index: 0, isEdge: true),
    );
    expect(
      classifyDragHandle(corners, const Offset(100, 50)),
      (index: 1, isEdge: true),
    );
    expect(
      classifyDragHandle(corners, const Offset(50, 100)),
      (index: 2, isEdge: true),
    );
    expect(
      classifyDragHandle(corners, const Offset(0, 50)),
      (index: 3, isEdge: true),
    );
  });

  test('an off-corner touch still grabs the nearer corner', () {
    final grab = classifyDragHandle(corners, const Offset(4, 3));
    expect(grab.isEdge, isFalse);
    expect(grab.index, 0);
  });
}

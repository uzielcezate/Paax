// test/widget/reorder_header_layout_test.dart — Phase 3.4.1.1 §A.
//
// Regression guard: in Edit Order mode the first reorderable row must render
// BELOW the fixed top bar (bar sits under the safe area). We reproduce the exact
// screen layout — a fixed bar of [kEditOrderBarHeight] beneath a simulated safe
// area, and a ReorderableListView padded via the production helper
// [editOrderListPadding] — and assert the first row's top is at or below the
// bar's bottom edge. If the padding formula regresses, the first row slides
// under the bar and this fails.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/presentation/screens/playlist_detail_screen.dart';

void main() {
  testWidgets('first reorder row starts below the fixed Edit Order bar',
      (tester) async {
    const safeTop = 50.0;
    final barKey = GlobalKey();

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(top: safeTop)),
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: ReorderableListView.builder(
                    padding: editOrderListPadding(safeTop),
                    itemCount: 5,
                    onReorder: (_, __) {},
                    itemBuilder: (_, i) => SizedBox(
                      key: ValueKey('row-$i'),
                      height: 56,
                      child: Text('Row $i'),
                    ),
                  ),
                ),
                // Fixed bar: safe-area spacer + the bar itself (mirrors screen).
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: safeTop),
                      SizedBox(
                        key: barKey,
                        height: kEditOrderBarHeight,
                        child: const Center(child: Text('Edit Order')),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final barBottom = tester.getBottomLeft(find.byKey(barKey)).dy;
    final firstRowTop = tester.getTopLeft(find.byKey(const ValueKey('row-0'))).dy;

    expect(barBottom, closeTo(safeTop + kEditOrderBarHeight, 0.5));
    expect(firstRowTop, greaterThanOrEqualTo(barBottom),
        reason: 'first row must not render under the fixed bar');
    // And specifically below by the intended gap.
    expect(firstRowTop, closeTo(barBottom + kEditOrderListGap, 0.5));
  });
}

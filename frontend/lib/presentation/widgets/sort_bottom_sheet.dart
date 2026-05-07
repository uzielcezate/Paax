import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/utils/dominant_color_service.dart';
import '../state/theme_state.dart';

class SortBottomSheet extends StatelessWidget {
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String title;

  const SortBottomSheet({
    super.key,
    required this.options, 
    required this.selectedIndex, 
    required this.onSelected,
    this.title = "Sort by",
  });

  @override
  Widget build(BuildContext context) {
    final themeState = context.watch<ThemeState>();
    final sheetBg = DominantColorService.adaptiveSheetColor(themeState.backgroundColor);
    final sheetFg = DominantColorService.foregroundOn(sheetBg);

    return Container(
      decoration: BoxDecoration(
        color: sheetBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40, height: 4,
                decoration: BoxDecoration(color: sheetFg.withOpacity(0.24), borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Text(title, style: TextStyle(color: sheetFg, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: options.length,
                itemBuilder: (context, index) {
                   final label = options[index];
                   return ListTile(
                     title: Text(label, style: TextStyle(color: sheetFg)),
                     trailing: index == selectedIndex ? Icon(Icons.check, color: sheetFg) : null,
                     onTap: () => onSelected(index),
                     contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                   );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

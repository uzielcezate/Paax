import 'package:flutter/material.dart';
import 'dart:ui';
import '../../core/theme/app_colors.dart';

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
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
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
                     title: Text(label, style: const TextStyle(color: Colors.white)),
                     trailing: index == selectedIndex ? const Icon(Icons.check, color: Colors.white) : null,
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

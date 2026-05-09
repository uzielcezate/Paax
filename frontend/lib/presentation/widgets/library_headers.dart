import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

class LibraryChipTabs extends StatelessWidget implements PreferredSizeWidget {
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;
  final List<String> tabs;

  const LibraryChipTabs({
    super.key,
    required this.selectedIndex,
    required this.onTabSelected,
    required this.tabs,
  });

  @override
  Size get preferredSize => const Size.fromHeight(72.0);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72.0,
      color: AppColors.background,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(bottom: 8), // Bottom spacing
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        primary: false,
        itemCount: tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final isSelected = selectedIndex == index;
          return GestureDetector(
            onTap: () => onTabSelected(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: isSelected ? Colors.white : Colors.white.withOpacity(0.05),
                border: isSelected ? null : Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              alignment: Alignment.center,
              child: Text(
                tabs[index],
                style: TextStyle(
                  color: isSelected ? Colors.black : Colors.white70,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class SearchSortHeaderDelegate extends SliverPersistentHeaderDelegate {
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSortPressed;
  final String currentSort;
  final Color? foregroundColor;

  SearchSortHeaderDelegate({
    required this.onSearchChanged,
    required this.onSortPressed,
    required this.currentSort,
    this.foregroundColor,
  });

  @override
  double get minExtent => 72.0; // Keep overall delegate height fixed for sliver if needed, OR adjust if dynamic. 
  // User reported "RenderFlex overflow", which usually happens INSIDE a fixed height widget when content is too big. 
  // The SliverDelegate itself defines extent. If the content inside overflows 72, then we have a problem. 
  // The user said: "Artists tab header area ... is causing a small overflow (~3.3 px)."
  // The delegate maxExtent is 72. The content is padding(v8) + height(48) = 16+48=64. 
  // If font scales, 48 might not be enough. 
  
  @override
  double get maxExtent => 72.0;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          color: Colors.white.withValues(alpha: 0.05),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center, // Ensure vertical centering
        children: [
          // Sort Button
          GestureDetector(
            onTap: onSortPressed,
            child: Container(
              constraints: const BoxConstraints(minHeight: 48), // Flexible height
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min, // Hug content
                children: [
                   Icon(Icons.sort_rounded, color: (foregroundColor ?? Colors.white).withValues(alpha: 0.7), size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Search Field
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 48), // Flexible height
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.centerLeft, // Align text field
              child: TextField(
                onChanged: onSearchChanged,
                style: TextStyle(color: foregroundColor ?? Colors.white),
                decoration: InputDecoration(
                  hintText: "Search...",
                  hintStyle: TextStyle(color: (foregroundColor ?? Colors.white).withValues(alpha: 0.38)),
                  prefixIcon: Icon(Icons.search, color: (foregroundColor ?? Colors.white).withValues(alpha: 0.38)),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 12), // Keep vertical padding
                  isDense: true, // Reduce internal height requirement
                ),
              ),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(SearchSortHeaderDelegate oldDelegate) {
    return oldDelegate.currentSort != currentSort;
  }
}

class SearchSortHeader extends StatelessWidget {
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSortPressed;
  final String currentSort;
  final Color? foregroundColor;

  const SearchSortHeader({
    super.key,
    required this.onSearchChanged,
    required this.onSortPressed,
    required this.currentSort,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          color: Colors.white.withValues(alpha: 0.05),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
          // Sort Button
          GestureDetector(
            onTap: onSortPressed,
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), // Added vertical padding for safety
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Row(
                 mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort_rounded, color: (foregroundColor ?? Colors.white).withValues(alpha: 0.7), size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Search Field
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.centerLeft,
              child: TextField(
                onChanged: onSearchChanged,
                style: TextStyle(color: foregroundColor ?? Colors.white),
                decoration: InputDecoration(
                  hintText: "Search...",
                  hintStyle: TextStyle(color: (foregroundColor ?? Colors.white).withValues(alpha: 0.38)),
                  prefixIcon: Icon(Icons.search, color: (foregroundColor ?? Colors.white).withValues(alpha: 0.38)),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                  isDense: true,
                ),
              ),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}

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
  Size get preferredSize => const Size.fromHeight(56.0);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56.0,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        primary: false,
        itemCount: tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final isSelected = selectedIndex == index;
          return GestureDetector(
            onTap: () => onTabSelected(index),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : AppColors.surface,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                tabs[index],
                style: TextStyle(
                  color: isSelected ? const Color(0xFF121212) : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
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
  double get minExtent => 64.0;
  
  @override
  double get maxExtent => 64.0;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return _SearchSortRow(
      onSearchChanged: onSearchChanged,
      onSortPressed: onSortPressed,
      foregroundColor: foregroundColor,
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
    return _SearchSortRow(
      onSearchChanged: onSearchChanged,
      onSortPressed: onSortPressed,
      foregroundColor: foregroundColor,
    );
  }
}

/// Shared layout for search bar + sort button using solid dark surface styling.
class _SearchSortRow extends StatelessWidget {
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSortPressed;
  final Color? foregroundColor;

  const _SearchSortRow({
    required this.onSearchChanged,
    required this.onSortPressed,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foregroundColor ?? Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Sort Button — solid dark surface
          GestureDetector(
            onTap: onSortPressed,
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Icon(Icons.sort_rounded, color: fg.withValues(alpha: 0.7), size: 20),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Search Field — solid dark surface
          Expanded(
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: TextField(
                  onChanged: onSearchChanged,
                  style: TextStyle(color: fg),
                  decoration: InputDecoration(
                    hintText: "Search...",
                    hintStyle: TextStyle(color: fg.withValues(alpha: 0.38)),
                    prefixIcon: Icon(Icons.search, color: fg.withValues(alpha: 0.38)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    isDense: true,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

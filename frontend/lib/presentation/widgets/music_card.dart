import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../../core/image/lh3_url_builder.dart';
import 'app_image.dart';

import '../../core/utils/string_utils.dart';

// Const shadow — avoids re-allocation on every card build during scroll
const _kCardShadow = [
  BoxShadow(
    color: Color(0x33000000), // Colors.black @ 20% opacity, compile-time const
    blurRadius: 8,
    offset: Offset(0, 4),
  ),
];

class MusicCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String imageUrl;
  final VoidCallback onTap;
  final double? width; // Nullable to allow external constraints or Responsive default
  final bool isCircle;

  const MusicCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.onTap,
    this.width,
    this.isCircle = false,
  });

  @override
  Widget build(BuildContext context) {
    final double cardWidth = (width ?? Responsive.value<double>(context, mobile: 140, tablet: 160, desktop: 200)).toDouble();
    
    // Disable tap if this is an artist card for a placeholder (e.g. "Various Artists")
    final isDisabled = isCircle && isPlaceholderArtist(title);

    return GestureDetector(
      onTap: isDisabled ? null : onTap,
      child: Container(
        width: cardWidth,
        margin: EdgeInsets.only(right: Responsive.spacing(context)),
        child: Column(
          crossAxisAlignment: isCircle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            // Image takes square space
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: isCircle ? BorderRadius.circular(100) : BorderRadius.circular(12),
                  boxShadow: _kCardShadow,
                ),
                child: AppImage(
                  url: imageUrl,
                  sizePx: Lh3UrlBuilder.listSize,
                  borderRadius: isCircle ? 0 : 12,
                  isCircular: isCircle,
                  fit: BoxFit.cover,
                  width: cardWidth,
                  height: cardWidth,
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Text area fills remaining space - Expanded prevents overflow
            Expanded(
              child: Column(
                crossAxisAlignment: isCircle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, 
                        fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(
                        color: AppColors.textSecondary, 
                        fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

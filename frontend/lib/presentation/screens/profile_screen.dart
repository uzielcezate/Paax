import '../widgets/thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../../data/local/hive_storage.dart';
import '../state/auth_controller.dart';
import '../state/library_controller.dart';
import '../state/playback_controller.dart'; // Added
import '../../domain/entities/track.dart'; // Added
import 'splash_screen.dart';
import '../widgets/bottom_content_padding.dart';
import '../widgets/section_header.dart'; // Added
import '../widgets/black_glass_blur_surface.dart'; // Added
import 'album_detail_screen.dart'; // Added
import '../../domain/entities/single_track_album_detail.dart'; // Added

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // We need to re-fetch Hive data on resume if needed, but for now just build time access is fine
  // as HiveStorage syncs.
  
  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().currentUser;
    final library = context.watch<LibraryController>();
    final history = HiveStorage.getRecentlyPlayed();
    
    // Compute minutes logic
    // If user.minutesListened > 0, use it. Else sum up history duration.
    // Assuming history tracks have duration.
    int minutes = user?.minutesListened.toInt() ?? 0;
    if (minutes == 0 && history.isNotEmpty) {
      final totalSeconds = history.fold(0, (sum, item) => sum + item.duration);
      minutes = totalSeconds ~/ 60;
    }
    
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
               const SizedBox(height: 20),
               // Header
               _buildHeader(user?.name, user?.email),
               
               const SizedBox(height: 24),
               
               // Plan Section
               _buildPlanSection(),
               
               const SizedBox(height: 16),

               // Stats Row
               Padding(
                 padding: const EdgeInsets.symmetric(horizontal: 20),
                 child: Row(
                   mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                   children: [
                     _buildStatItem("Liked", library.likedTracks.length.toString()),
                     _buildStatItem("Playlists", library.playlists.length.toString()),
                     _buildStatItem("Minutes", minutes.toString()),
                   ],
                 ),
               ),
               
               const SizedBox(height: 32),
               
               // Recently Played
               if (history.isNotEmpty) ...[
                 const Padding(
                   padding: EdgeInsets.symmetric(horizontal: 20),
                   child: SectionHeader(title: "Recently Played"),
                 ),
                 const SizedBox(height: 12),
                 SizedBox(
                   height: 155, // Increased from 140 to prevent overflow
                   child: ListView.builder(
                     padding: const EdgeInsets.only(left: 20),
                     scrollDirection: Axis.horizontal,
                     itemCount: history.length,
                     itemBuilder: (context, index) {
                       final track = history[index];
                       return _buildRecentCard(context, track);
                     },
                   ),
                 ),
                 const SizedBox(height: 32),
               ],
               
               // Settings
               Padding(
                 padding: const EdgeInsets.symmetric(horizontal: 20),
                 child: Column(
                   children: [
                      // Settings
                      _buildMenuItem("Settings", Icons.settings_outlined, () {}),
                      const SizedBox(height: 8),
                      // Clear Data
                      _buildMenuItem("Clear Data", Icons.delete_outline, () => _confirmClearData(context), isDestructive: true),
                      const SizedBox(height: 8),
                      // Logout
                      _buildMenuItem("Log out", Icons.logout, () {
                         context.read<AuthController>().logout();
                         Navigator.of(context).pushAndRemoveUntil(
                           MaterialPageRoute(builder: (_)=> const SplashScreen()),
                           (route) => false,
                         );
                      }),
                   ],
                 ),
               ),
               
               const BottomContentPadding(), 
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(String? name, String? email) {
    return Column(
      children: [
         Container(
           width: 90, height: 90,
           decoration: BoxDecoration(
             shape: BoxShape.circle,
             color: AppColors.surfaceLight,
             border: Border.all(color: AppColors.primaryStart, width: 2),
           ),
           child: const Icon(Icons.person, size: 45, color: Colors.white),
         ),
         const SizedBox(height: 12),
         Text(
           name ?? "Guest",
           style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
         ),
         if (email != null && email.isNotEmpty)
           Text(
             email,
             style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
           ),
      ],
    );
  }
  
  Widget _buildPlanSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      // Glass container logic if needed, or just container
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Plan: ", style: TextStyle(color: AppColors.textSecondary)),
              const Text("Premium", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [AppColors.primaryStart, AppColors.primaryEnd]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text("PRO", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 4),
        Text(label.toUpperCase(), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, letterSpacing: 1)),
      ],
    );
  }
  
  Widget _buildRecentCard(BuildContext context, Track track) {
    return GestureDetector(
      onTap: () {
          context.read<PlaybackController>().playTrack(track);
      },
      child: Container(
        width: 100, // Fixed width
        margin: const EdgeInsets.only(right: 12),
        // No explicit height, let children determine up to parent constraint
        child: Column(
          mainAxisSize: MainAxisSize.min, // Essential
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Thumbnail.list(
              url: track.artworkUrl,
              size: 100,
              borderRadius: 8,
            ),
            const SizedBox(height: 8),
            Text(
              track.title, 
              maxLines: 1, 
              overflow: TextOverflow.ellipsis, 
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)
            ),
            const SizedBox(height: 2), // Tighter spacing
            Text(
              track.artistName, 
              maxLines: 1, 
              overflow: TextOverflow.ellipsis, 
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildMenuItem(String title, IconData icon, VoidCallback onTap, {bool isDestructive = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            Icon(icon, color: isDestructive ? Colors.redAccent : Colors.white, size: 22),
            const SizedBox(width: 16),
            Expanded(child: Text(title, style: TextStyle(color: isDestructive ? Colors.redAccent : Colors.white, fontSize: 16, fontWeight: FontWeight.w500))),
            if (!isDestructive) const Icon(Icons.arrow_forward_ios, color: AppColors.textSecondary, size: 14),
          ],
        ),
      ),
    );
  }
  
  void _confirmClearData(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text("Clear Data?", style: TextStyle(color: Colors.white)),
        content: const Text("This will delete all your liked songs, playlists, and history.", style: TextStyle(color: Colors.grey)),
        actions: [
          TextButton(onPressed: ()=>Navigator.pop(context), child: const Text("Cancel")),
          TextButton(
            onPressed: () async {
              await context.read<AuthController>().logout(); 
               Navigator.of(context).pushAndRemoveUntil(
                     MaterialPageRoute(builder: (_)=> const SplashScreen()),
                     (route) => false,
                   );
            }, 
            child: const Text("Clear", style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    );
  }
}

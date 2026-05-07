import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/playlist.dart';
import '../state/library_controller.dart';
import '../state/theme_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/dominant_color_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'playlist_cover.dart';

class AddToPlaylistSheet extends StatelessWidget {
  final List<Track> tracks;

  const AddToPlaylistSheet({super.key, required this.tracks});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    final playlists = library.playlists;
    final themeState = context.watch<ThemeState>();
    final sheetBg = DominantColorService.adaptiveSheetColor(themeState.backgroundColor);
    final sheetFg = DominantColorService.foregroundOn(sheetBg);

    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: sheetBg, 
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: sheetFg.withOpacity(0.1), width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(color: sheetFg.withOpacity(0.24), borderRadius: BorderRadius.circular(2)),
          ),
          Text(
            "Add to Playlist",
            style: TextStyle(color: sheetFg, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: ContainerBox(icon: Icons.add, color: sheetFg),
            title: Text("New Playlist", style: TextStyle(color: sheetFg)),
            onTap: () => _showCreateDialog(context, library),
          ),
          Divider(color: sheetFg.withOpacity(0.1)),
          if (playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text("No playlists yet", style: TextStyle(color: sheetFg.withOpacity(0.5))),
            ),
          
          Expanded(
            child: ListView.builder(
              shrinkWrap: true,
              physics: const BouncingScrollPhysics(),
              itemCount: playlists.length,
              itemBuilder: (context, index) {
                final pl = playlists[index];
                // Only show check if adding a single track that is already in playlist
                final bool isSingle = tracks.length == 1;
                final alreadyAdded = isSingle && pl.tracks.any((t) => t.id == tracks.first.id);
                return ListTile(
                  leading: PlaylistCover(playlist: pl, size: 48),
                  title: Text(pl.name, style: TextStyle(color: sheetFg)),
                  subtitle: Text("${pl.tracks.length} tracks", style: TextStyle(color: sheetFg.withOpacity(0.54), fontSize: 12)),
                  trailing: alreadyAdded 
                      ? Icon(Icons.check, color: sheetFg)
                      : null,
                  onTap: () {
                    if (!alreadyAdded) {
                      library.addTracksToPlaylist(pl, tracks);
                      Navigator.pop(context); 
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("Added to ${pl.name}", style: TextStyle(color: sheetFg.withOpacity(0.54))),
                          backgroundColor: sheetBg,
                          behavior: SnackBarBehavior.floating,
                        )
                      );
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

//Es a partir de aqui lo del pop up

  void _showCreateDialog(BuildContext context, LibraryController library) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withOpacity(0.55),
      barrierDismissible: true,
      builder: (dialogContext) => Center(
        child: Material(
          type: MaterialType.transparency,
          child: AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text("New Playlist", style: TextStyle(color: Colors.white)),
            content: TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "Playlist name",
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
              ),
              TextButton(
                onPressed: () {
                  if (controller.text.isNotEmpty) {
                    library.createPlaylist(controller.text);
                    Navigator.of(dialogContext).pop();
                  }
                },
                child: const Text("Create", style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ContainerBox extends StatelessWidget {
  final IconData icon;
  final Color color;
  const ContainerBox({super.key, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48, height: 48,
      decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
      child: Icon(icon, color: color),
    );
  }
}

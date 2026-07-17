import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/playlist.dart';
import '../state/library_controller.dart';
import '../../core/theme/app_colors.dart';
import 'playlist_cover.dart';

class AddToPlaylistSheet extends StatelessWidget {
  final List<Track> tracks;

  const AddToPlaylistSheet({super.key, required this.tracks});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => _AddToPlaylistContent(
        tracks: tracks,
        scrollController: scrollController,
      ),
    );
  }
}

class _AddToPlaylistContent extends StatelessWidget {
  final List<Track> tracks;
  final ScrollController scrollController;

  const _AddToPlaylistContent({
    required this.tracks,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    final playlists = library.playlists;
    // Solid surface sheet — unified design
    const sheetBg = AppColors.surface;
    const sheetFg = Colors.white;
    final bottomSafe = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: sheetBg, 
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: const Border(top: BorderSide(color: Color(0xFF1A1A1A), width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF333333),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 8),
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
          const Divider(color: Color(0xFF1A1A1A)),
          if (playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text("No playlists yet", style: TextStyle(color: const Color(0xFF888888))),
            ),
          
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.only(bottom: bottomSafe + 24),
              itemCount: playlists.length,
              itemBuilder: (context, index) {
                final pl = playlists[index];
                final bool isSingle = tracks.length == 1;
                final alreadyAdded = isSingle && pl.tracks.any((t) => t.id == tracks.first.id);
                return ListTile(
                  leading: PlaylistCover(playlist: pl, size: 48),
                  title: Text(pl.name, style: TextStyle(color: sheetFg)),
                  subtitle: Text("${pl.tracks.length} tracks", style: const TextStyle(color: Color(0xFF888888), fontSize: 12)),
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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../state/auth_controller.dart';
import '../state/home_controller.dart';
import '../state/library_controller.dart';
import '../state/playback_controller.dart';
import '../../data/repositories/home_repository.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';
import '../../domain/entities/genre.dart';
import '../widgets/notification_bell.dart';
import '../widgets/section_header.dart';
import '../widgets/music_card.dart';
import '../widgets/error_state_widget.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'genre_results_screen.dart';
import 'profile_screen.dart';
import '../widgets/bottom_content_padding.dart';

/// Home — a personalized feed backed by REAL Supabase catalog data
/// (Phase 3.2.5). The screen layout, header, edge fades, horizontal card rails
/// and navigation are the pre-existing Paax ones; only the DATA behind the
/// sections changed from the old YouTube-derived charts to personalized,
/// deterministic catalog sections. Empty personalized sections are hidden.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    // Ensure a load happens once the tree is ready. The auth-driven proxy
    // usually triggers the first load already, so only load if it hasn't — this
    // avoids a duplicate fetch while still covering the cold-start case.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final home = context.read<HomeController>();
      if (!home.hasLoadedOnce && !home.isLoading) home.load();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Maps catalog [HomeAlbum]s into the existing [SavedAlbum] card model used by
  /// [_buildAlbumRow]. Albums without a Deezer id are dropped, because
  /// AlbumDetailScreen is keyed by the Deezer id — a card that can't open its
  /// detail should not be shown. AlbumDetailScreen re-resolves the artist from
  /// its own metadata fetch, so artistName can be empty here.
  List<SavedAlbum> _asSavedAlbums(List<HomeAlbum> albums) => albums
      .where((a) => a.deezerId != null && a.deezerId!.isNotEmpty)
      .map((a) => SavedAlbum(
            albumId: a.deezerId!,
            title: a.title,
            artistName: '',
            artworkUrl: a.artworkUrl ?? '',
          ))
      .toList();

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<AuthController>().profile;
    final firstName = profile?.firstName?.trim() ?? '';
    final userName = firstName.isNotEmpty
        ? firstName.split(RegExp(r'\s+')).first
        : (profile?.greetingName.trim().isNotEmpty ?? false)
            ? profile!.greetingName
            : 'there';

    final hour = DateTime.now().hour;
    String greeting = "Good morning";
    if (hour >= 12) greeting = "Good afternoon";
    if (hour >= 18) greeting = "Good evening";

    final home = context.watch<HomeController>();
    final library = context.watch<LibraryController>();

    final followedArtists = library.followedArtists;
    final followedGenres = library.followedGenres;

    // Personalized + global album sections (real catalog data). Each renders
    // only when it has content, so a new user sees only what actually exists.
    final newFromArtists = _asSavedAlbums(home.newFromArtists);
    final popularFromArtists = _asSavedAlbums(home.popularFromArtists);
    final recommended = _asSavedAlbums(home.recommended);
    final trending = _asSavedAlbums(home.trending);
    final recentlyAdded = _asSavedAlbums(home.recentlyAdded);

    final sections = <Widget>[
      if (followedArtists.isNotEmpty)
        _buildArtistRow(context, "Your artists", followedArtists),
      if (followedGenres.isNotEmpty)
        _buildGenreRow(context, "Your genres", followedGenres),
      if (newFromArtists.isNotEmpty)
        _buildAlbumRow(context, "New from your artists", newFromArtists),
      if (popularFromArtists.isNotEmpty)
        _buildAlbumRow(context, "Popular from your artists", popularFromArtists),
      if (recommended.isNotEmpty)
        _buildAlbumRow(context, "Recommended for you", recommended),
      if (trending.isNotEmpty)
        _buildAlbumRow(context, "Trending", trending),
      if (recentlyAdded.isNotEmpty)
        _buildAlbumRow(context, "Recently added", recentlyAdded),
    ];

    final showFirstLoad = home.isLoading && sections.isEmpty;
    final showError = home.error != null && sections.isEmpty && !home.isLoading;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => context.read<HomeController>().refresh(),
            color: Colors.white,
            backgroundColor: AppColors.surface,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                    child: SizedBox(height: MediaQuery.of(context).padding.top)),
                SliverToBoxAdapter(
                    child: _buildHeader(context, greeting, userName)),
                if (showFirstLoad)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(top: 80),
                      child: Center(
                          child: CircularProgressIndicator(color: Colors.white)),
                    ),
                  )
                else if (showError)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: ErrorStateWidget(
                        rawError: home.error,
                        onRetry: () => context.read<HomeController>().retry(),
                      ),
                    ),
                  )
                else ...[
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => sections[index],
                      childCount: sections.length,
                    ),
                  ),
                  const SliverToBoxAdapter(child: BottomContentPadding()),
                ],
              ],
            ),
          ),
          // ── Top edge fade ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: 120,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.background,
                      AppColors.background.withValues(alpha: 0.65),
                      AppColors.background.withValues(alpha: 0.25),
                      AppColors.background.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.35, 0.65, 1.0],
                  ),
                ),
              ),
            ),
          ),
          // ── Bottom edge fade ──
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                height:
                    context.read<PlaybackController>().currentTrack != null ? 240 : 160,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      AppColors.background.withValues(alpha: 0.96),
                      AppColors.background.withValues(alpha: 0.65),
                      AppColors.background.withValues(alpha: 0.25),
                      AppColors.background.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.35, 0.65, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String greeting, String userName) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "$greeting,",
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w400,
                    fontSize: 20),
              ),
              Text(
                userName,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 28),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const NotificationBell(),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () {
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const ProfileScreen()));
                },
                child: const CircleAvatar(
                  backgroundColor: AppColors.surfaceLight,
                  child: Icon(Icons.person, color: Colors.white),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  // ── Reusable horizontal rails (unchanged Paax visuals) ──────────────────

  Widget _buildAlbumRow(
      BuildContext context, String title, List<SavedAlbum> albums) {
    if (albums.isEmpty) return const SizedBox.shrink();
    final cardWidth =
        Responsive.value(context, mobile: 140.0, tablet: 160.0, desktop: 200.0);
    final cardHeight = cardWidth + 64;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            padding:
                EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            primary: false,
            itemCount: albums.length,
            itemBuilder: (context, index) {
              final album = albums[index];
              return MusicCard(
                width: cardWidth,
                title: album.title,
                subtitle: album.artistName,
                imageUrl: album.artworkUrl,
                onTap: () {
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => AlbumDetailScreen(album: album)));
                },
              );
            },
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildArtistRow(
      BuildContext context, String title, List<Artist> artists) {
    if (artists.isEmpty) return const SizedBox.shrink();
    final cardWidth =
        Responsive.value(context, mobile: 100.0, tablet: 120.0, desktop: 140.0);
    final cardHeight = cardWidth + 50;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            padding:
                EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            primary: false,
            itemCount: artists.length,
            itemBuilder: (context, index) {
              final artist = artists[index];
              return MusicCard(
                width: cardWidth,
                title: artist.name,
                subtitle: "Artist",
                imageUrl: artist.picture,
                isCircle: true,
                onTap: () {
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => ArtistDetailScreen(
                                artistId: artist.id,
                                artistName: artist.name,
                                pictureUrl: artist.picture,
                              )));
                },
              );
            },
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  /// Followed-genres rail — reuses the existing circular [MusicCard] and opens
  /// the existing [GenreResultsScreen] (no new screen).
  Widget _buildGenreRow(
      BuildContext context, String title, List<Genre> genres) {
    if (genres.isEmpty) return const SizedBox.shrink();
    final cardWidth =
        Responsive.value(context, mobile: 100.0, tablet: 120.0, desktop: 140.0);
    final cardHeight = cardWidth + 50;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            padding:
                EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            primary: false,
            itemCount: genres.length,
            itemBuilder: (context, index) {
              final genre = genres[index];
              return MusicCard(
                width: cardWidth,
                title: genre.name,
                subtitle: "Genre",
                imageUrl: genre.imageUrl ?? '',
                isCircle: true,
                onTap: () {
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => GenreResultsScreen(
                                genreSlug: genre.name,
                                gradientColors: _genreGradient(genre.name),
                              )));
                },
              );
            },
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  /// Deterministic dark gradient for a genre tile / header (no external data).
  List<Color> _genreGradient(String name) {
    const palettes = <List<Color>>[
      [Color(0xFF3A1C71), Color(0xFF181818)],
      [Color(0xFF1D4350), Color(0xFF181818)],
      [Color(0xFF4B1248), Color(0xFF181818)],
      [Color(0xFF16222A), Color(0xFF181818)],
      [Color(0xFF41295A), Color(0xFF181818)],
      [Color(0xFF334D50), Color(0xFF181818)],
    ];
    return palettes[name.hashCode.abs() % palettes.length];
  }
}

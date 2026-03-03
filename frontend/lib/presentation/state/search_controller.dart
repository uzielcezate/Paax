import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/repositories/music_repository.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart'; 

class SearchController extends ChangeNotifier {
  final MusicRepository _repository = MusicRepositoryImpl();
  
  String _query = '';
  // "all" is effectively handled by checking results for all types
  // But for simple Tab UI, we can keep a selected filter.
  // Requirement: Default to "All".
  
  List<Track> _trackResults = [];
  List<SavedAlbum> _albumResults = [];
  List<Artist> _artistResults = [];
  
  bool _isLoading = false;
  String? _error;
  Timer? _debounce;
  
  // Getters
  List<Track> get trackResults => _trackResults;
  List<SavedAlbum> get albumResults => _albumResults;
  List<Artist> get artistResults => _artistResults;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get query => _query;

  // We fetch ALL types simultaneously now.
  
  void onQueryChanged(String newQuery) {
    if (_query == newQuery) return;
    _query = newQuery;
    
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    
    if (newQuery.isEmpty) {
      _clearResults();
      return;
    }
    
    _isLoading = true; // Show loading immediately for better feedback
    notifyListeners();
    
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _performSearch();
    });
  }
  
  void _clearResults() {
    _trackResults = [];
    _albumResults = [];
    _artistResults = [];
    _isLoading = false;
    _error = null;
    notifyListeners();
  }
  
  Future<void> _performSearch() async {
    // Already loading
    _error = null;
    // notifyListeners(); already called in onQueryChanged if we want spinner to stay
    
    try {
      // Parallel execution
      final results = await Future.wait([
        _repository.searchTracks(_query),
        _repository.searchAlbums(_query),
        _repository.searchArtists(_query),
      ]);
      
      _trackResults = results[0] as List<Track>;
      _albumResults = results[1] as List<SavedAlbum>;
      _artistResults = results[2] as List<Artist>;
      
    } catch (e) {
      _error = e.toString();
      _trackResults = [];
      _albumResults = [];
      _artistResults = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}

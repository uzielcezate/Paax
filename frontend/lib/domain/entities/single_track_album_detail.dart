
import 'package:flutter/material.dart';
import '../../domain/entities/track.dart';

class SingleTrackAlbumDetail {
  final Track track;
  final String title;
  final String artistName;
  final String artworkUrl;
  final int duration;
  final int releaseYear;
  
  SingleTrackAlbumDetail({
    required this.track,
    required this.title,
    required this.artistName,
    required this.artworkUrl,
    required this.duration,
    required this.releaseYear,
  });
  
  factory SingleTrackAlbumDetail.fromTrack(Track track) {
    return SingleTrackAlbumDetail(
      track: track,
      title: track.title,
      artistName: track.artistName,
      artworkUrl: track.artworkUrl,
      duration: track.duration,
      releaseYear: 2024, // Fallback as track model lacks year
    );
  }
}

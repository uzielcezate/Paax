import 'package:hive/hive.dart';

part 'genre.g.dart';

@HiveType(typeId: 5)
class Genre extends HiveObject {
  @HiveField(0)
  final String id; // Deezer genre id as a String (the resolver key, mirrors Artist.id)

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String? imageUrl;

  @HiveField(3)
  final String? slug;

  @HiveField(4)
  final String? supabaseId; // Supabase genres.id UUID (for opening detail without re-resolve)

  Genre({
    required this.id,
    required this.name,
    this.imageUrl,
    this.slug,
    this.supabaseId,
  });
}

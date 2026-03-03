// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'artist.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ArtistAdapter extends TypeAdapter<Artist> {
  @override
  final int typeId = 4;

  @override
  Artist read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Artist(
      id: fields[0] as String,
      name: fields[1] as String,
      picture: fields[2] as String,
      nbFans: fields[3] as int,
      albums: (fields[4] as List).cast<dynamic>(),
      singles: (fields[5] as List).cast<dynamic>(),
      topTracks: (fields[6] as List).cast<dynamic>(),
      relatedArtists: (fields[7] as List).cast<Artist>(),
    );
  }

  @override
  void write(BinaryWriter writer, Artist obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.picture)
      ..writeByte(3)
      ..write(obj.nbFans)
      ..writeByte(4)
      ..write(obj.albums)
      ..writeByte(5)
      ..write(obj.singles)
      ..writeByte(6)
      ..write(obj.topTracks)
      ..writeByte(7)
      ..write(obj.relatedArtists);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtistAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

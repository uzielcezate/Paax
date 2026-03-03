// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'track.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class TrackAdapter extends TypeAdapter<Track> {
  @override
  final int typeId = 0;

  @override
  Track read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Track(
      id: fields[0] as String,
      title: fields[1] as String,
      artistName: fields[2] as String,
      albumId: fields[3] as String,
      albumTitle: fields[4] as String,
      artworkUrl: fields[5] as String,
      previewUrl: fields[6] as String?,
      duration: fields[7] as int,
      artists: (fields[9] as List?)
          ?.map((dynamic e) => (e as Map).cast<String, String>())
          ?.toList(),
    );
  }

  @override
  void write(BinaryWriter writer, Track obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.artistName)
      ..writeByte(3)
      ..write(obj.albumId)
      ..writeByte(4)
      ..write(obj.albumTitle)
      ..writeByte(5)
      ..write(obj.artworkUrl)
      ..writeByte(6)
      ..write(obj.previewUrl)
      ..writeByte(7)
      ..write(obj.duration)
      ..writeByte(9)
      ..write(obj.artists);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

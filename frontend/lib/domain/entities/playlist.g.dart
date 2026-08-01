// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'playlist.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PlaylistAdapter extends TypeAdapter<Playlist> {
  @override
  final int typeId = 1;

  @override
  Playlist read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Playlist(
      id: fields[0] as String,
      name: fields[1] as String,
      tracks: (fields[2] as List).cast<Track>(),
      createdAt: fields[3] as DateTime,
      coverColor: fields[4] as int?,
      ownerId: fields[5] as String?,
      ownerUsername: fields[6] as String?,
      visibility: fields[7] as String?,
      isCollaborative: fields[8] as bool?,
      collaboratorsJson: fields[9] as String?,
      trackPositions: (fields[10] as List?)?.cast<int>(),
    );
  }

  @override
  void write(BinaryWriter writer, Playlist obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.tracks)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.coverColor)
      ..writeByte(5)
      ..write(obj.ownerId)
      ..writeByte(6)
      ..write(obj.ownerUsername)
      ..writeByte(7)
      ..write(obj.visibility)
      ..writeByte(8)
      ..write(obj.isCollaborative)
      ..writeByte(9)
      ..write(obj.collaboratorsJson)
      ..writeByte(10)
      ..write(obj.trackPositions);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

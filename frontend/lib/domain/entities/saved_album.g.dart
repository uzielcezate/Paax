// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'saved_album.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SavedAlbumAdapter extends TypeAdapter<SavedAlbum> {
  @override
  final int typeId = 2;

  @override
  SavedAlbum read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SavedAlbum(
      albumId: fields[0] as String,
      title: fields[1] as String,
      artistName: fields[2] as String,
      artworkUrl: fields[3] as String,
      artistId: fields[4] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, SavedAlbum obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.albumId)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.artistName)
      ..writeByte(3)
      ..write(obj.artworkUrl)
      ..writeByte(4)
      ..write(obj.artistId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedAlbumAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

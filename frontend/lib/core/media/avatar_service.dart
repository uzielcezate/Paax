// lib/core/media/avatar_service.dart
//
// Picks an image from the gallery, validates MIME + size, resizes/re-encodes it
// to a small square JPEG, and uploads it to the public `user-avatars` Storage
// bucket under `{auth.uid()}/avatar_{ts}.jpg` (the path prefix RLS requires).
//
// Never uses the service-role key — only the app's authenticated anon client.
// Testable: inject an [ImagePicker] and [SupabaseClient].

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Friendly, user-safe failure. Never carries stack traces or PII.
class AvatarException implements Exception {
  final String message;
  const AvatarException(this.message);
  @override
  String toString() => message;
}

class AvatarService {
  final ImagePicker _picker;
  final SupabaseClient _client;

  /// Storage bucket (public, RLS-scoped to the first path folder == auth.uid()).
  static const String bucket = 'user-avatars';

  /// Max accepted source file size (~8MB).
  static const int maxSourceBytes = 8 * 1024 * 1024;

  /// Output square edge in pixels.
  static const int outputSize = 512;

  /// Accepted source extensions (defense-in-depth alongside decode validation).
  static const Set<String> _allowedExt = {'jpg', 'jpeg', 'png', 'webp'};
  static const Set<String> _allowedMime = {
    'image/jpg',
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  AvatarService({ImagePicker? picker, SupabaseClient? client})
      : _picker = picker ?? ImagePicker(),
        _client = client ?? Supabase.instance.client;

  /// Picks from the gallery, processes, uploads, and returns the new public URL.
  ///
  /// Returns `null` when the user cancels the picker. Throws [AvatarException]
  /// with a friendly message on any real failure.
  Future<String?> pickAndUpload() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) {
      throw const AvatarException('You must be signed in to change your photo.');
    }

    final XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: ImageSource.gallery,
        // Let package:image do the precise resize; this is just a soft cap.
        maxWidth: 2048,
        maxHeight: 2048,
      );
    } catch (_) {
      throw const AvatarException('Could not open your photo library.');
    }
    if (picked == null) return null; // user cancelled

    // ── Validate type ──────────────────────────────────────────────────────
    final ext = _extensionOf(picked.name.isNotEmpty ? picked.name : picked.path);
    final mime = picked.mimeType?.toLowerCase();
    final extOk = ext != null && _allowedExt.contains(ext);
    final mimeOk = mime == null || _allowedMime.contains(mime);
    if (!extOk || !mimeOk) {
      throw const AvatarException('Please choose a JPG, PNG, or WebP image.');
    }

    // ── Validate size ──────────────────────────────────────────────────────
    late final Uint8List bytes;
    try {
      final len = await picked.length();
      if (len > maxSourceBytes) {
        throw const AvatarException('That image is too large (max 8 MB).');
      }
      bytes = await picked.readAsBytes();
    } on AvatarException {
      rethrow;
    } catch (_) {
      throw const AvatarException('Could not read the selected image.');
    }
    if (bytes.length > maxSourceBytes) {
      throw const AvatarException('That image is too large (max 8 MB).');
    }

    // ── Decode / resize / re-encode ────────────────────────────────────────
    final Uint8List jpeg;
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw const AvatarException('That image could not be processed.');
      }
      // Center-crop to a square and resize to `outputSize` in one step.
      final square = img.copyResizeCropSquare(decoded, size: outputSize);
      jpeg = Uint8List.fromList(img.encodeJpg(square, quality: 85));
    } on AvatarException {
      rethrow;
    } catch (_) {
      throw const AvatarException('That image could not be processed.');
    }

    // ── Upload ─────────────────────────────────────────────────────────────
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = '$uid/avatar_$ts.jpg';
    try {
      await _client.storage.from(bucket).uploadBinary(
            path,
            jpeg,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'image/jpeg',
            ),
          );
    } catch (_) {
      throw const AvatarException('Upload failed. Check your connection and try again.');
    }

    // ── Best-effort cleanup of previous avatars ───────────────────────────
    await _deletePrevious(uid, keep: path);

    return _client.storage.from(bucket).getPublicUrl(path);
  }

  /// Removes older `avatar_*` objects in the user's folder, keeping [keep].
  /// Best-effort: never throws.
  Future<void> _deletePrevious(String uid, {required String keep}) async {
    try {
      final objects = await _client.storage.from(bucket).list(path: uid);
      final stale = <String>[];
      for (final o in objects) {
        if (!o.name.startsWith('avatar_')) continue;
        final full = '$uid/${o.name}';
        if (full == keep) continue;
        stale.add(full);
      }
      if (stale.isNotEmpty) {
        await _client.storage.from(bucket).remove(stale);
      }
    } catch (_) {
      // Non-fatal — orphaned objects can be reaped later.
    }
  }

  String? _extensionOf(String nameOrPath) {
    final dot = nameOrPath.lastIndexOf('.');
    if (dot < 0 || dot == nameOrPath.length - 1) return null;
    return nameOrPath.substring(dot + 1).toLowerCase();
  }
}

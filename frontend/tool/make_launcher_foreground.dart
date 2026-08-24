// tool/make_launcher_foreground.dart
//
// Derives the Android ADAPTIVE-ICON FOREGROUND from the shipped Paax logo.
//
// Run from `frontend/`:
//   dart run tool/make_launcher_foreground.dart
//
// WHY THIS EXISTS. An adaptive icon is a 108dp canvas of which only the centre
// 72dp is guaranteed to survive the launcher's mask — a circle mask inscribes a
// 72dp CIRCLE, so anything outside that circle can be cut off. `paaxlogo.png`
// is a full-bleed square: the wave spans ~60% of its width and sits on the
// logo's own background, so using it directly as the foreground puts the ends
// of the wave right at (and past) the circular mask's edge.
//
// So the foreground is the SAME artwork, untouched: the mark is copied
// pixel-for-pixel, scaled UNIFORMLY (never stretched), never recoloured,
// re-drawn or cropped, and centred on a transparent canvas so its bounding box
// fits comfortably inside the safe circle. The logo's own background colour
// becomes the adaptive BACKGROUND layer, so the composed icon looks exactly
// like the asset — it just cannot be clipped.
//
// Output: assets/logo/paaxlogo_foreground.png (committed, so a normal
// `flutter_launcher_icons` run needs no image tooling).

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// Fraction of the FINAL icon the mark's bounding-box DIAGONAL may occupy.
/// The guaranteed-safe circle is 72/108 = 0.667 of the canvas; 0.60 leaves a
/// deliberate margin for the tighter masks some launchers apply.
const double kSafeDiagonal = 0.60;

/// The inset flutter_launcher_icons writes into
/// `mipmap-anydpi-v26/ic_launcher.xml` (`<inset android:inset="16%">`), applied
/// to EACH edge. The foreground drawable is therefore rendered at 1 - 2×0.16 of
/// the icon canvas, and this file must be authored pre-inset or the mark ends
/// up ~40% of the icon instead of the intended 60%. Keep in sync with that XML.
const double kPluginInsetPerEdge = 0.16;

/// Adaptive icons are authored at 108dp; 432px is the xxxhdpi rendering, and
/// flutter_launcher_icons downsamples from there.
const int kCanvas = 1024;

void main() {
  final srcFile = File('assets/logo/paaxlogo.png');
  final src = img.decodePng(srcFile.readAsBytesSync());
  if (src == null) {
    stderr.writeln('could not decode ${srcFile.path}');
    exit(1);
  }

  // The background colour is whatever the artwork's own corner is.
  final bg = src.getPixel(0, 0);
  final bgHex = '#${_hex(bg.r)}${_hex(bg.g)}${_hex(bg.b)}';

  // Bounding box of everything that is NOT the background.
  var minX = src.width, minY = src.height, maxX = -1, maxY = -1;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      final d = (p.r - bg.r).abs() + (p.g - bg.g).abs() + (p.b - bg.b).abs();
      if (d < 24) continue; // background (tolerant of PNG noise)
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) {
    stderr.writeln('no mark found — is the logo a solid colour?');
    exit(1);
  }

  final markW = maxX - minX + 1;
  final markH = maxY - minY + 1;
  final mark = img.copyCrop(src, x: minX, y: minY, width: markW, height: markH);

  // ONE uniform scale factor for both axes — the mark's proportions are never
  // altered — chosen so its diagonal fits the safe circle.
  final diagonal = math.sqrt(markW * markW + markH * markH);
  final visible = 1 - 2 * kPluginInsetPerEdge; // what the inset leaves visible
  final targetDiagonal = kSafeDiagonal / visible; // authored pre-inset
  final scale = (targetDiagonal * kCanvas) / diagonal;
  final outW = math.max(1, (markW * scale).round());
  final outH = math.max(1, (markH * scale).round());
  final scaled = img.copyResize(mark,
      width: outW, height: outH, interpolation: img.Interpolation.cubic);

  // Transparent canvas: the background layer is a flat colour, so the mask can
  // never reveal a hard edge of the artwork.
  final canvas = img.Image(width: kCanvas, height: kCanvas, numChannels: 4);
  img.fill(canvas, color: img.ColorRgba8(0, 0, 0, 0));
  img.compositeImage(canvas, _asAlpha(scaled, bg),
      dstX: ((kCanvas - outW) / 2).round(),
      dstY: ((kCanvas - outH) / 2).round());

  File('assets/logo/paaxlogo_foreground.png')
      .writeAsBytesSync(img.encodePng(canvas));

  stdout.writeln('source      : ${src.width}x${src.height}');
  stdout.writeln('background  : $bgHex');
  stdout.writeln('mark bbox   : ${markW}x$markH at ($minX,$minY)');
  stdout.writeln('scaled to   : ${outW}x$outH on ${kCanvas}x$kCanvas'
      ' (${(diagonal * scale / kCanvas * 100).toStringAsFixed(1)}% diagonal'
      ' pre-inset)');
  stdout.writeln('after inset : '
      '${(diagonal * scale / kCanvas * visible * 100).toStringAsFixed(1)}%'
      ' of the launcher icon — safe limit ${(kSafeDiagonal * 100).round()}%,'
      ' guaranteed-visible circle 66.7%');
  stdout.writeln('wrote       : assets/logo/paaxlogo_foreground.png');
  stdout.writeln('\nSet adaptive_icon_background to $bgHex in pubspec.yaml.');
}

/// Replaces the artwork's flat background with transparency, keeping the mark's
/// own pixels (and its anti-aliased edges) exactly as drawn.
img.Image _asAlpha(img.Image src, img.Pixel bg) {
  final out = img.Image(width: src.width, height: src.height, numChannels: 4);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      // Distance from the background, normalised, IS the coverage of the mark —
      // which keeps the original anti-aliasing instead of hard-thresholding it.
      final d = ((p.r - bg.r).abs() + (p.g - bg.g).abs() + (p.b - bg.b).abs()) /
          (255 * 3);
      final coverage = (d * 3).clamp(0.0, 1.0);
      out.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(),
          (coverage * 255).round());
    }
  }
  return out;
}

String _hex(num v) => v.toInt().toRadixString(16).padLeft(2, '0').toUpperCase();

import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;

typedef LogFn = void Function(String);

/// Thin wrapper around FFprobe/FFmpeg for a single-file H.264 + AAC re-encode.
class VideoProcessor {
  VideoProcessor();

  // ---- Logging -------------------------------------------------------------

  void _log(String msg) {
    // print(msg);
  }

  // ---- Utilities -----------------------------------------------------------

  /// Quotes a path safely for the shell invocation FFmpegKit builds internally.
  String _quote(String s) => '"${s.replaceAll('"', r'\"')}"';

  /// If [candidatePath] already exists, keep appending `_tmp` (recursively)
  /// before the extension until it doesn't.
  Future<String> _uniqueOutPath(String candidatePath) async {
    var path = candidatePath;
    while (await File(path).exists()) {
      final dir = p.dirname(path);
      final ext = p.extension(path);
      final base = p.basenameWithoutExtension(path);
      path = p.join(dir, '${base}_tmp$ext');
    }
    return path;
  }

  /// Probe audio codec name (e.g. "aac", "mp3", "opus"). Returns null if unknown.
  Future<String?> _probeAudioCodecName(File input) async {
    _log('FFprobe: probing audio codec → ${input.path}');
    try {
      final session = await FFprobeKit.getMediaInformation(input.path);
      final info = session.getMediaInformation();
      final streams = info?.getStreams();
      if (streams == null) return null;

      for (final s in streams) {
        if (s.getType() == 'audio') {
          final props = s.getAllProperties();
          final codec = (props?['codec_name'] ?? props?['codec_tag_string'])
              ?.toString()
              .toLowerCase()
              .trim();
          if (codec != null && codec.isNotEmpty) return codec;
        }
      }
    } catch (e) {
      _log('FFprobe audio probe error: $e');
    }
    return null;
  }

  List<String> _buildCmd({
    required File input,
    required String outPath,
    required bool toTemp,
    required int targetCrf,
    required bool copyAudio,
  }) {
    // NOTE: We intentionally do NOT set `-r`. FFmpeg will preserve the
    // source timing/frame-rate using input timestamps by default.
    return <String>[
      '-y',
      '-i',
      _quote(input.path),

      // Video
      '-c:v',
      'libx264',
      '-preset',
      'medium',
      '-crf',
      targetCrf.toString(),
      '-pix_fmt',
      'yuv420p',

      // Audio
      if (copyAudio) ...[
        '-c:a',
        'copy',
      ] else ...[
        '-c:a',
        'aac',
        '-b:a',
        '192k', // better quality + safer fallback than 128k
      ],

      // Container flags
      '-movflags',
      '+faststart',
      if (toTemp) ...['-f', 'mp4'],
      _quote(outPath),
    ];
  }

  Future<dynamic> _runFfmpeg(List<String> cmd) async {
    final cmdStr = cmd.join(' ');
    _log('FFmpeg: $cmdStr');
    return FFmpegKit.executeAsync(cmdStr);
  }

  bool _isAacCodec(String? codec) {
    final c = codec?.toLowerCase().trim();
    return c == 'aac';
  }

  // ---- Public API ----------------------------------------------------------

  Future<({dynamic session, String outPath})> reencodeH264AacAsync(
    File input, {
    required String outputDirPath,
    required String labelSuffix,
    int targetCrf = 23,
  }) async {
    final stem = p.basenameWithoutExtension(input.path);

    final toTemp = labelSuffix.trim().isEmpty;
    final initialOutPath = toTemp
        ? p.join(outputDirPath, '${stem}_squeeze_tmp.mp4')
        : p.join(outputDirPath, '$stem$labelSuffix.mp4');

    final outPath = await _uniqueOutPath(initialOutPath);

    // Detect audio codec
    final audioCodec = await _probeAudioCodecName(input);
    final audioIsAac = _isAacCodec(audioCodec);

    // Strategy:
    // - If audio is AAC => try copy first, fallback to re-encode AAC if needed.
    // - If audio is NOT AAC/unknown => go straight to AAC re-encode (more reliable),
    //   but still safe for MP4 output.
    if (audioIsAac) {
      // 1) Try audio copy
      var cmd = _buildCmd(
        input: input,
        outPath: outPath,
        toTemp: toTemp,
        targetCrf: targetCrf,
        copyAudio: true,
      );

      var session = await _runFfmpeg(cmd);
      final rc = await session.getReturnCode();

      if (ReturnCode.isSuccess(rc)) {
        return (session: session, outPath: outPath);
      }

      // 2) Fallback: delete any partial output, then re-encode audio to AAC
      try {
        final f = File(outPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}

      cmd = _buildCmd(
        input: input,
        outPath: outPath,
        toTemp: toTemp,
        targetCrf: targetCrf,
        copyAudio: false,
      );

      session = await _runFfmpeg(cmd);
      return (session: session, outPath: outPath);
    } else {
      // Non-AAC (or unknown): re-encode audio to AAC directly
      final cmd = _buildCmd(
        input: input,
        outPath: outPath,
        toTemp: toTemp,
        targetCrf: targetCrf,
        copyAudio: false,
      );

      final session = await _runFfmpeg(cmd);
      return (session: session, outPath: outPath);
    }
  }
}

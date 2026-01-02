import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class VideoProcessor {
  static const String squeezeTag = 'compressed-by:squeeze';

  void _log(String msg) {
    // print(msg);
  }

  String _quote(String s) => '"${s.replaceAll('"', r'\"')}"';

  Future<Directory> _getTempDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'squeeze_encode_tmp'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Returns true if this video was already compressed by Squeeze (metadata marker).
  /// We check multiple common tag fields because containers differ.
  Future<bool> isAlreadyCompressedBySqueeze(File input) async {
    try {
      final session = await FFprobeKit.getMediaInformation(input.path);
      final info = session.getMediaInformation();
      final tags = info?.getTags();
      if (tags == null) return false;

      bool containsTag(dynamic v) {
        final s = v?.toString().toLowerCase();
        return s != null && s.contains(squeezeTag);
      }

      // Common tag keys seen across containers
      if (containsTag(tags['comment'])) return true;
      if (containsTag(tags['description'])) return true;
      if (containsTag(tags['title'])) return true;
      if (containsTag(tags['encoder'])) return true;

      return false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _probeAudioProps(File input) async {
    try {
      final session = await FFprobeKit.getMediaInformation(input.path);
      final info = session.getMediaInformation();
      final streams = info?.getStreams();
      if (streams == null) return {};

      for (final s in streams) {
        if (s.getType() == 'audio') {
          final props = s.getAllProperties() ?? {};
          return {
            'channels': props['channels'],
            'sample_rate': props['sample_rate'],
          };
        }
      }
    } catch (_) {}
    return {};
  }

  String _inputExt(File input) {
    final ext = p.extension(input.path).toLowerCase();
    return ext.isEmpty ? '.mp4' : ext;
  }

  /// Adds multiple metadata keys to maximize survival across containers.
  List<String> _metadataTagArgs() {
    return <String>[
      '-metadata',
      'comment=$squeezeTag',
      '-metadata',
      'description=$squeezeTag',
      '-metadata',
      'title=$squeezeTag',
      // encoder is commonly surfaced by tools; harmless if ignored
      '-metadata',
      'encoder=squeeze',
    ];
  }

  List<String> _buildCmd({
    required File input,
    required String outPath,
    required String ext,
    required int targetCrf,
    required Map<String, dynamic> audioProps,
  }) {
    final cmd = <String>[
      '-y',
      '-i',
      _quote(input.path),

      // ✅ Tag outputs so we never re-compress
      ..._metadataTagArgs(),
    ];

    final bool isWebm = ext == '.webm';

    if (isWebm) {
      // WEBM container: VP9 + Opus is the sane default.
      cmd.addAll([
        '-c:v',
        'libvpx-vp9',
        '-crf',
        '27',
        '-b:v',
        '0',
        '-c:a',
        'libopus',
        '-b:a',
        '160k',
      ]);
    } else {
      // Most other containers: H.264 + AAC
      cmd.addAll([
        '-c:v',
        'libx264',
        '-preset',
        'medium',
        '-crf',
        targetCrf.toString(),
        '-pix_fmt',
        'yuv420p',

        // ✅ Always re-encode audio (AAC is inherently lossy; we mitigate w/ bitrate)
        '-c:a',
        'aac',
        '-b:a',
        '256k',
      ]);

      if (audioProps['channels'] != null) {
        cmd.addAll(['-ac', audioProps['channels'].toString()]);
      }
      if (audioProps['sample_rate'] != null) {
        cmd.addAll(['-ar', audioProps['sample_rate'].toString()]);
      }

      // For MP4/MOV: faststart helps playback.
      if (ext == '.mp4' || ext == '.m4v' || ext == '.mov') {
        cmd.addAll(['-movflags', '+faststart']);
      }

      // Some containers don’t like global metadata unless you force it:
      // Keeping it simple for now; FFmpeg will ignore unsupported tags.
    }

    // Let muxer infer from extension
    cmd.add(_quote(outPath));
    return cmd;
  }

  Future<({dynamic session, File tempFile, String ext})>
      encodeToTempSameContainer(
    File input, {
    int targetCrf = 28,
  }) async {
    final tempDir = await _getTempDir();
    final ext = _inputExt(input);
    final base = p.basenameWithoutExtension(input.path);

    final tempPath = p.join(
      tempDir.path,
      '${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
    );

    final audioProps = await _probeAudioProps(input);

    final cmd = _buildCmd(
      input: input,
      outPath: tempPath,
      ext: ext,
      targetCrf: targetCrf,
      audioProps: audioProps,
    );

    _log('FFmpeg: ${cmd.join(' ')}');
    final session = await FFmpegKit.executeAsync(cmd.join(' '));
    return (session: session, tempFile: File(tempPath), ext: ext);
  }

  Future<bool> isSmallerThanOriginal(File input, File temp) async {
    try {
      return (await temp.length()) < (await input.length());
    } catch (_) {
      return false;
    }
  }

  Future<int> safeLength(File f) async {
    try {
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> discardTemp(File f) async {
    try {
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }
}

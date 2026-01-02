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

  /// Read container/global tags via FFprobe and return a lowercase-keyed map.
  Future<Map<String, String>> _readTags(File input) async {
    try {
      final session = await FFprobeKit.getMediaInformation(input.path);
      final info = session.getMediaInformation();
      final tags = info?.getTags();
      if (tags == null) return const {};

      final out = <String, String>{};
      for (final e in tags.entries) {
        final k = e.key.toString().toLowerCase();
        final v = e.value?.toString();
        if (v != null && v.trim().isNotEmpty) {
          out[k] = v;
        }
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Append [squeezeTag] to an existing tag value without overwriting it.
  /// Avoid duplicates and keep it readable.
  String _appendSqueezeTag(String? existing) {
    final cur = (existing ?? '').trim();

    // Already contains tag -> keep as-is.
    if (cur.toLowerCase().contains(squeezeTag)) return cur;

    // If empty -> just the tag.
    if (cur.isEmpty) return squeezeTag;

    // Choose a separator that tends to survive metadata round-trips.
    // " | " is readable and common.
    return '$cur | $squeezeTag';
  }

  /// Builds -metadata args for multiple fields, preserving existing values
  /// and appending our marker.
  Future<List<String>> _metadataTagArgsPreserve(File input) async {
    final tags = await _readTags(input);

    // FFprobe keys are often lowercase; normalize lookup.
    final existingComment = tags['comment'];
    final existingDescription = tags['description'];
    final existingTitle = tags['title'];
    final existingEncoder = tags['encoder'];

    final commentOut = _appendSqueezeTag(existingComment);
    final descriptionOut = _appendSqueezeTag(existingDescription);
    final titleOut = _appendSqueezeTag(existingTitle);

    return <String>[
      '-metadata',
      'comment=$commentOut',
      '-metadata',
      'description=$descriptionOut',
    ];
  }

  List<String> _buildCmd({
    required File input,
    required String outPath,
    required String ext,
    required int targetCrf,
    required Map<String, dynamic> audioProps,
    required List<String> metadataArgs,
  }) {
    final cmd = <String>[
      '-y',
      '-i',
      _quote(input.path),

      // ✅ Tag outputs so we never re-compress (preserving existing metadata)
      ...metadataArgs,
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

      if (ext == '.mp4' || ext == '.m4v' || ext == '.mov') {
        cmd.addAll(['-movflags', '+faststart']);
      }
    }

    cmd.add(_quote(outPath));
    return cmd;
  }

  Future<({dynamic session, File tempFile, String ext})> encodeToTempSameContainer(
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

    // ✅ Read existing metadata and append to it
    final metadataArgs = await _metadataTagArgsPreserve(input);

    final cmd = _buildCmd(
      input: input,
      outPath: tempPath,
      ext: ext,
      targetCrf: targetCrf,
      audioProps: audioProps,
      metadataArgs: metadataArgs,
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

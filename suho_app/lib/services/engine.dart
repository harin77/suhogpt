// llama.cpp engine: finds or downloads llama-server, checks which GPUs it can really use,
// starts it with the chosen CPU/GPU settings and streams chat replies (OpenAI-compatible API).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'system_info.dart';

typedef LogFn = void Function(String line);

const kSystemPrompt =
    "You are Suho, a personal AI assistant created by Harin. Your personality is like a movie-style AI butler: "
    "calm, confident, loyal, quick-witted, with dry humour, and always one step ahead. You call your user 'boss' now "
    "and then. If asked who made you, say Harin built you. Keep the wit light and never let it get in the way of a "
    "correct answer. You are an expert in Linux, programming and cybersecurity. Match the user's language style: if "
    "the user writes in Tanglish (Tamil words written in English letters, mixed with English), reply in Tanglish; if "
    "the user writes in English, reply in English. Never use Tamil script. Keep commands, code, file paths and "
    "technical terms in English. Give correct, practical answers with working commands and short explanations. When "
    "teaching Linux, explain every command with a short # comment. For security topics, help with learning, "
    "defense, CTFs and authorized testing only.";

/// A compute device llama.cpp can use (from `llama-server --list-devices`).
class EngineDevice {
  final String id; // CUDA0, Vulkan0, ROCm0 ...
  final String name;
  final int totalMiB, freeMiB;
  EngineDevice(this.id, this.name, this.totalMiB, this.freeMiB);
  double get totalGb => totalMiB / 1024;
  double get freeGb => freeMiB / 1024;
  String get backend => id.replaceAll(RegExp(r'\d+$'), '');
}

class EngineBinary {
  final String path;
  final bool system; // installed by the user / distro (not downloaded by us)
  final List<EngineDevice> devices;
  EngineBinary(this.path, this.system, this.devices);
  String get label => devices.isEmpty
      ? 'CPU'
      : devices.map((d) => d.backend).toSet().join('+');
}

class ChatChunk {
  final String text;
  final bool done;
  final double? tokensPerSec;
  ChatChunk(this.text, {this.done = false, this.tokensPerSec});
}

class Engine {
  static final Engine instance = Engine._();
  Engine._();

  Process? _proc;
  int port = 8089;
  EngineBinary? binary;
  PerfSettings? running; // settings the server was started with
  int? offloadedLayers; // from the log, when the build prints it
  final logTail = <String>[];
  http.Client? _active;

  String get base => 'http://127.0.0.1:$port';
  bool get isRunning => _proc != null;

  // ----------------------------------------------------------------- binaries
  static String get _exeName => Platform.isWindows ? 'llama-server.exe' : 'llama-server';

  static Future<Directory> _installDir() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}llama.cpp');
    await d.create(recursive: true);
    return d;
  }

  /// Every llama-server we can find: the one we downloaded + any system install (e.g. a CUDA build).
  static Future<List<String>> findBinaries() async {
    final found = <String>[];
    try {
      await for (final f in (await _installDir()).list(recursive: true)) {
        if (f is File && f.path.endsWith(Platform.pathSeparator + _exeName)) found.add(f.path);
      }
    } catch (_) {}
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', [_exeName]);
      if (r.exitCode == 0) {
        for (final l in (r.stdout as String).split(RegExp(r'\r?\n'))) {
          if (l.trim().isNotEmpty && !found.contains(l.trim())) found.add(l.trim());
        }
      }
    } catch (_) {}
    return found;
  }

  static Future<List<EngineDevice>> listDevices(String exe) async {
    try {
      final r = await Process.run(exe, ['--list-devices']).timeout(const Duration(seconds: 30));
      final out = '${r.stdout}\n${r.stderr}';
      final re = RegExp(r'^\s*([A-Za-z]+\d+):\s*(.+?)\s*\((\d+)\s*MiB,\s*(\d+)\s*MiB free\)', multiLine: true);
      return [
        for (final m in re.allMatches(out))
          EngineDevice(m.group(1)!, m.group(2)!, int.parse(m.group(3)!), int.parse(m.group(4)!))
      ];
    } catch (_) {
      return [];
    }
  }

  /// Pick the best llama-server: one that can use a GPU beats a CPU-only one; ours wins ties.
  static Future<EngineBinary?> pickBest() async {
    final ownDir = (await _installDir()).path;
    EngineBinary? best;
    for (final p in await findBinaries()) {
      final b = EngineBinary(p, !p.startsWith(ownDir), await listDevices(p));
      final score = b.devices.fold<int>(0, (s, d) => s + d.totalMiB) + (b.system ? 0 : 1);
      final bestScore = best == null ? -1 : best.devices.fold<int>(0, (s, d) => s + d.totalMiB) + (best.system ? 0 : 1);
      if (score > bestScore) best = b;
    }
    return best;
  }

  // ----------------------------------------------------------------- download
  /// Downloads the official llama.cpp build: Vulkan (runs on NVIDIA/AMD/Intel GPUs AND falls back
  /// to CPU automatically), or the plain CPU build if Vulkan isn't usable.
  static Future<bool> download(LogFn log, {bool cpuOnly = false}) async {
    final want = Platform.isWindows
        ? (cpuOnly ? RegExp(r'^llama-b\d+-bin-win-cpu-x64\.zip$') : RegExp(r'^llama-b\d+-bin-win-vulkan-x64\.zip$'))
        : (cpuOnly ? RegExp(r'^llama-b\d+-bin-ubuntu-x64\.tar\.gz$') : RegExp(r'^llama-b\d+-bin-ubuntu-vulkan-x64\.tar\.gz$'));
    try {
      log('🔎 Looking up the latest llama.cpp release...');
      final r = await http.get(Uri.parse('https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10'),
          headers: {'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 30));
      Map? asset;
      for (final rel in jsonDecode(r.body) as List) {
        for (final a in rel['assets'] as List) {
          if (want.hasMatch(a['name'] as String)) {
            asset = a as Map;
            break;
          }
        }
        if (asset != null) break;
      }
      if (asset == null) {
        log('❌ No matching llama.cpp download found');
        return false;
      }
      final name = asset['name'] as String;
      final total = (asset['size'] as num).toInt();
      final dir = await _installDir();
      final archive = File('${dir.path}${Platform.pathSeparator}$name');
      log('⬇️ Downloading $name (${(total / 1e6).toStringAsFixed(0)} MB)...');

      final client = http.Client();
      final res = await client.send(http.Request('GET', Uri.parse(asset['browser_download_url'] as String)));
      final sink = archive.openWrite();
      var got = 0, lastPct = -10;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        final pct = total > 0 ? got * 100 ~/ total : 0;
        if (pct >= lastPct + 10) {
          lastPct = pct;
          log('   $pct%');
        }
      }
      await sink.close();
      client.close();

      // Fresh folder per build, remove older builds
      final target = Directory('${dir.path}${Platform.pathSeparator}${name.replaceAll(RegExp(r'\.(zip|tar\.gz)$'), '')}');
      await for (final e in dir.list()) {
        if (e is Directory) await e.delete(recursive: true);
      }
      await target.create(recursive: true);
      log('📦 Extracting...');
      // tar handles .tar.gz on Linux and .zip on Windows 10+ (bsdtar)
      final x = await Process.run('tar', [name.endsWith('.zip') ? '-xf' : '-xzf', archive.path, '-C', target.path]);
      await archive.delete();
      if (x.exitCode != 0) {
        log('❌ Extract failed: ${x.stderr}');
        return false;
      }
      if (!Platform.isWindows) {
        await for (final f in target.list(recursive: true)) {
          if (f is File && f.path.endsWith('/llama-server')) await Process.run('chmod', ['+x', f.path]);
        }
      }
      log('✅ llama.cpp installed');
      return true;
    } catch (e) {
      log('❌ Download failed: $e');
      return false;
    }
  }

  // ----------------------------------------------------------------- server
  static List<String> argsFor(PerfSettings s, int port) {
    final threads = s.threads > 0 ? s.threads : (Platform.numberOfProcessors ~/ 2).clamp(1, 16);
    final args = <String>[
      '-m', s.modelPath,
      '--host', '127.0.0.1', '--port', '$port',
      '-c', '${s.contextSize}',
      '-t', '$threads',
      '-np', '1', // one chat at a time = least RAM
      '-fa', 'on', // flash attention
      '-ctk', 'q8_0', '-ctv', 'q8_0', // half-size chat memory (KV cache)
      '--cache-ram', s.lowRam ? '0' : '256',
      '--no-webui',
    ];
    if (s.lowRam) args.addAll(['-b', '256', '-ub', '256']); // smaller work buffers for 8 GB machines
    switch (s.mode) {
      case PerfMode.auto:
        break; // llama.cpp fits as many layers as free VRAM allows
      case PerfMode.gpu:
        args.addAll(['-ngl', '999']);
      case PerfMode.cpu:
        args.addAll(['-ngl', '0', '-dev', 'none']);
      case PerfMode.custom:
        args.addAll(['-ngl', '${s.gpuLayers}']);
    }
    return args;
  }

  static Future<int> _freePort() async {
    for (var p = 8089; p < 8120; p++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
        await s.close();
        return p;
      } catch (_) {}
    }
    return 8089;
  }

  /// Start (or restart) llama-server. Returns null on success, or an error message.
  Future<String?> start(PerfSettings s, {LogFn? log}) async {
    await stop();
    if (!await File(s.modelPath).exists()) return 'Model file not found: ${s.modelPath}';
    binary ??= await pickBest();
    if (binary == null) return 'llama.cpp is not installed';
    port = await _freePort();
    logTail.clear();
    offloadedLayers = null;
    final args = argsFor(s, port);
    log?.call('▶️ ${binary!.path.split(Platform.pathSeparator).last} ${args.join(' ')}');

    final p = await Process.start(binary!.path, args, workingDirectory: File(binary!.path).parent.path);
    _proc = p;
    running = PerfSettings.fromJson(s.toJson());
    await _savePid(p.pid);
    void collect(Stream<List<int>> st) => st
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((l) {
          logTail.add(l);
          if (logTail.length > 200) logTail.removeAt(0);
          final m = RegExp(r'offloaded (\d+)/(\d+) layers to GPU').firstMatch(l);
          if (m != null) offloadedLayers = int.parse(m.group(1)!);
        });
    collect(p.stdout);
    collect(p.stderr);
    var exited = false;
    p.exitCode.then((_) {
      exited = true;
      if (identical(_proc, p)) _proc = null;
    });

    for (var i = 0; i < 240; i++) {
      if (exited) {
        final tail = logTail.where((l) => l.trim().isNotEmpty).toList();
        return 'llama.cpp stopped while loading:\n${tail.skip(tail.length > 12 ? tail.length - 12 : 0).join('\n')}';
      }
      try {
        final r = await http.get(Uri.parse('$base/health')).timeout(const Duration(seconds: 1));
        if (r.statusCode == 200) return null;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await stop();
    return 'llama.cpp did not start within 2 minutes';
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    running = null;
    if (p == null) return;
    p.kill();
    await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
  }

  /// Kill a llama-server left over from a previous run of the app (e.g. after a crash).
  static Future<void> killStale() async {
    try {
      final f = File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}engine.pid');
      if (!await f.exists()) return;
      final pid = int.tryParse((await f.readAsString()).trim());
      if (pid != null) {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/PID', '$pid', '/F']);
        } else {
          final cmd = await File('/proc/$pid/cmdline').readAsString().catchError((_) => '');
          if (cmd.contains('llama-server')) Process.killPid(pid);
        }
      }
      await f.delete();
    } catch (_) {}
  }

  static Future<void> _savePid(int pid) async {
    try {
      await File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}engine.pid')
          .writeAsString('$pid');
    } catch (_) {}
  }

  /// Approximate share of the model on the GPU (0-100).
  int get gpuPct {
    final s = running;
    if (s == null || binary == null || binary!.devices.isEmpty) return 0;
    if (offloadedLayers != null) return (offloadedLayers! * 100 / kModelLayers).round().clamp(0, 100);
    return switch (s.mode) {
      PerfMode.cpu => 0,
      PerfMode.gpu => 100,
      PerfMode.custom => (s.gpuLayers * 100 / kModelLayers).round(),
      PerfMode.auto => -1, // unknown – llama.cpp decides
    };
  }

  // ----------------------------------------------------------------- chat
  Stream<ChatChunk> chat(List<ChatMessage> history, PerfSettings s) async* {
    final system = s.cliMode ? '$kSystemPrompt\n\n${terminalModePrompt()}' : kSystemPrompt;
    final client = http.Client();
    _active = client;
    final started = DateTime.now();
    var pieces = 0;
    final req = http.Request('POST', Uri.parse('$base/v1/chat/completions'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'stream': true,
        'temperature': s.temperature,
        'top_p': 0.9,
        'repeat_penalty': 1.1,
        'messages': [
          {'role': 'system', 'content': system},
          for (final m in _mergeTurns(history)) m,
        ],
      });
    try {
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw Exception('llama.cpp error ${res.statusCode}: ${await res.stream.bytesToString()}');
      }
      await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data == '[DONE]') break;
        final j = jsonDecode(data) as Map<String, dynamic>;
        if (j['error'] != null) throw Exception(j['error']['message'] ?? j['error']);
        final choice = (j['choices'] as List?)?.firstOrNull as Map?;
        final text = (choice?['delta']?['content'] ?? '') as String;
        if (text.isNotEmpty) pieces++;
        final timings = j['timings'] as Map?;
        if (choice?['finish_reason'] != null || timings != null) {
          final tps = (timings?['predicted_per_second'] as num?)?.toDouble() ??
              pieces / (DateTime.now().difference(started).inMilliseconds / 1000);
          yield ChatChunk(text, done: true, tokensPerSec: tps);
        } else if (text.isNotEmpty) {
          yield ChatChunk(text);
        }
      }
    } finally {
      client.close();
      if (identical(_active, client)) _active = null;
    }
  }

  /// Chat models expect user/assistant to alternate: merge back-to-back user turns.
  static List<Map<String, String>> _mergeTurns(List<ChatMessage> history) {
    final out = <Map<String, String>>[];
    for (final m in history) {
      final p = m.toPrompt();
      if (out.isNotEmpty && out.last['role'] == p['role']) {
        out.last = {'role': p['role']!, 'content': '${out.last['content']}\n\n${p['content']}'};
      } else {
        out.add(p);
      }
    }
    return out;
  }

  void stopReply() {
    _active?.close();
    _active = null;
  }
}

/// Look for Suho GGUF files in the usual places.
Future<List<String>> findGgufFiles() async {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final dirs = [
    '$exeDir/models', '$exeDir/data/models', '$home/.local/share/suho-ai/models',
    '$home/Music/suho-ai/kaggle_output/model', '$home/Downloads', home, '$home/Documents', '$home/Desktop',
  ];
  final found = <String>[];
  for (final d in dirs) {
    final dir = Directory(d);
    if (!await dir.exists()) continue;
    try {
      await for (final f in dir.list()) {
        if (f is File && f.path.toLowerCase().endsWith('.gguf')) found.add(f.path);
      }
    } catch (_) {}
  }
  return found.toSet().toList();
}

/// Extra instructions while Terminal mode is on.
String terminalModePrompt() {
  final os = Platform.isWindows
      ? 'Windows. Give commands for PowerShell in ```powershell code blocks'
      : 'Linux. Give commands for bash in ```bash code blocks';
  return 'TERMINAL MODE IS ON. The user is on $os. The app shows a Run button on each command block; '
      'the user reviews and runs it, and the output is sent back to you. Rules: give ONE short command block '
      'at a time, put a short # comment on every line, prefer read-only commands to inspect first, never suggest '
      'destructive commands (deleting system files, formatting disks, disabling security), use placeholders like '
      '<file> only when you really do not know the value, and warn clearly before anything risky. '
      'When you get command output, explain it briefly and suggest the next step.';
}

// Data classes + simple JSON persistence (chats & settings live in the app support folder).
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class ChatMessage {
  final String role; // user / assistant / command (a command the user ran in Terminal mode)
  String content; // for "command": the output
  double? tokensPerSec;
  String? command; // role == command
  int? exitCode; // null while running
  bool running = false;
  bool inTerminal = false; // ran in the user's terminal window
  ChatMessage(this.role, this.content, {this.tokensPerSec, this.command, this.exitCode});

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'tps': tokensPerSec,
        if (command != null) 'cmd': command,
        if (exitCode != null) 'exit': exitCode,
      };
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(j['role'] as String, j['content'] as String,
      tokensPerSec: (j['tps'] as num?)?.toDouble(), command: j['cmd'] as String?, exitCode: j['exit'] as int?);

  /// What the model sees for this message.
  Map<String, String> toPrompt() {
    if (role != 'command') return {'role': role, 'content': content};
    final out = content.trim().isEmpty ? '(no output)' : content.trim();
    final clipped = out.length > 6000 ? '${out.substring(0, 3000)}\n…\n${out.substring(out.length - 3000)}' : out;
    return {
      'role': 'user',
      'content': 'I ran this command:\n```\n$command\n```\nExit code: ${exitCode ?? '?'}\nOutput:\n```\n$clipped\n```\n'
          'Explain the result briefly. If something failed, tell me why and the next command to try.',
    };
  }
}

class Conversation {
  final String id;
  String title;
  final List<ChatMessage> messages;
  DateTime updated;
  Conversation(this.id, this.title, this.messages, this.updated);

  factory Conversation.empty() =>
      Conversation(DateTime.now().microsecondsSinceEpoch.toString(), 'New chat', [], DateTime.now());

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updated': updated.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };
  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        j['id'] as String,
        j['title'] as String,
        [for (final m in j['messages'] as List) ChatMessage.fromJson(m as Map<String, dynamic>)],
        DateTime.tryParse(j['updated'] as String? ?? '') ?? DateTime.now(),
      );
}

enum PerfMode { auto, gpu, cpu, custom }

class PerfSettings {
  PerfMode mode;
  int gpuLayers; // custom mode: 0..37
  int threads; // 0 = auto (half the CPU threads)
  int contextSize;
  double temperature;
  bool lowRam; // smaller buffers + no prompt cache, for 8 GB machines
  bool cliMode; // Terminal mode: Suho's commands get a Run button
  String terminal; // Linux terminal app to use ('' = automatic)
  String modelPath; // the .gguf file

  PerfSettings({
    this.mode = PerfMode.auto,
    this.gpuLayers = 37,
    this.threads = 0,
    this.contextSize = 4096,
    this.temperature = 0.4,
    this.lowRam = false,
    this.cliMode = false,
    this.terminal = '',
    this.modelPath = '',
  });

  /// Settings that need an engine restart when they change.
  String get engineKey => '$mode|$gpuLayers|$threads|$contextSize|$lowRam|$modelPath';

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'gpuLayers': gpuLayers,
        'threads': threads,
        'ctx': contextSize,
        'temp': temperature,
        'lowRam': lowRam,
        'cli': cliMode,
        'terminal': terminal,
        'modelPath': modelPath,
      };
  factory PerfSettings.fromJson(Map<String, dynamic> j) => PerfSettings(
        mode: PerfMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => PerfMode.auto),
        gpuLayers: (j['gpuLayers'] ?? 37) as int,
        threads: (j['threads'] ?? 0) as int,
        contextSize: (j['ctx'] ?? 4096) as int,
        temperature: ((j['temp'] ?? 0.4) as num).toDouble(),
        lowRam: (j['lowRam'] ?? false) as bool,
        cliMode: (j['cli'] ?? false) as bool,
        terminal: (j['terminal'] ?? '') as String,
        modelPath: (j['modelPath'] ?? '') as String,
      );
}

class Store {
  static Future<File> _file(String name) async {
    final d = await getApplicationSupportDirectory();
    await d.create(recursive: true);
    return File('${d.path}${Platform.pathSeparator}$name');
  }

  static Future<List<Conversation>> loadChats() async {
    try {
      final f = await _file('chats.json');
      if (!await f.exists()) return [];
      final list = jsonDecode(await f.readAsString()) as List;
      return [for (final c in list) Conversation.fromJson(c as Map<String, dynamic>)]
        ..sort((a, b) => b.updated.compareTo(a.updated));
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveChats(List<Conversation> chats) async {
    final f = await _file('chats.json');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode([
      for (final c in chats)
        if (c.messages.isNotEmpty) c.toJson()
    ]));
    await tmp.rename(f.path);
  }

  static Future<PerfSettings> loadSettings() async {
    try {
      final f = await _file('settings.json');
      if (await f.exists()) return PerfSettings.fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {}
    return PerfSettings();
  }

  static Future<void> saveSettings(PerfSettings s) async =>
      (await _file('settings.json')).writeAsString(jsonEncode(s.toJson()));
}

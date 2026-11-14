// Terminal mode: runs commands that Suho suggests – ONLY after the user reviews and clicks Run.
// Linux -> bash, Windows -> PowerShell. Includes a rule-based risk checker that writes
// "safety comments" explaining what a command can do, and blocks the truly destructive ones.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';


export 'risk.dart';

class RunResult {
  final int exitCode;
  final String output;
  final Duration took;
  final bool timedOut, stopped;
  RunResult(this.exitCode, this.output, this.took, {this.timedOut = false, this.stopped = false});
}

class ShellRunner {
  Process? _p;
  bool _stopped = false;
  static const maxOutput = 12000;

  bool get running => _p != null;

  /// Run in the background (no window). Output streams to [onOutput].
  Future<RunResult> run(String cmd, {Duration timeout = const Duration(minutes: 2), void Function(String)? onOutput}) async {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path;
    final started = DateTime.now();
    _stopped = false;
    final buf = StringBuffer();
    var truncated = false;

    final Process p;
    if (Platform.isWindows) {
      p = await Process.start('powershell', ['-NoProfile', '-NonInteractive', '-Command', cmd], workingDirectory: home);
    } else {
      // setsid = own process group, so Stop also kills child processes
      final hasSetsid = await File('/usr/bin/setsid').exists() || await File('/bin/setsid').exists();
      p = await Process.start(hasSetsid ? 'setsid' : 'bash', [if (hasSetsid) 'bash', '-c', cmd],
          workingDirectory: home, environment: {'TERM': 'dumb', 'PAGER': 'cat', 'SYSTEMD_PAGER': 'cat', 'GIT_PAGER': 'cat'});
    }
    _p = p;
    unawaited(p.stdin.close());
    Future<void> collect(Stream<List<int>> s) => s.transform(const Utf8Decoder(allowMalformed: true)).listen((t) {
          t = t.replaceAll(RegExp(r'\x1B\[[0-9;?]*[A-Za-z]'), '');
          if (buf.length < maxOutput) {
            buf.write(t);
            onOutput?.call(t);
          } else if (!truncated) {
            truncated = true;
            buf.write('\n… (output cut at ${maxOutput ~/ 1000} KB)');
            onOutput?.call('\n… (output cut)');
          }
        }).asFuture<void>().catchError((_) {});
    final streams = Future.wait([collect(p.stdout), collect(p.stderr)]);

    var timedOut = false;
    final code = await p.exitCode.timeout(timeout, onTimeout: () {
      timedOut = true;
      stop();
      return -1;
    });
    // Wait for the remaining output (bounded – a leftover background child could keep the pipe open)
    await streams.timeout(const Duration(seconds: 2), onTimeout: () => []);
    _p = null;
    final r = RunResult(code, buf.toString(), DateTime.now().difference(started), timedOut: timedOut, stopped: _stopped);
    await _audit('in-app', cmd, code);
    return r;
  }

  void stop() {
    final p = _p;
    if (p == null) return;
    _stopped = true;
    if (Platform.isWindows) {
      Process.run('taskkill', ['/PID', '${p.pid}', '/T', '/F']);
    } else {
      Process.run('kill', ['-TERM', '-${p.pid}']); // whole process group
      p.kill();
    }
  }

  /// Open the command in a real terminal window (for sudo / interactive commands). Returns false if none found.
  static Future<bool> openInTerminal(String cmd) async {
    final dir = await getTemporaryDirectory();
    await _audit('terminal', cmd, null);
    if (Platform.isWindows) {
      final f = File('${dir.path}\\suho_cmd_${DateTime.now().millisecondsSinceEpoch}.ps1');
      await f.writeAsString('Write-Host "SuhoGPT command:" -ForegroundColor Cyan\n'
          'Write-Host @\'\n$cmd\n\'@ -ForegroundColor Yellow\nWrite-Host ""\n$cmd\n');
      await Process.start('powershell', [
        '-NoProfile', '-Command',
        "Start-Process powershell -ArgumentList '-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File','${f.path}'"
      ]);
      return true;
    }
    final f = File('${dir.path}/suho_cmd_${DateTime.now().millisecondsSinceEpoch}.sh');
    final quoted = cmd.replaceAll("'", "'\\''");
    await f.writeAsString('#!/usr/bin/env bash\n'
        'echo -e "\\e[36mSuhoGPT command:\\e[0m"\nprintf \'%s\\n\' \'$quoted\'\necho\n'
        '$cmd\n'
        'echo; read -rp "Done (exit \$?). Press Enter to close..." _\n');
    await Process.run('chmod', ['+x', f.path]);
    final terms = <List<String>>[
      ['x-terminal-emulator', '-e', f.path],
      ['kgx', '--', f.path],
      ['gnome-terminal', '--', f.path],
      ['ptyxis', '--new-window', '--', f.path],
      ['ghostty', '-e', f.path],
      ['konsole', '-e', f.path],
      ['xfce4-terminal', '-x', f.path],
      ['kitty', f.path],
      ['alacritty', '-e', f.path],
      ['wezterm', 'start', '--', f.path],
      ['foot', f.path],
      ['tilix', '-e', f.path],
      ['mate-terminal', '-x', f.path],
      ['lxterminal', '-e', f.path],
      ['xterm', '-e', f.path],
    ];
    for (final t in terms) {
      final w = await Process.run('which', [t.first]);
      if (w.exitCode == 0) {
        await Process.start(t.first, t.sublist(1), mode: ProcessStartMode.detached);
        return true;
      }
    }
    return false;
  }

  /// Every command that runs is logged to command_history.log in the app data folder.
  static Future<void> _audit(String where, String cmd, int? code) async {
    try {
      final f = File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}command_history.log');
      await f.writeAsString(
          '[${DateTime.now().toIso8601String()}] ($where${code == null ? '' : ', exit $code'})\n$cmd\n\n',
          mode: FileMode.append);
    } catch (_) {}
  }
}

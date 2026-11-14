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

  bool get running => _p != null || _waiting;

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
    if (_waiting) _cancelWait = true;
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

  // ---------------------------------------------------------------- real terminal
  bool _cancelWait = false;
  bool _waiting = false;

  bool get waitingForTerminal => _waiting;

  /// Run the command in the user's REAL terminal window (Ptyxis/Konsole/... or PowerShell).
  /// Everything shown in the terminal is recorded, streamed to [onOutput] and returned when
  /// the command finishes, so Suho can explain it. Returns null if no terminal app was found.
  Future<RunResult?> runInTerminal(String cmd,
      {void Function(String)? onOutput, Duration timeout = const Duration(minutes: 30)}) async {
    final started = DateTime.now();
    final sep = Platform.pathSeparator;
    final dir = Directory('${(await getTemporaryDirectory()).path}${sep}suho_run_${started.millisecondsSinceEpoch}');
    await dir.create(recursive: true);
    final out = File('${dir.path}${sep}out.log');
    final exitF = File('${dir.path}${sep}exit.code');
    await _audit('terminal', cmd, null);

    if (Platform.isWindows) {
      await File('${dir.path}${sep}cmd.ps1').writeAsString(cmd);
      final wrap = File('${dir.path}${sep}run.ps1');
      final d = dir.path;
      await wrap.writeAsString([
        'Set-Location \$HOME',
        '\$Host.UI.RawUI.WindowTitle = "SuhoGPT command"',
        'Write-Host "-- SuhoGPT command --" -ForegroundColor Cyan',
        'Get-Content "$d\\cmd.ps1" | Write-Host -ForegroundColor Yellow',
        'Write-Host "---------------------" -ForegroundColor Cyan',
        '\$global:LASTEXITCODE = 0',
        'try { & "$d\\cmd.ps1" 2>&1 | Tee-Object -FilePath "$d\\out.log"; \$code = if (\$?) { [int]\$LASTEXITCODE } else { 1 } }',
        'catch { \$_ | Out-String | Tee-Object -FilePath "$d\\out.log" -Append | Write-Host -ForegroundColor Red; \$code = 1 }',
        'Set-Content "$d\\exit.code" \$code',
        'Write-Host ""',
        'Write-Host "-- finished (exit \$code) - output sent to SuhoGPT --" -ForegroundColor Cyan',
        'Read-Host "Press Enter to close"',
      ].join('\r\n'));
      await Process.start('powershell', [
        '-NoProfile', '-Command',
        "Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','${wrap.path}'"
      ]);
    } else {
      await File('${dir.path}/cmd.sh').writeAsString('$cmd\n');
      final wrap = File('${dir.path}/run.sh');
      final d = dir.path;
      await wrap.writeAsString([
        '#!/usr/bin/env bash',
        "D='$d'",
        'cd "\$HOME"',
        r"printf '\033]0;SuhoGPT command\007'",
        r'echo -e "\e[36m── SuhoGPT command ─────────────────────\e[0m"',
        r'cat "$D/cmd.sh"',
        r'echo -e "\e[36m────────────────────────────────────────\e[0m"',
        r'if command -v script >/dev/null 2>&1; then',
        r'''  script -qefc "bash '$D/cmd.sh'" "$D/out.log"; code=$?''',
        r'else',
        r'  bash "$D/cmd.sh" 2>&1 | tee "$D/out.log"; code=${PIPESTATUS[0]}',
        r'fi',
        r'echo "$code" > "$D/exit.code"',
        r'echo',
        r'echo -e "\e[36m── finished (exit $code) – output sent to SuhoGPT ──\e[0m"',
        r'read -rp "Press Enter to close..." _',
      ].join('\n'));
      await Process.run('chmod', ['+x', wrap.path]);
      if (!await _launchLinuxTerminal(wrap.path)) return null;
    }

    _waiting = true;
    _cancelWait = false;
    var shown = 0;
    var timedOut = false;
    while (true) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (await out.exists()) {
        final txt = cleanTerminalLog(await out.readAsString().catchError((_) => ''));
        if (txt.length > shown) {
          onOutput?.call(txt.substring(shown));
          shown = txt.length;
        }
      }
      if (await exitF.exists() || _cancelWait) break;
      if (DateTime.now().difference(started) > timeout) {
        timedOut = true;
        break;
      }
    }
    _waiting = false;
    await Future.delayed(const Duration(milliseconds: 200));
    var output = await out.exists() ? cleanTerminalLog(await out.readAsString().catchError((_) => '')) : '';
    if (output.length > maxOutput) output = '${output.substring(0, maxOutput)}\n… (output cut)';
    final code = await exitF.exists() ? int.tryParse((await exitF.readAsString()).trim()) ?? -1 : -1;
    await _audit('terminal', cmd, code);
    return RunResult(code, output, DateTime.now().difference(started), timedOut: timedOut, stopped: _cancelWait);
  }

  /// User's choice from Settings ('' = automatic).
  static String preferredTerminal = '';

  /// How each Linux terminal runs a program: name -> extra args placed before the script path.
  static const linuxTerminals = <String, List<String>>{
    // desktop-default helpers
    'xdg-terminal-exec': [],
    'x-terminal-emulator': ['-e'],
    // GNOME / GTK
    'ptyxis': ['--new-window', '--'],
    'kgx': ['--'], // GNOME Console
    'gnome-terminal': ['--'],
    'tilix': ['-e'],
    'terminator': ['-x'],
    'guake': ['-e'],
    'io.elementary.terminal': ['-x'],
    'deepin-terminal': ['-e'],
    'sakura': ['-e'],
    // KDE / Qt
    'konsole': ['-e'],
    'yakuake': [], // drop-down; falls through if it can't exec
    'qterminal': ['-e'],
    'cool-retro-term': ['-e'],
    // Xfce / MATE / LXDE / LXQt / Cinnamon
    'xfce4-terminal': ['-x'],
    'mate-terminal': ['-x'],
    'lxterminal': ['-e'],
    'tilda': ['-c'],
    // GPU / modern terminals
    'kitty': [],
    'alacritty': ['-e'],
    'wezterm': ['start', '--'],
    'foot': [],
    'ghostty': ['-e'],
    'rio': ['-e'],
    'contour': ['execute'],
    'warp-terminal': [],
    'cosmic-term': ['-e'],
    'blackbox': ['--'],
    'terminology': ['-e'],
    // classic X11 terminals
    'st': ['-e'],
    'urxvt': ['-e'],
    'rxvt': ['-e'],
    'termite': ['-e'],
    'zutty': ['-e'],
    'eterm': ['-e'],
    'aterm': ['-e'],
    'xterm': ['-e'],
  };

  static Future<bool> _has(String exe) async {
    try {
      return (await Process.run('which', [exe])).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Installed terminals, in the order they would be tried.
  static Future<List<String>> installedTerminals() async {
    final found = <String>[];
    for (final t in linuxTerminals.keys) {
      if (t == 'yakuake' || t == 'guake' || t == 'tilda') continue; // drop-down terminals: only if chosen
      if (await _has(t)) found.add(t);
    }
    return found;
  }

  /// The user's desktop default terminal, if it can be found.
  static Future<String?> _desktopDefault() async {
    final env = Platform.environment['TERMINAL'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    final desk = (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase();
    if (desk.contains('KDE')) {
      for (final k in ['kreadconfig6', 'kreadconfig5']) {
        try {
          final r = await Process.run(k, ['--file', 'kdeglobals', '--group', 'General', '--key', 'TerminalApplication']);
          final v = (r.stdout as String).trim();
          if (r.exitCode == 0 && v.isNotEmpty) return v;
        } catch (_) {}
      }
      return 'konsole';
    }
    if (desk.contains('GNOME')) {
      for (final t in ['ptyxis', 'kgx', 'gnome-terminal']) {
        if (await _has(t)) return t;
      }
    }
    if (desk.contains('XFCE')) return 'xfce4-terminal';
    if (desk.contains('MATE')) return 'mate-terminal';
    if (desk.contains('LXQT')) return 'qterminal';
    if (desk.contains('LXDE')) return 'lxterminal';
    if (desk.contains('COSMIC')) return 'cosmic-term';
    if (desk.contains('PANTHEON')) return 'io.elementary.terminal';
    if (desk.contains('DEEPIN')) return 'deepin-terminal';
    if (desk.contains('CINNAMON')) return 'gnome-terminal';
    return null;
  }

  static Future<bool> _launchLinuxTerminal(String script) async {
    final order = <String>[];
    if (preferredTerminal.isNotEmpty) order.add(preferredTerminal);
    final def = await _desktopDefault();
    if (def != null) order.add(def);
    order.add('xdg-terminal-exec'); // freedesktop standard (new GNOME/KDE/Fedora/Arch)
    order.addAll(linuxTerminals.keys.where((t) => t != 'yakuake' && t != 'guake' && t != 'tilda'));

    final tried = <String>{};
    for (final entry in order) {
      // $TERMINAL / KDE settings may contain a full command line like "kitty --single-instance"
      final parts = entry.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      if (parts.isEmpty) continue;
      final exe = parts.first;
      final name = exe.split('/').last;
      if (!tried.add(name) || !await _has(exe)) continue;
      final args = [...parts.skip(1), ...(linuxTerminals[name] ?? const ['-e']), script];
      try {
        await Process.start(exe, args, mode: ProcessStartMode.detached);
        return true;
      } catch (_) {}
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

/// Turn a recorded terminal session into plain text: remove colour codes, cursor movement,
/// carriage-return progress bars and the `script` header/footer lines.
String cleanTerminalLog(String raw) {
  var t = raw
      .replaceAll(RegExp(r'\x1B\][^\x07\x1B]*(\x07|\x1B\\)'), '') // OSC (window title etc.)
      .replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '') // CSI (colours, cursor)
      .replaceAll(RegExp(r'\x1B[()][A-Za-z0-9]|\x1B[=>78]'), '')
      .replaceAll('\r\n', '\n');
  // keep only the final state of lines redrawn with \r (progress bars)
  t = t
      .split('\n')
      .map((l) => l.contains('\r') ? l.split('\r').lastWhere((x) => x.isNotEmpty, orElse: () => '') : l)
      .join('\n');
  // apply backspaces
  while (t.contains('\b')) {
    final n = t.replaceAll(RegExp(r'[^\n\x08]\x08'), '');
    if (n == t) break;
    t = n;
  }
  return t
      .replaceAll('\b', '')
      .split('\n')
      .where((l) => !l.startsWith('Script started on') && !l.startsWith('Script done on'))
      .join('\n')
      .replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F]'), '')
      .trim();
}

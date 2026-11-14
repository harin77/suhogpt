import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suho_ai/services/shell.dart';

void main() {
  test('captures output and exit code', () async {
    final r = await ShellRunner().run('echo hello; echo err >&2; exit 3');
    expect(r.exitCode, 3);
    expect(r.output, contains('hello'));
    expect(r.output, contains('err'));
  });

  test('stop kills the command and its children', () async {
    final sh = ShellRunner();
    final f = sh.run('sleep 300 & sleep 300; echo never');
    await Future.delayed(const Duration(seconds: 1));
    sh.stop();
    final r = await f;
    expect(r.stopped, isTrue);
    expect(r.output, isNot(contains('never')));
    await Future.delayed(const Duration(milliseconds: 300));
    final left = await Process.run('pgrep', ['-fx', 'sleep 300']);
    expect((left.stdout as String).trim(), isEmpty, reason: 'child sleep should be killed');
  });

  test('timeout', () async {
    final r = await ShellRunner().run('sleep 10', timeout: const Duration(seconds: 1));
    expect(r.timedOut, isTrue);
  });

  test('runs in home folder, no stdin hang', () async {
    final r = await ShellRunner().run('pwd; read x; echo "read-exit:\$?"');
    expect(r.output.trim().split('\n').first, Platform.environment['HOME']);
    expect(r.output, contains('read-exit:1'));
  });

  test('cleanCommand strips prompts', () {
    expect(cleanCommand('\$ ls -la\n\$ df -h'), 'ls -la\ndf -h');
  });
}

@Tags(['gui'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_linux/path_provider_linux.dart';
import 'package:suho_ai/services/shell.dart';

void main() {
  test('cleanTerminalLog strips colours, \\r progress and script header', () {
    const raw = 'Script started on 2026-11-14 [COMMAND="x"]\n\x1B[32mgreen\x1B[0m text\r\n'
        '10%\r50%\r100%\nab\x08c\nScript done on 2026-11-14 [COMMAND_EXIT_CODE="0"]\n';
    expect(cleanTerminalLog(raw), 'green text\n100%\nac');
  });

  test('runs in the real terminal and captures output + exit code', () async {
    PathProviderLinux.registerWith();
    final terms = await ShellRunner.installedTerminals();
    print('terminals found: $terms');
    final r = await ShellRunner().runInTerminal('echo hello-from-terminal; uname -s; exit 4',
        timeout: const Duration(seconds: 40));
    expect(r, isNotNull);
    print('exit=${r!.exitCode} output=${r.output}');
    expect(r.exitCode, 4);
    expect(r.output, contains('hello-from-terminal'));
    expect(r.output, contains('Linux'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}

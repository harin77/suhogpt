// Review screen shown before ANY command runs: editable command, risk level, safety comments.
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/shell.dart';

enum RunChoice { inApp, terminal }

class RunRequest {
  final String command;
  final RunChoice choice;
  RunRequest(this.command, this.choice);
}

class RunDialog extends StatefulWidget {
  final String command;
  const RunDialog({super.key, required this.command});

  static Future<RunRequest?> show(BuildContext context, String command) =>
      showDialog<RunRequest>(context: context, builder: (_) => RunDialog(command: command));

  @override
  State<RunDialog> createState() => _RunDialogState();
}

class _RunDialogState extends State<RunDialog> {
  late final ctrl = TextEditingController(text: widget.command);
  late RiskReport report = analyzeCommand(widget.command);
  bool understood = false;

  @override
  void initState() {
    super.initState();
    ctrl.addListener(() => setState(() {
          report = analyzeCommand(ctrl.text);
          understood = false;
        }));
  }

  (Color, IconData, String) _style(Risk r) => switch (r) {
        Risk.safe => (Colors.greenAccent.shade400, Icons.verified_user_outlined, 'Safe'),
        Risk.caution => (Colors.amberAccent.shade200, Icons.info_outline, 'Caution'),
        Risk.danger => (Colors.orangeAccent, Icons.warning_amber_rounded, 'Dangerous'),
        Risk.blocked => (Colors.redAccent, Icons.block, 'Blocked'),
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (color, icon, label) = _style(report.level);
    final shell = Platform.isWindows ? 'PowerShell' : 'bash';
    final blocked = report.level == Risk.blocked;
    final needsTick = report.level == Risk.danger;
    final canRun = report.canRunInApp && (!needsTick || understood) && ctrl.text.trim().isNotEmpty;
    final term = Platform.isWindows ? 'PowerShell window' : 'your terminal';
    final canTerminal = !blocked && !report.hasPlaceholder && (!needsTick || understood) && ctrl.text.trim().isNotEmpty;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      title: Row(children: [
        Icon(Icons.terminal, color: cs.primary),
        const SizedBox(width: 10),
        Text('Run in $shell?'),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.6))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
        ),
      ]),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Check the command – you can edit it before running.',
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              minLines: 1,
              maxLines: 10,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.3),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0D0D0D),
                prefixText: Platform.isWindows ? 'PS> ' : '\$ ',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Text('Safety check', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final n in report.notes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(_style(n.level).$2, size: 16, color: _style(n.level).$1),
                  const SizedBox(width: 8),
                  Expanded(child: Text(n.text, style: const TextStyle(fontSize: 13))),
                ]),
              ),
            if (blocked)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    'SuhoGPT will not run this. It can destroy your system or data. '
                    'If you really know what you are doing, type it yourself in a terminal.',
                    style: TextStyle(color: Colors.redAccent.shade100, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            if (needsTick)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: understood,
                onChanged: (v) => setState(() => understood = v ?? false),
                title: const Text('I understand what this command does and want to run it'),
              ),
            const SizedBox(height: 4),
            Text(
              blocked
                  ? ''
                  : 'Opens in $term – you see everything and type any password yourself. '
                      'The output is sent back to Suho to explain. Every command is logged.'
                      '${report.canRunInApp ? '' : '\n(This one can only run in a terminal.)'}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        Tooltip(
          message: 'Runs hidden inside the app (no window), 2-minute limit, no admin rights',
          child: TextButton.icon(
            onPressed: canRun ? () => Navigator.pop(context, RunRequest(ctrl.text.trim(), RunChoice.inApp)) : null,
            icon: const Icon(Icons.visibility_off_outlined, size: 18),
            label: const Text('Run hidden'),
          ),
        ),
        FilledButton.icon(
          style: report.level == Risk.danger ? FilledButton.styleFrom(backgroundColor: Colors.orange.shade800) : null,
          onPressed: canTerminal ? () => Navigator.pop(context, RunRequest(ctrl.text.trim(), RunChoice.terminal)) : null,
          icon: const Icon(Icons.terminal, size: 18),
          label: Text(Platform.isWindows ? 'Run in PowerShell' : 'Run in my terminal'),
        ),
      ],
    );
  }
}

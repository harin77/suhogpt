import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../main.dart';
import '../models.dart';
import '../services/shell.dart';

class MessageView extends StatelessWidget {
  final ChatMessage msg;
  final bool streaming;
  final void Function(String command)? onRun; // set in Terminal mode
  final VoidCallback? onStopCommand;
  const MessageView({super.key, required this.msg, this.streaming = false, this.onRun, this.onStopCommand});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (msg.role == 'command') return _CommandCard(msg: msg, onStop: onStopCommand);
    if (msg.role == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(left: 80, bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(20)),
          child: SelectableText(msg.content, style: const TextStyle(fontSize: 14.5, height: 1.35)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 1), child: SuhoLogo(size: 24)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (msg.content.isEmpty && streaming)
              const _Typing()
            else
              MarkdownBody(
                data: msg.content + (streaming ? ' ▍' : ''),
                selectable: true,
                extensionSet: md.ExtensionSet.gitHubFlavored,
                builders: {'code': CodeBuilder(context, streaming ? null : onRun)},
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: const TextStyle(fontSize: 14.5, height: 1.35),
                  blockSpacing: 6,
                  h1: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, height: 1.3),
                  h2: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.3),
                  h3: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3),
                  listIndent: 20,
                  listBullet: const TextStyle(fontSize: 14.5, height: 1.35),
                  code: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      backgroundColor: cs.surfaceContainerHigh,
                      color: cs.onSurface),
                  codeblockDecoration: const BoxDecoration(),
                  codeblockPadding: EdgeInsets.zero,
                  blockquoteDecoration: BoxDecoration(
                      border: Border(left: BorderSide(color: cs.outline, width: 3))),
                  tableBorder: TableBorder.all(color: cs.outlineVariant),
                ),
              ),
            if (!streaming && msg.content.isNotEmpty)
              Row(children: [
                IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: cs.onSurfaceVariant,
                  onPressed: () => Clipboard.setData(ClipboardData(text: msg.content)),
                  icon: const Icon(Icons.copy_rounded),
                ),
                if (msg.tokensPerSec != null)
                  Text('${msg.tokensPerSec!.toStringAsFixed(1)} tok/s',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ]),
          ]),
        ),
      ]),
    );
  }
}

/// Renders fenced code blocks with a header (language + copy button).
class CodeBuilder extends MarkdownElementBuilder {
  final BuildContext ctx;
  final void Function(String command)? onRun;
  CodeBuilder(this.ctx, [this.onRun]);

  @override
  Widget? visitElementAfterWithContext(
      BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final text = element.textContent;
    final cls = element.attributes['class'] ?? '';
    final isBlock = cls.startsWith('language-') || text.contains('\n');
    if (!isBlock) return null; // inline code -> default styling
    final lang = cls.replaceFirst('language-', '');
    final code = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
    return _CodeBlock(code: code, lang: lang, onRun: onRun != null && isRunnableLang(lang) ? onRun : null);
  }
}

class _CodeBlock extends StatefulWidget {
  final String code, lang;
  final void Function(String command)? onRun;
  const _CodeBlock({required this.code, required this.lang, this.onRun});
  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool copied = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 0, 2, 0),
          decoration: const BoxDecoration(
            color: Color(0xFF2A2A2A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
          ),
          child: Row(children: [
            Text(widget.lang.isEmpty ? 'code' : widget.lang,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const Spacer(),
            if (widget.onRun != null)
              TextButton.icon(
                style: TextButton.styleFrom(
                    foregroundColor: Colors.greenAccent.shade400, visualDensity: VisualDensity.compact),
                onPressed: () => widget.onRun!(cleanCommand(widget.code)),
                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                label: const Text('Run', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white70, visualDensity: VisualDensity.compact),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: widget.code));
                setState(() => copied = true);
                await Future.delayed(const Duration(seconds: 2));
                if (mounted) setState(() => copied = false);
              },
              icon: Icon(copied ? Icons.check : Icons.copy_rounded, size: 14),
              label: Text(copied ? 'Copied' : 'Copy', style: const TextStyle(fontSize: 12)),
            ),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: _highlight(widget.code),
        ),
      ]),
    );
  }

  /// Tiny highlighter: # comments (the Linux-teacher comments!) in green, strings in amber.
  Widget _highlight(String code) {
    const base = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.3, color: Color(0xFFE6E6E6));
    final spans = <TextSpan>[];
    final re = RegExp(r'''(#[^\n]*|//[^\n]*|"(?:\\.|[^"\\\n])*"|'[^'\n]*')''');
    var last = 0;
    for (final m in re.allMatches(code)) {
      // Treat '#' as a comment only at line start or after whitespace (not in $# or URLs).
      final s = m.group(0)!;
      final isComment = s.startsWith('#') || s.startsWith('//');
      if (isComment && m.start > 0 && !RegExp(r'\s').hasMatch(code[m.start - 1])) continue;
      spans.add(TextSpan(text: code.substring(last, m.start)));
      spans.add(TextSpan(
          text: s,
          style: TextStyle(color: isComment ? const Color(0xFF7FB77E) : const Color(0xFFE5C07B))));
      last = m.end;
    }
    spans.add(TextSpan(text: code.substring(last)));
    return SelectableText.rich(TextSpan(style: base, children: spans));
  }
}

class _Typing extends StatefulWidget {
  const _Typing();
  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: c,
        builder: (_, __) => Row(children: [
          for (var i = 0; i < 3; i++)
            Container(
              margin: const EdgeInsets.only(right: 5, top: 8),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.3 + 0.7 * (((c.value * 3 - i) % 3) < 1 ? 1 : 0)),
              ),
            ),
        ]),
      );
}

/// Terminal-style card for a command the user ran.
class _CommandCard extends StatelessWidget {
  final ChatMessage msg;
  final VoidCallback? onStop;
  const _CommandCard({required this.msg, this.onStop});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = msg.exitCode == 0;
    final status = msg.running
        ? 'running…'
        : msg.exitCode == null
            ? 'opened in terminal'
            : 'exit ${msg.exitCode}';
    final statusColor = msg.running || msg.exitCode == null
        ? cs.onSurfaceVariant
        : ok
            ? Colors.greenAccent.shade400
            : Colors.orangeAccent;
    return Container(
      margin: const EdgeInsets.only(left: 36, bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: const BoxDecoration(
              color: Color(0xFF1E2A24), borderRadius: BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: [
            const Icon(Icons.terminal, size: 15, color: Colors.white70),
            const SizedBox(width: 8),
            Text(Platform.isWindows ? 'PowerShell' : 'Terminal',
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const Spacer(),
            if (msg.running) ...[
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
            ],
            Text(status, style: TextStyle(fontSize: 12, color: statusColor)),
            if (msg.running && onStop != null)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent, visualDensity: VisualDensity.compact),
                onPressed: onStop,
                icon: const Icon(Icons.stop_rounded, size: 16),
                label: const Text('Stop', style: TextStyle(fontSize: 12)),
              )
            else
              const SizedBox(width: 8),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SelectableText.rich(TextSpan(
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.3, color: Color(0xFFE6E6E6)),
            children: [
              TextSpan(
                  text: '${Platform.isWindows ? 'PS>' : '\$'} ${msg.command}\n',
                  style: const TextStyle(color: Color(0xFF7FB77E), fontWeight: FontWeight.w600)),
              TextSpan(text: msg.content.isEmpty && !msg.running ? '(no output)' : msg.content),
            ],
          )),
        ),
      ]),
    );
  }
}

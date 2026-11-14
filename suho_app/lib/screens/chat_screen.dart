// ChatGPT-style screen: sidebar with chats, streaming answers, input box, live CPU/GPU chip.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../models.dart';
import '../services/engine.dart';
import '../services/shell.dart';
import '../widgets/run_dialog.dart';
import '../services/system_info.dart';
import '../widgets/message_view.dart';
import '../widgets/perf_panel.dart';
import 'setup_screen.dart';

class ChatScreen extends StatefulWidget {
  final PerfSettings settings;
  const ChatScreen({super.key, required this.settings});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late PerfSettings settings = widget.settings;
  List<Conversation> chats = [];
  late Conversation current = Conversation.empty();
  final input = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  bool streaming = false;
  bool userScrolledUp = false;
  SystemInfo? info;
  final engine = Engine.instance;
  final shell = ShellRunner();
  bool restarting = false;
  Timer? poll;

  static const suggestions = [
    ('🐧', 'Linux la disk full aagiduchu, epdi clean pannradhu?'),
    ('🔐', 'SQL injection na enna? example-oda sollu'),
    ('🐍', 'Python la oru simple port scanner ezhudhi kudu (learning-ku)'),
    ('🛡️', 'How do I harden an Ubuntu server?'),
  ];

  @override
  void initState() {
    super.initState();
    Store.loadChats().then((c) => setState(() => chats = c));
    SystemInfo.detect().then((i) => mounted ? setState(() => info = i) : null);
    poll = Timer.periodic(const Duration(seconds: 3), (_) => _pollLoad());
    scroll.addListener(() {
      if (!scroll.hasClients) return;
      userScrolledUp = scroll.position.maxScrollExtent - scroll.position.pixels > 80;
    });
  }

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> _pollLoad() async {
    if (mounted) setState(() {}); // engine state is read directly in _topBar
  }

  void _scrollDown({bool force = false}) {
    if (userScrolledUp && !force) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send([String? text]) async {
    final q = (text ?? input.text).trim();
    if (q.isEmpty || streaming) return;
    input.clear();
    final convo = current;
    if (convo.messages.isEmpty) {
      convo.title = q.length > 40 ? '${q.substring(0, 40)}…' : q;
      if (!chats.contains(convo)) chats.insert(0, convo);
    }
    convo.messages.add(ChatMessage('user', q));
    await _reply(convo);
  }

  /// Ask Suho to answer the conversation as it is now (after a question or a command result).
  Future<void> _reply(Conversation convo) async {
    final reply = ChatMessage('assistant', '');
    convo.messages.add(reply);
    convo.updated = DateTime.now();
    setState(() => streaming = true);
    _scrollDown(force: true);

    try {
      if (!engine.isRunning) {
        final err = await engine.start(settings);
        if (err != null) throw Exception(err);
      }
      final history = convo.messages.sublist(0, convo.messages.length - 1);
      await for (final c in engine.chat(history, settings)) {
        reply.content += c.text;
        if (c.done) reply.tokensPerSec = c.tokensPerSec;
        if (mounted) setState(() {});
        _scrollDown();
      }
    } catch (e) {
      final msg = e.toString();
      if (!msg.contains('Connection closed') && !msg.contains('ClientException')) {
        reply.content += '\n\n⚠️ **Error:** $msg\n\nIf this keeps happening, open ⚙ Performance → Re-run setup.';
      }
    } finally {
      if (reply.content.isEmpty) reply.content = '_(stopped)_';
      if (mounted) setState(() => streaming = false);
      await Store.saveChats(chats);
      _pollLoad();
      focus.requestFocus();
    }
  }

  void _stop() => engine.stopReply();

  /// Terminal mode: review -> run (in app or in a terminal window) -> Suho explains the output.
  Future<void> _runCommand(String command) async {
    if (streaming || shell.running) return;
    final req = await RunDialog.show(context, command);
    if (req == null || !mounted) return;
    final convo = current;
    final msg = ChatMessage('command', '', command: req.command);
    convo.messages.add(msg);

    msg.inTerminal = req.choice == RunChoice.terminal;
    setState(() => msg.running = true);
    _scrollDown(force: true);
    void onOut(String t) {
      msg.content += t;
      if (mounted) setState(() {});
      _scrollDown();
    }

    ShellRunner.preferredTerminal = settings.terminal;
    final res = msg.inTerminal
        ? await shell.runInTerminal(req.command, onOutput: onOut)
        : await shell.run(req.command, onOutput: onOut);
    msg.running = false;
    if (res == null) {
      msg.content = 'No terminal app found. Pick one in ⚙ Performance → Terminal app, or use "Run hidden".';
      setState(() {});
      await Store.saveChats(chats);
      return;
    }
    msg.exitCode = res.exitCode;
    if (res.timedOut) msg.content += '\n⏱ Stopped after 2 minutes (timeout).';
    if (res.stopped && !res.timedOut) {
      msg.content += msg.inTerminal ? '\n⏹ Stopped waiting (the terminal window may still be open).' : '\n⏹ Stopped by you.';
    }
    if (mounted) setState(() {});
    await Store.saveChats(chats);
    if (!res.stopped && mounted && identical(convo, current)) await _reply(convo); // Suho explains the output
  }

  Future<void> _toggleCli() async {
    final turningOn = !settings.cliMode;
    if (turningOn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.terminal),
          title: const Text('Turn on Terminal mode?'),
          content: const SizedBox(
            width: 480,
            child: Text(
              'Suho\'s command blocks get a ▶ Run button, and results are sent back to Suho to explain.\n\n'
              '🛡  Nothing runs until you review it and click Run.\n'
              '🛡  Each command gets a safety check with comments; destructive ones are blocked.\n'
              '🛡  Admin (sudo) and never-ending commands open in a real terminal window.\n'
              '🛡  Runs in your home folder, 2-minute limit, every command is logged.\n\n'
              'Suho is a small AI and can be wrong – always read a command before running it.',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Turn on')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => settings.cliMode = turningOn);
    await Store.saveSettings(settings);
  }

  void _newChat() {
    if (streaming) return;
    setState(() => current = Conversation.empty());
    focus.requestFocus();
  }

  Future<void> _openPerf() async {
    final s = await showDialog<PerfSettings>(
      context: context,
      builder: (_) => PerfPanel(
        settings: settings,
        info: info,
        onRerunSetup: () {
          Navigator.pop(context);
          Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const SetupScreen()));
        },
      ),
    );
    if (s == null) return;
    final restart = s.engineKey != settings.engineKey;
    final old = settings;
    setState(() => settings = s);
    await Store.saveSettings(s);
    if (!restart || streaming) return;
    // CPU/GPU/thread/context changes need llama.cpp restarted
    setState(() => restarting = true);
    final err = await engine.start(s);
    String? fallback;
    if (err != null) {
      fallback = await engine.start(old); // go back to what worked
      setState(() => settings = old);
      await Store.saveSettings(old);
    }
    if (!mounted) return;
    setState(() => restarting = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: Duration(seconds: err == null ? 3 : 10),
      content: Text(err == null
          ? 'Suho restarted on ${engine.binary?.label ?? 'CPU'} with the new settings.'
          : 'Could not start with those settings, so the previous ones were restored.\n${err.split('\n').last}'
              '${fallback != null ? '\n$fallback' : ''}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 860;
    final sidebar = _Sidebar(
      chats: chats,
      current: current,
      onNew: () {
        _newChat();
        if (!wide) Navigator.maybePop(context);
      },
      onSelect: (c) {
        if (streaming) return;
        setState(() => current = c);
        if (!wide) Navigator.maybePop(context);
        _scrollDown(force: true);
      },
      onDelete: (c) async {
        setState(() {
          chats.remove(c);
          if (identical(c, current)) current = Conversation.empty();
        });
        await Store.saveChats(chats);
      },
      onSettings: _openPerf,
      info: info,
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newChat,
        const SingleActivator(LogicalKeyboardKey.escape): _stop,
      },
      child: Scaffold(
        drawer: wide ? null : Drawer(width: 280, child: sidebar),
        body: Row(children: [
          if (wide) SizedBox(width: 270, child: sidebar),
          Expanded(
            child: Column(children: [
              _topBar(wide),
              Expanded(child: current.messages.isEmpty ? _empty() : _messages()),
              _inputBox(),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _topBar(bool wide) {
    final cs = Theme.of(context).colorScheme;
    final pct = engine.gpuPct;
    final dev = engine.binary?.label ?? 'CPU';
    final (label, color) = restarting
        ? ('restarting…', cs.onSurfaceVariant)
        : !engine.isRunning
            ? ('stopped', cs.error)
            : pct < 0
                ? ('Auto · $dev', Colors.greenAccent.shade400)
                : pct >= 95
                    ? ('GPU 100% · $dev', Colors.greenAccent.shade400)
                    : pct == 0
                        ? ('CPU 100%', Colors.lightBlueAccent.shade100)
                        : ('GPU $pct% · CPU ${100 - pct}%', Colors.amberAccent.shade200);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
      child: Row(children: [
        if (!wide)
          Builder(builder: (c) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(c).openDrawer())),
        const SizedBox(width: 8),
        Text('Suho', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        Text('llama.cpp${settings.lowRam ? ' · Low-RAM' : ''}', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
        const Spacer(),
        Tooltip(
          message: 'Where the model is running right now – click to change',
          child: ActionChip(
            avatar: Icon(Icons.speed, size: 16, color: color),
            label: Text(label, style: TextStyle(fontSize: 12, color: color)),
            onPressed: _openPerf,
          ),
        ),
        IconButton(tooltip: 'New chat (Ctrl+N)', onPressed: _newChat, icon: const Icon(Icons.edit_square)),
      ]),
    );
  }

  Widget _empty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(children: [
            const SuhoLogo(size: 56),
            const SizedBox(height: 12),
            Text('Enna help venum, boss?', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text('Linux · Coding · Cybersecurity — Tanglish or English',
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 18),
            Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
              for (final (e, s) in suggestions)
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _send(s),
                  child: Container(
                    width: 330,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(14)),
                    child: Row(children: [
                      Text(e, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 10),
                      Expanded(child: Text(s, style: const TextStyle(fontSize: 13.5))),
                    ]),
                  ),
                ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _messages() => ListView.builder(
        controller: scroll,
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: current.messages.length,
        itemBuilder: (_, i) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: MessageView(
                msg: current.messages[i],
                streaming: streaming && i == current.messages.length - 1,
                onRun: settings.cliMode && !streaming && !shell.running ? _runCommand : null,
                onStopCommand: shell.stop,
              ),
            ),
          ),
        ),
      );

  Widget _inputBox() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius: BorderRadius.circular(26),
                border: settings.cliMode ? Border.all(color: Colors.greenAccent.shade400.withValues(alpha: 0.5)) : null,
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: IconButton(
                    tooltip: settings.cliMode ? 'Terminal mode ON – click to turn off' : 'Turn on Terminal mode',
                    isSelected: settings.cliMode,
                    onPressed: _toggleCli,
                    color: settings.cliMode ? Colors.greenAccent.shade400 : cs.onSurfaceVariant,
                    icon: const Icon(Icons.terminal),
                  ),
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: (_, e) {
                      // Enter = send, Shift+Enter = new line
                      if (e is KeyDownEvent &&
                          e.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed) {
                        _send();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: input,
                      focusNode: focus,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 8,
                      style: const TextStyle(fontSize: 14.5, height: 1.3),
                      decoration: InputDecoration(
                        hintText: settings.cliMode
                            ? 'Terminal mode – ask Suho to check or fix something on your PC…'
                            : 'Message Suho…  (Shift+Enter for new line)',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: streaming
                      ? IconButton.filled(tooltip: 'Stop (Esc)', onPressed: _stop, icon: const Icon(Icons.stop_rounded))
                      : ListenableBuilder(
                          listenable: input,
                          builder: (_, __) => IconButton.filled(
                            tooltip: 'Send',
                            onPressed: input.text.trim().isEmpty ? null : _send,
                            icon: const Icon(Icons.arrow_upward_rounded),
                          ),
                        ),
                ),
              ]),
            ),
            const SizedBox(height: 6),
            Text('Suho runs offline on your PC and can make mistakes. Double-check important commands.',
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final List<Conversation> chats;
  final Conversation current;
  final VoidCallback onNew, onSettings;
  final ValueChanged<Conversation> onSelect, onDelete;
  final SystemInfo? info;
  const _Sidebar(
      {required this.chats,
      required this.current,
      required this.onNew,
      required this.onSelect,
      required this.onDelete,
      required this.onSettings,
      required this.info});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = info?.verdict();
    return Container(
      color: cs.surfaceContainerLow,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
          child: Row(children: [
            const SuhoLogo(size: 30),
            const SizedBox(width: 10),
            const Text('Suho AI', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const Spacer(),
            IconButton(tooltip: 'New chat', onPressed: onNew, icon: const Icon(Icons.edit_square, size: 20)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(onPressed: onNew, icon: const Icon(Icons.add), label: const Text('New chat')),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: chats.isEmpty
              ? Center(child: Text('No chats yet', style: TextStyle(color: cs.onSurfaceVariant)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: chats.length,
                  itemBuilder: (_, i) {
                    final c = chats[i];
                    final sel = identical(c, current);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -3),
                        minVerticalPadding: 0,
                        contentPadding: const EdgeInsets.only(left: 12, right: 0),
                        selected: sel,
                        selectedTileColor: cs.surfaceContainerHigh,
                        selectedColor: cs.onSurface,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => onSelect(c),
                        trailing: PopupMenuButton<String>(
                          iconSize: 18,
                          tooltip: 'Options',
                          onSelected: (_) => onDelete(c),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'del', child: Text('Delete')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('Performance'),
          subtitle: v == null ? null : Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: onSettings,
        ),
      ]),
    );
  }
}

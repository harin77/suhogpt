// First-run wizard: hardware check -> get llama.cpp -> choose model -> test start.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../services/engine.dart';
import '../services/system_info.dart';
import '../widgets/hardware_card.dart';
import 'chat_screen.dart';

enum StepState { todo, running, done, failed }

class SetupScreen extends StatefulWidget {
  final String? startError;
  const SetupScreen({super.key, this.startError});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final engine = Engine.instance;
  SystemInfo? info;
  EngineBinary? bin;
  final logs = <String>[];
  final logScroll = ScrollController();
  var sEngine = StepState.todo, sModel = StepState.todo, sStart = StepState.todo;
  List<String> ggufs = [];
  String? gguf;
  bool busy = false;
  PerfSettings? ready;

  @override
  void initState() {
    super.initState();
    if (widget.startError != null) logs.add('⚠️ ${widget.startError}');
    _scan();
  }

  void _log(String l) {
    if (!mounted) return;
    setState(() => logs.add(l));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (logScroll.hasClients) logScroll.jumpTo(logScroll.position.maxScrollExtent);
    });
  }

  bool get _hasGpuHardware =>
      info?.gpus.any((g) => g.vendor == GpuVendor.nvidia || g.vendor == GpuVendor.amd || g.vendor == GpuVendor.intel) ??
      false;

  Future<void> _scan() async {
    final results = await Future.wait([SystemInfo.detect(), Engine.pickBest(), findGgufFiles(), Store.loadSettings()]);
    final i = results[0] as SystemInfo;
    final b = results[1] as EngineBinary?;
    final found = results[2] as List<String>;
    final saved = results[3] as PerfSettings;
    if (!mounted) return;
    final want = i.verdict(engineDevices: b?.devices).recommended.label.toLowerCase();
    if (saved.modelPath.isNotEmpty && await File(saved.modelPath).exists() && !found.contains(saved.modelPath)) {
      found.insert(0, saved.modelPath);
    }
    setState(() {
      info = i;
      bin = b;
      engine.binary = b;
      ggufs = found;
      gguf = saved.modelPath.isNotEmpty && found.contains(saved.modelPath)
          ? saved.modelPath
          : (found.where((f) => f.toLowerCase().contains(want)).firstOrNull ?? found.firstOrNull);
      sEngine = b != null ? StepState.done : StepState.todo;
      sModel = gguf != null ? StepState.done : StepState.todo;
      sStart = StepState.todo;
    });
  }

  PerfSettings _settingsFor(String model) {
    final v = info!.verdict(engineDevices: bin?.devices);
    return PerfSettings(
      // Auto: llama.cpp fits as many layers as free VRAM allows (never runs out of memory), and a GPU
      // that starts working later (e.g. after a reboot) is used automatically. GPU/Split can be forced in Performance.
      mode: PerfMode.auto,
      gpuLayers: v.mode == RunMode.gpuPartial ? v.suggestedGpuLayers : kModelLayers,
      lowRam: v.lowRam,
      contextSize: v.lowRam ? 2048 : 4096,
      modelPath: model,
    );
  }

  Future<void> _downloadEngine({bool cpuOnly = false}) async {
    setState(() => sEngine = StepState.running);
    final ok = await Engine.download(_log, cpuOnly: cpuOnly);
    final b = await Engine.pickBest();
    setState(() {
      bin = b;
      engine.binary = b;
      sEngine = ok && b != null ? StepState.done : StepState.failed;
    });
    if (b != null) {
      _log(b.devices.isEmpty
          ? '💻 llama.cpp will run on the CPU${_hasGpuHardware ? ' (no usable GPU driver found – a reboot or driver update may enable it)' : ''}'
          : '⚡ GPU ready: ${b.devices.map((d) => '${d.id} ${d.name} (${d.totalGb.toStringAsFixed(1)} GB)').join(', ')}');
    }
  }

  Future<void> _runAll() async {
    if (info == null) return;
    setState(() => busy = true);
    try {
      if (sEngine != StepState.done) {
        await _downloadEngine();
        if (sEngine != StepState.done) return;
      }
      if (gguf == null) {
        setState(() => sModel = StepState.failed);
        _log('👉 Choose the model file (.gguf) with "Browse".');
        return;
      }
      setState(() {
        sModel = StepState.done;
        sStart = StepState.running;
      });
      final s = _settingsFor(gguf!);
      _log('🧠 Starting Suho on ${bin!.label}${s.lowRam ? ' (Low-RAM mode)' : ''}...');
      final err = await engine.start(s, log: _log);
      if (err != null) {
        _log('❌ $err');
        setState(() => sStart = StepState.failed);
        return;
      }
      await Store.saveSettings(s);
      setState(() {
        sStart = StepState.done;
        ready = s;
      });
      _log('🎉 All set! Click "Start chatting".');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _browse() async {
    final r = await FilePicker.platform.pickFiles(dialogTitle: 'Choose the Suho model (.gguf)', type: FileType.any);
    final p = r?.files.single.path;
    if (p != null) {
      setState(() {
        if (!ggufs.contains(p)) ggufs.add(p);
        gguf = p;
        sModel = StepState.done;
        sStart = StepState.todo;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: info == null
          ? const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Checking your hardware...'),
            ]))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: ListView(padding: const EdgeInsets.all(24), children: [
                  Row(children: [
                    const SuhoLogo(size: 44),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Set up Suho AI', style: Theme.of(context).textTheme.headlineSmall),
                        Text('Runs 100% on your computer with llama.cpp. Nothing is sent to the internet.',
                            style: TextStyle(color: cs.onSurfaceVariant)),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 20),
                  HardwareCard(info: info!, devices: bin?.devices),
                  const SizedBox(height: 16),
                  _step(1, 'AI engine (llama.cpp)', sEngine, _engineText(), child: _engineButtons()),
                  _step(2, 'Suho model file (.gguf)', sModel, null, child: _modelPicker()),
                  _step(3, 'Load the model', sStart, 'Starts llama.cpp with the best settings for your PC'),
                  const SizedBox(height: 12),
                  Row(children: [
                    if (ready == null)
                      FilledButton.icon(
                        onPressed: busy ? null : _runAll,
                        icon: busy
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_fix_high),
                        label: Text(busy ? 'Working...' : 'Set up everything'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (_) => ChatScreen(settings: ready!))),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: const Text('Start chatting'),
                      ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                        onPressed: busy ? null : _scan, icon: const Icon(Icons.refresh), label: const Text('Re-check')),
                  ]),
                  if (logs.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Container(
                      height: 190,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(10)),
                      child: SelectionArea(
                        child: ListView.builder(
                          controller: logScroll,
                          itemCount: logs.length,
                          itemBuilder: (_, i) => Text(logs[i],
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.35)),
                        ),
                      ),
                    ),
                  ],
                ]),
              ),
            ),
    );
  }

  String _engineText() {
    final b = bin;
    if (b == null) {
      return 'Downloads the official llama.cpp build (~40 MB). It uses NVIDIA, AMD or Intel GPUs through Vulkan '
          'and falls back to the CPU automatically.';
    }
    final where = b.system ? 'Using your installed llama.cpp' : 'Using downloaded llama.cpp';
    final dev = b.devices.isEmpty
        ? 'CPU only'
        : b.devices.map((d) => '${d.id}: ${d.name} – ${d.totalGb.toStringAsFixed(1)} GB (${d.freeGb.toStringAsFixed(1)} GB free)').join(', ');
    return '$where → $dev\n${b.path}';
  }

  Widget? _engineButtons() {
    if (busy) return null;
    final b = bin;
    return Wrap(spacing: 8, runSpacing: 6, children: [
      if (b == null || (b.devices.isEmpty && _hasGpuHardware))
        OutlinedButton.icon(
            onPressed: () => _downloadEngine(),
            icon: const Icon(Icons.download, size: 18),
            label: Text(b == null ? 'Download llama.cpp' : 'Try GPU (Vulkan) build')),
      if (sEngine == StepState.failed)
        OutlinedButton.icon(
            onPressed: () => _downloadEngine(cpuOnly: true),
            icon: const Icon(Icons.memory, size: 18),
            label: const Text('Download CPU-only build')),
    ]);
  }

  Widget _modelPicker() {
    final rec = info!.verdict(engineDevices: bin?.devices).recommended;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Recommended for your PC: ${rec.label} (${rec.fileGb} GB)',
          style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 13)),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: ggufs.isEmpty
              ? const Text('No .gguf file found automatically.', style: TextStyle(fontSize: 13))
              : DropdownButton<String>(
                  isExpanded: true,
                  value: gguf,
                  items: [
                    for (final f in ggufs)
                      DropdownMenuItem(
                          value: f, child: Text(f, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                  ],
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                            gguf = v;
                            sStart = StepState.todo;
                            ready = null;
                          }),
                ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
            onPressed: busy ? null : _browse, icon: const Icon(Icons.folder_open, size: 18), label: const Text('Browse')),
      ]),
    ]);
  }

  Widget _step(int n, String title, StepState s, String? sub, {Widget? child}) {
    final cs = Theme.of(context).colorScheme;
    final icon = switch (s) {
      StepState.done => Icon(Icons.check_circle, color: cs.primary),
      StepState.failed => Icon(Icons.error, color: cs.error),
      StepState.running => const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
      StepState.todo => CircleAvatar(
          radius: 11, backgroundColor: cs.surfaceContainerHigh, child: Text('$n', style: const TextStyle(fontSize: 12))),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: cs.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 26, child: icon),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (sub != null) ...[
                const SizedBox(height: 3),
                SelectableText(sub, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
              ],
              if (child != null) ...[const SizedBox(height: 8), child],
            ]),
          ),
        ]),
      ),
    );
  }
}

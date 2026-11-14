// "Performance" panel: CPU / GPU / split, threads, chat memory, Low-RAM mode; shows live load.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/engine.dart';
import '../services/system_info.dart';
import 'hardware_card.dart';

class PerfPanel extends StatefulWidget {
  final PerfSettings settings;
  final SystemInfo? info;
  final VoidCallback onRerunSetup;
  const PerfPanel({super.key, required this.settings, required this.info, required this.onRerunSetup});

  @override
  State<PerfPanel> createState() => _PerfPanelState();
}

class _PerfPanelState extends State<PerfPanel> {
  late PerfSettings s = PerfSettings.fromJson(widget.settings.toJson());
  final engine = Engine.instance;
  Timer? timer;
  GpuLive? gpu;
  double? engineRamGb;

  @override
  void initState() {
    super.initState();
    _poll();
    timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final g = await GpuLive.read();
    double? ram;
    // Real (non-reclaimable) memory used by llama-server – Linux only
    try {
      final r = await Process.run('pgrep', ['-f', 'llama-server.*--port ${engine.port}']);
      final pid = (r.stdout as String).trim().split('\n').first;
      if (pid.isNotEmpty) {
        final st = await File('/proc/$pid/status').readAsString();
        final kb = RegExp(r'RssAnon:\s+(\d+)').firstMatch(st)?.group(1);
        if (kb != null) ram = int.parse(kb) / 1048576;
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        gpu = g;
        engineRamGb = ram;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final threads = widget.info?.cpuThreads ?? 8;
    final devices = engine.binary?.devices ?? [];
    final hasGpu = devices.isNotEmpty;
    final gpuHw = widget.info?.gpus.where((g) => g.vendor != GpuVendor.other).toList() ?? [];

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 840),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
            child: Row(children: [
              Text('Performance & hardware', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), children: [
              _live(cs),
              const SizedBox(height: 14),
              if (widget.info != null) HardwareCard(info: widget.info!, devices: engine.binary?.devices),
              const SizedBox(height: 16),
              Text('Where should the model run?', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<PerfMode>(
                segments: [
                  const ButtonSegment(value: PerfMode.auto, label: Text('Auto'), icon: Icon(Icons.auto_awesome)),
                  ButtonSegment(value: PerfMode.gpu, label: const Text('GPU'), icon: const Icon(Icons.bolt), enabled: hasGpu),
                  const ButtonSegment(value: PerfMode.cpu, label: Text('CPU'), icon: Icon(Icons.memory)),
                  ButtonSegment(
                      value: PerfMode.custom, label: const Text('Split'), icon: const Icon(Icons.call_split), enabled: hasGpu),
                ],
                selected: {s.mode},
                onSelectionChanged: (v) => setState(() => s.mode = v.first),
              ),
              if (!hasGpu)
                _notice(
                    cs,
                    Icons.info_outline,
                    gpuHw.isEmpty ? cs.onSurfaceVariant : Colors.orangeAccent,
                    gpuHw.isEmpty
                        ? 'No GPU found – Suho runs on the CPU.'
                        : '${gpuHw.first.name} is not usable by llama.cpp right now'
                            '${gpuHw.first.note.isEmpty ? '' : ' (${gpuHw.first.note})'}. '
                            'Reboot after driver updates, then use Re-run setup → "Try GPU build".'),
              const SizedBox(height: 6),
              Text(
                switch (s.mode) {
                  PerfMode.auto => 'llama.cpp puts as many layers on the GPU as free VRAM allows.',
                  PerfMode.gpu => 'All layers on the GPU – fastest if your VRAM is big enough.',
                  PerfMode.cpu => 'Everything on the CPU – GPU stays free for games and other apps.',
                  PerfMode.custom => 'Choose how many of the $kModelLayers layers go on the GPU. The rest run on the CPU.',
                },
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
              ),
              if (s.mode == PerfMode.custom)
                _slider('GPU layers', '${s.gpuLayers} / $kModelLayers', s.gpuLayers.toDouble(), 0, kModelLayers.toDouble(),
                    kModelLayers, (v) => setState(() => s.gpuLayers = v.round())),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.lowRam,
                onChanged: (v) => setState(() {
                  s.lowRam = v;
                  if (v && s.contextSize > 2048) s.contextSize = 2048;
                }),
                title: const Text('Low-RAM mode (8 GB PCs)'),
                subtitle: Text('Smaller work buffers and no prompt cache. Uses about 1.2–1.5 GB of RAM.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ),
              _slider('CPU threads', s.threads == 0 ? 'Auto (${(threads ~/ 2).clamp(1, 16)})' : '${s.threads} / $threads',
                  s.threads.toDouble(), 0, threads.toDouble(), threads, (v) => setState(() => s.threads = v.round()),
                  hint: 'Fewer threads = lighter CPU load, slower answers.'),
              _slider('Chat memory (context)', '${s.contextSize} tokens',
                  [1024, 2048, 4096, 8192].indexOf(s.contextSize).clamp(0, 3).toDouble(), 0, 3, 3,
                  (v) => setState(() => s.contextSize = [1024, 2048, 4096, 8192][v.round()]),
                  hint: 'Bigger = remembers longer chats but uses more RAM/VRAM.'),
              _slider('Creativity (temperature)', s.temperature.toStringAsFixed(1), s.temperature, 0, 1.2, 12,
                  (v) => setState(() => s.temperature = (v * 10).round() / 10),
                  hint: 'Low = precise commands. High = more creative.'),
              const SizedBox(height: 14),
              Row(children: [
                TextButton.icon(
                    onPressed: widget.onRerunSetup, icon: const Icon(Icons.build_outlined), label: const Text('Re-run setup')),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(context, s), child: const Text('Apply')),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _live(ColorScheme cs) {
    final pct = engine.gpuPct;
    Widget tile(String label, String value, double? frac, Color c) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              const SizedBox(height: 3),
              Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              if (frac != null) ...[
                const SizedBox(height: 5),
                LinearProgressIndicator(value: frac.clamp(0, 1), color: c, borderRadius: BorderRadius.circular(4)),
              ],
            ]),
          ),
        );
    final ramTotal = widget.info?.ramTotalGb ?? 0;
    return Row(children: [
      tile(
        'Model on GPU',
        !engine.isRunning ? 'Stopped' : (pct < 0 ? 'Auto' : '$pct%'),
        pct < 0 ? null : pct / 100,
        Colors.greenAccent.shade400,
      ),
      const SizedBox(width: 8),
      tile('Engine RAM', engineRamGb == null ? 'n/a' : '${engineRamGb!.toStringAsFixed(1)} GB',
          engineRamGb == null || ramTotal == 0 ? null : engineRamGb! / ramTotal, Colors.lightBlueAccent),
      const SizedBox(width: 8),
      tile('GPU use', gpu == null ? 'n/a' : '${gpu!.utilPct}%', gpu == null ? null : gpu!.utilPct / 100,
          Colors.orangeAccent),
      const SizedBox(width: 8),
      tile('VRAM', gpu == null ? 'n/a' : '${gpu!.memUsedGb.toStringAsFixed(1)}/${gpu!.memTotalGb.toStringAsFixed(1)} GB',
          gpu == null ? null : gpu!.memUsedGb / gpu!.memTotalGb, Colors.purpleAccent.shade100),
    ]);
  }

  Widget _notice(ColorScheme cs, IconData icon, Color color, String text) => Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5))),
        ]),
      );

  Widget _slider(String label, String value, double v, double min, double max, int div, ValueChanged<double> on,
          {String? hint}) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Text(label), const Spacer(), Text(value, style: const TextStyle(fontWeight: FontWeight.w600))]),
          Slider(value: v.clamp(min, max), min: min, max: max, divisions: div, onChanged: on),
          if (hint != null)
            Text(hint, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      );
}

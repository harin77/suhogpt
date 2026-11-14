import 'package:flutter/material.dart';

import '../services/engine.dart';
import '../services/system_info.dart';

/// Shows CPU / RAM / GPU and the verdict: can this PC run the model, and on what.
class HardwareCard extends StatelessWidget {
  final SystemInfo info;
  final List<EngineDevice>? devices; // what llama.cpp can actually use
  const HardwareCard({super.key, required this.info, this.devices});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = info.verdict(engineDevices: devices);
    final (color, icon) = switch (v.mode) {
      RunMode.gpuFull => (Colors.greenAccent.shade400, Icons.bolt),
      RunMode.gpuPartial => (Colors.amberAccent.shade200, Icons.call_split),
      RunMode.cpu => (Colors.lightBlueAccent.shade100, Icons.memory),
      RunMode.tooWeak => (cs.error, Icons.warning_amber),
    };

    Widget row(IconData i, String label, String value, {String? note, Color? noteColor}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 10),
            SizedBox(width: 56, child: Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13))),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(value, style: const TextStyle(fontSize: 13)),
                if (note != null && note.isNotEmpty)
                  Text(note, style: TextStyle(fontSize: 12, color: noteColor ?? cs.onSurfaceVariant)),
              ]),
            ),
          ]),
        );

    return Card(
      color: cs.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your computer', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          row(Icons.computer, 'OS', info.osPretty),
          row(Icons.developer_board, 'CPU', '${info.cpuName}  ·  ${info.cpuThreads} threads'),
          row(Icons.sd_storage, 'RAM',
              '${info.ramTotalGb.toStringAsFixed(1)} GB total  ·  ${info.ramFreeGb.toStringAsFixed(1)} GB free'),
          if (info.gpus.isEmpty) row(Icons.videogame_asset, 'GPU', 'None detected'),
          for (final g in info.gpus)
            row(
              Icons.videogame_asset,
              'GPU',
              '${g.name}${g.vramGb > 0 ? '  ·  ${g.vramGb.toStringAsFixed(1)} GB VRAM' : ''}',
              note: _gpuNote(g),
              noteColor: _gpuOk(g) ? Colors.greenAccent.shade400 : Colors.orangeAccent,
            ),
          if (devices != null)
            row(Icons.bolt, 'llama.cpp',
                devices!.isEmpty
                    ? 'CPU only'
                    : devices!.map((d) => '${d.id}: ${d.totalGb.toStringAsFixed(1)} GB (${d.freeGb.toStringAsFixed(1)} GB free)').join('  ·  ')),
          const Divider(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(v.title, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
                  const SizedBox(height: 2),
                  Text(v.detail, style: const TextStyle(fontSize: 13)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  bool _gpuOk(GpuInfo g) {
    if (devices != null) {
      final first = g.name.toLowerCase().split(RegExp(r'[\s\[\]]+')).where((w) => w.length > 3).toList();
      return devices!.any((d) => first.any((w) => d.name.toLowerCase().contains(w)) ||
          (g.vendor == GpuVendor.nvidia && d.backend == 'CUDA'));
    }
    return g.usableByOllama;
  }

  String _gpuNote(GpuInfo g) {
    if (_gpuOk(g)) return '✓ used by llama.cpp for acceleration';
    if (g.vendor == GpuVendor.intel) return 'integrated graphics – may work through Vulkan';
    return g.note.isEmpty ? 'not usable by llama.cpp right now' : g.note;
  }
}

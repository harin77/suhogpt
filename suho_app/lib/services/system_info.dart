// Detects OS / distro, CPU, RAM and GPU (NVIDIA, AMD, Intel) on Linux and Windows,
// and decides whether the model should run on GPU, split, or CPU.
import 'dart:convert';
import 'dart:io';

import 'engine.dart';

enum GpuVendor { nvidia, amd, intel, other }

class GpuInfo {
  final GpuVendor vendor;
  final String name;
  final double vramGb; // 0 if unknown
  final bool driverWorking; // can Ollama actually use it?
  final String note;
  GpuInfo(this.vendor, this.name, this.vramGb, this.driverWorking, [this.note = '']);

  bool get usableByOllama =>
      driverWorking && (vendor == GpuVendor.nvidia || vendor == GpuVendor.amd) && vramGb >= 1.5;
}

class ModelVariant {
  final String label; // Q4_K_M / Q8_0
  final double fileGb;
  final double runtimeGb; // memory needed incl. 4k context
  const ModelVariant(this.label, this.fileGb, this.runtimeGb);
}

const q4 = ModelVariant('Q4_K_M', 1.9, 2.4);
const q8 = ModelVariant('Q8_0', 3.3, 3.8);
const kModelLayers = 37; // Qwen2.5-3B: 36 transformer layers + output layer

enum RunMode { gpuFull, gpuPartial, cpu, tooWeak }

class Verdict {
  final RunMode mode;
  final ModelVariant recommended;
  final int suggestedGpuLayers;
  final bool lowRam; // turn on Low-RAM mode (8 GB machines)
  final String title;
  final String detail;
  Verdict(this.mode, this.recommended, this.suggestedGpuLayers, this.lowRam, this.title, this.detail);
}

class SystemInfo {
  final String os; // linux / windows / other
  final String osPretty;
  final String distroId; // ubuntu, arch, fedora, ...
  final List<String> distroLike;
  final String cpuName;
  final int cpuThreads;
  final double ramTotalGb;
  final double ramFreeGb;
  final List<GpuInfo> gpus;

  SystemInfo({
    required this.os,
    required this.osPretty,
    required this.distroId,
    required this.distroLike,
    required this.cpuName,
    required this.cpuThreads,
    required this.ramTotalGb,
    required this.ramFreeGb,
    required this.gpus,
  });

  GpuInfo? get bestGpu {
    final usable = gpus.where((g) => g.usableByOllama).toList()
      ..sort((a, b) => b.vramGb.compareTo(a.vramGb));
    if (usable.isNotEmpty) return usable.first;
    return gpus.isEmpty ? null : gpus.first;
  }

  /// Decide how this machine should run the model.
  /// [engineDevices] = what llama.cpp itself can use (most reliable); falls back to our own detection.
  Verdict verdict({List<EngineDevice>? engineDevices}) {
    final lowRam = ramTotalGb > 0 && ramTotalGb <= 9.5;
    final ramNote = lowRam
        ? ' Low-RAM mode is on for your ${ramTotalGb.toStringAsFixed(0)} GB RAM (smaller buffers, 2048-token chat memory).'
        : '';
    String gpuName;
    double vram;
    var busyNote = '';
    if (engineDevices != null && engineDevices.isNotEmpty) {
      final d = engineDevices.reduce((a, b) => a.totalMiB >= b.totalMiB ? a : b);
      gpuName = '${d.name} (${d.backend})';
      vram = d.totalGb;
      if (d.freeGb < q4.runtimeGb) {
        busyNote = ' Right now only ${d.freeGb.toStringAsFixed(1)} GB VRAM is free – other apps (Ollama, games, '
            'another AI) are using it. Auto mode uses what is free; close them for full speed.';
      }
    } else {
      final g = bestGpu;
      final usable = g != null && g.usableByOllama && engineDevices == null;
      gpuName = g?.name ?? 'GPU';
      vram = usable ? g.vramGb : 0.0;
    }

    if (vram >= q8.runtimeGb + 0.6 && !lowRam) {
      return Verdict(RunMode.gpuFull, q8, 999, false, 'Full GPU – fast',
          '$gpuName (${vram.toStringAsFixed(1)} GB VRAM) can hold the whole model. Expect ~40-100+ tokens/sec.$busyNote');
    }
    if (vram >= q4.runtimeGb + 0.3) {
      return Verdict(RunMode.gpuFull, q4, 999, lowRam, 'Full GPU – fast',
          '$gpuName (${vram.toStringAsFixed(1)} GB VRAM) fits the Q4 model completely. Expect ~40-70 tokens/sec.$busyNote$ramNote');
    }
    if (vram >= 1.5) {
      final layers = ((vram - 0.6) / q4.runtimeGb * kModelLayers).floor().clamp(1, kModelLayers - 1);
      return Verdict(RunMode.gpuPartial, q4, layers, lowRam, 'GPU + CPU split',
          '$gpuName has only ${vram.toStringAsFixed(1)} GB VRAM, so about $layers of $kModelLayers layers go on the GPU and the rest on the CPU.$busyNote$ramNote');
    }
    final g = bestGpu;
    final why = g == null
        ? 'No usable GPU found'
        : (g.vendor == GpuVendor.intel
            ? '${g.name} is integrated graphics'
            : '${g.name} found, but llama.cpp cannot use it right now${g.note.isEmpty ? '' : ' (${g.note})'}');
    if (ramTotalGb >= 5.5) {
      return Verdict(RunMode.cpu, ramTotalGb >= 16 ? q8 : q4, 0, lowRam, 'CPU only – works, slower',
          '$why. The model runs on your $cpuThreads-thread CPU. Expect ~8-20 tokens/sec.$ramNote');
    }
    return Verdict(RunMode.tooWeak, q4, 0, true, 'Very low memory',
        'Only ${ramTotalGb.toStringAsFixed(1)} GB RAM. Suho needs about 2 GB free – close other apps. Low-RAM mode is on.');
  }

  static Future<SystemInfo> detect() async {
    if (Platform.isWindows) return _detectWindows();
    return _detectLinux();
  }

  // ---------------------------------------------------------------- Linux
  static Future<SystemInfo> _detectLinux() async {
    var pretty = 'Linux', id = 'linux';
    var like = <String>[];
    try {
      for (final l in await File('/etc/os-release').readAsLines()) {
        final i = l.indexOf('=');
        if (i < 0) continue;
        final k = l.substring(0, i), v = l.substring(i + 1).replaceAll('"', '');
        if (k == 'PRETTY_NAME') pretty = v;
        if (k == 'ID') id = v;
        if (k == 'ID_LIKE') like = v.split(' ');
      }
    } catch (_) {}

    var cpu = 'Unknown CPU';
    try {
      final m = RegExp(r'model name\s*:\s*(.+)').firstMatch(await File('/proc/cpuinfo').readAsString());
      if (m != null) cpu = m.group(1)!.trim();
    } catch (_) {}

    var total = 0.0, free = 0.0;
    try {
      final mem = await File('/proc/meminfo').readAsString();
      double kb(String key) =>
          double.parse(RegExp('$key:\\s+(\\d+)').firstMatch(mem)?.group(1) ?? '0') / 1024 / 1024;
      total = kb('MemTotal');
      free = kb('MemAvailable');
    } catch (_) {}

    return SystemInfo(
      os: 'linux',
      osPretty: pretty,
      distroId: id,
      distroLike: like,
      cpuName: cpu,
      cpuThreads: Platform.numberOfProcessors,
      ramTotalGb: total,
      ramFreeGb: free,
      gpus: await _linuxGpus(),
    );
  }

  static Future<List<GpuInfo>> _linuxGpus() async {
    final gpus = <GpuInfo>[];

    // NVIDIA via nvidia-smi (also proves the driver works)
    final smi = await _nvidiaSmi();
    gpus.addAll(smi);

    // Everything else from sysfs (works without any extra tools)
    final drm = Directory('/sys/class/drm');
    if (await drm.exists()) {
      final seen = <String>{};
      await for (final e in drm.list()) {
        final name = e.path.split('/').last;
        if (!RegExp(r'^card\d+$').hasMatch(name)) continue;
        final dev = '${e.path}/device';
        final vendor = (await _read('$dev/vendor')).trim();
        final pci = (await _read('$dev/uevent'));
        final slot = RegExp(r'PCI_SLOT_NAME=(\S+)').firstMatch(pci)?.group(1) ?? name;
        if (!seen.add(slot)) continue;
        final driver = RegExp(r'DRIVER=(\S+)').firstMatch(pci)?.group(1) ?? '';
        if (vendor == '0x10de') {
          if (smi.isEmpty) {
            gpus.add(GpuInfo(GpuVendor.nvidia, await _lspciName(slot, 'NVIDIA GPU'), 0, false,
                driver == 'nouveau'
                    ? 'using open-source nouveau driver – install the NVIDIA driver'
                    : 'nvidia-smi failed – reboot after a driver update, or install the NVIDIA driver'));
          }
        } else if (vendor == '0x1002') {
          final vram = double.tryParse((await _read('$dev/mem_info_vram_total')).trim()) ?? 0;
          gpus.add(GpuInfo(GpuVendor.amd, await _lspciName(slot, 'AMD GPU'), vram / 1073741824,
              driver == 'amdgpu', driver == 'amdgpu' ? '' : 'amdgpu driver not loaded'));
        } else if (vendor == '0x8086') {
          gpus.add(GpuInfo(GpuVendor.intel, await _lspciName(slot, 'Intel graphics'), 0, true,
              'integrated graphics – Ollama uses the CPU here'));
        }
      }
    }
    return gpus;
  }

  static Future<String> _lspciName(String slot, String fallback) async {
    try {
      final r = await Process.run('lspci', ['-s', slot]);
      final out = (r.stdout as String).trim();
      final i = out.indexOf(': ');
      if (r.exitCode == 0 && i > 0) {
        return out.substring(i + 2).replaceAll(RegExp(r'\s*\(rev [0-9a-f]+\)'), '');
      }
    } catch (_) {}
    return fallback;
  }

  // ---------------------------------------------------------------- Windows
  static Future<SystemInfo> _detectWindows() async {
    const ps = r'''
$ErrorActionPreference='SilentlyContinue'
$cpu=(Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$cs=Get-CimInstance Win32_ComputerSystem
$osi=Get-CimInstance Win32_OperatingSystem
$gpus=@()
$keys=Get-ChildItem 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' | Where-Object { $_.PSChildName -match '^\d{4}$' }
foreach($k in $keys){ $p=Get-ItemProperty $k.PSPath
  $mem=$p.'HardwareInformation.qwMemorySize'; if(-not $mem){$mem=$p.'HardwareInformation.MemorySize'}
  if($mem -is [byte[]]){ $mem=[BitConverter]::ToUInt32($mem,0) }
  if($p.DriverDesc){ $gpus+=@{name=$p.DriverDesc; vram=[double]$mem} } }
@{cpu=$cpu; ram=[double]$cs.TotalPhysicalMemory; free=[double]$osi.FreePhysicalMemory*1024; os=$osi.Caption; gpus=$gpus} | ConvertTo-Json -Depth 4
''';
    Map<String, dynamic> j = {};
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]);
      j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    } catch (_) {}

    final gpus = <GpuInfo>[];
    final smi = await _nvidiaSmi();
    gpus.addAll(smi);
    final list = j['gpus'] is List ? j['gpus'] as List : (j['gpus'] is Map ? [j['gpus']] : []);
    for (final g in list) {
      final name = '${g['name']}';
      final vram = ((g['vram'] ?? 0) as num).toDouble() / 1073741824;
      final low = name.toLowerCase();
      if (low.contains('nvidia')) {
        if (smi.isEmpty) {
          gpus.add(GpuInfo(GpuVendor.nvidia, name, vram, false, 'nvidia-smi not found – update the NVIDIA driver'));
        }
      } else if (low.contains('amd') || low.contains('radeon')) {
        gpus.add(GpuInfo(GpuVendor.amd, name, vram, true));
      } else if (low.contains('intel')) {
        gpus.add(GpuInfo(GpuVendor.intel, name, vram, true, 'integrated graphics – Ollama uses the CPU here'));
      } else if (!low.contains('basic') && !low.contains('virtual')) {
        gpus.add(GpuInfo(GpuVendor.other, name, vram, false, 'not supported by Ollama'));
      }
    }

    return SystemInfo(
      os: 'windows',
      osPretty: '${j['os'] ?? 'Windows'}',
      distroId: 'windows',
      distroLike: const [],
      cpuName: '${j['cpu'] ?? 'Unknown CPU'}'.trim(),
      cpuThreads: Platform.numberOfProcessors,
      ramTotalGb: ((j['ram'] ?? 0) as num).toDouble() / 1073741824,
      ramFreeGb: ((j['free'] ?? 0) as num).toDouble() / 1073741824,
      gpus: gpus,
    );
  }

  // ---------------------------------------------------------------- shared
  static Future<List<GpuInfo>> _nvidiaSmi() async {
    try {
      final r = await Process.run('nvidia-smi',
          ['--query-gpu=name,memory.total', '--format=csv,noheader,nounits']);
      if (r.exitCode != 0) return [];
      return (r.stdout as String)
          .trim()
          .split('\n')
          .where((l) => l.contains(','))
          .map((l) {
        final p = l.split(',');
        return GpuInfo(GpuVendor.nvidia, p[0].trim(), (double.tryParse(p[1].trim()) ?? 0) / 1024, true);
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<String> _read(String path) async {
    try {
      return await File(path).readAsString();
    } catch (_) {
      return '';
    }
  }
}

/// Live GPU usage (NVIDIA only – uses nvidia-smi). Returns null if not available.
class GpuLive {
  final int utilPct;
  final double memUsedGb, memTotalGb;
  GpuLive(this.utilPct, this.memUsedGb, this.memTotalGb);

  static Future<GpuLive?> read() async {
    try {
      final r = await Process.run('nvidia-smi',
          ['--query-gpu=utilization.gpu,memory.used,memory.total', '--format=csv,noheader,nounits']);
      if (r.exitCode != 0) return null;
      final p = (r.stdout as String).trim().split('\n').first.split(',');
      return GpuLive(int.parse(p[0].trim()), double.parse(p[1].trim()) / 1024, double.parse(p[2].trim()) / 1024);
    } catch (_) {
      return null;
    }
  }
}

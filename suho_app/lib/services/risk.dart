// Rule-based safety checker for Terminal mode (pure Dart, no Flutter – easy to test).
// Writes "safety comments" explaining what a command can do and blocks destructive ones.
import 'dart:io';

enum Risk { safe, caution, danger, blocked }

class SafetyNote {
  final Risk level;
  final String text;
  const SafetyNote(this.level, this.text);
}

class RiskReport {
  final Risk level;
  final List<SafetyNote> notes;
  final bool needsAdmin; // sudo / RunAs -> must run in a real terminal (password prompt)
  final bool interactive; // never ends or needs keyboard -> real terminal
  final bool hasPlaceholder; // like <ip_address> – user must edit first
  RiskReport(this.level, this.notes, this.needsAdmin, this.interactive, this.hasPlaceholder);

  bool get canRunInApp => level != Risk.blocked && !needsAdmin && !interactive && !hasPlaceholder;
}

class _Rule {
  final RegExp re;
  final Risk level;
  final String note;
  _Rule(String pattern, this.level, this.note) : re = RegExp(pattern, caseSensitive: false, multiLine: true);
}

// ------------------------------------------------------------------ Linux rules
final _linuxRules = <_Rule>[
  // BLOCKED – can destroy the system or all data
  _Rule(r'\brm\s+(-\S*\s+)*(/|/\*|~/?|\$HOME/?|/home/?|/etc/?|/usr/?|/boot/?|/var/?|/bin/?|/lib\S*)(\s|$|;)', Risk.blocked,
      'Deletes the whole system or your home folder. This can never be undone.'),
  _Rule(r'--no-preserve-root', Risk.blocked, 'Turns off the protection that stops deleting "/" (the whole system).'),
  _Rule(r':\s*\(\s*\)\s*\{.*\|.*&\s*\}\s*;', Risk.blocked, 'Fork bomb: starts processes forever until the PC freezes.'),
  _Rule(r'\bmkfs(\.\w+)?\b|\bwipefs\b|\bmkswap\s+/dev/', Risk.blocked, 'Formats a disk/partition – erases everything on it.'),
  _Rule(r'\bdd\b[^\n]*\bof=/dev/(sd|nvme|hd|vd|mmcblk|disk)', Risk.blocked, 'Writes raw data over a whole disk – erases it.'),
  _Rule(r'>\s*/dev/(sd|nvme|hd|vd|mmcblk)\w*', Risk.blocked, 'Overwrites a disk directly – destroys its data.'),
  _Rule(r'\bshred\b[^\n]*/dev/', Risk.blocked, 'Securely erases a whole disk.'),
  _Rule(r'\bchmod\s+(-\S*\s+)*-?R\S*\s+[0-7]*7[0-7]*\s+/(\s|$)|\bchown\s+-R\S*\s+\S+\s+/(\s|$)', Risk.blocked,
      'Changes permissions/owner of the entire system – breaks Linux.'),
  // DANGER
  _Rule(r'\brm\b[^\n]*\s-\S*r', Risk.danger, 'rm -r deletes folders and everything inside them. Linux has no recycle bin.'),
  _Rule(r'\brm\b', Risk.danger, 'rm deletes files permanently – they do not go to the trash.'),
  _Rule(r'\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(ba|z)?sh\b', Risk.danger,
      'Downloads a script from the internet and runs it immediately. Only do this for sources you trust.'),
  _Rule(r'\b(shutdown|reboot|poweroff|halt)\b|\binit\s+[06]\b|systemctl\s+(reboot|poweroff|halt)', Risk.danger,
      'Shuts down or restarts the computer – save your work first.'),
  _Rule(r'\b(kill|killall|pkill)\b', Risk.danger, 'Stops running programs – unsaved work in them is lost.'),
  _Rule(r'systemctl\s+(stop|disable|mask|restart)\b', Risk.danger, 'Stops/changes a system service – things that depend on it may break.'),
  _Rule(r'\b(apt|apt-get|dnf|yum|zypper)\s+(remove|purge|autoremove|erase)\b|\bpacman\s+-R', Risk.danger,
      'Removes installed software (and maybe things that depend on it).'),
  _Rule(r'\biptables\s+-F|\bnft\s+flush|\bufw\s+disable|\bsetenforce\s+0|systemctl\s+\w+\s+(firewalld|apparmor)', Risk.danger,
      'Turns off firewall / security protection.'),
  _Rule(r'\bhistory\s+-c|unset\s+HISTFILE|HISTSIZE=0', Risk.danger, 'Hides or wipes your command history.'),
  _Rule(r'\bchmod\b[^\n]*\b777\b', Risk.danger, 'chmod 777 lets ANY user change or run the file – a security risk.'),
  _Rule(r'\b(nmap|masscan|hydra|sqlmap|nikto|metasploit|msfconsole|john|hashcat|aircrack-ng)\b', Risk.danger,
      'Security/attack tool – only use it on systems you own or have written permission to test. Scanning others is illegal.'),
  _Rule(r'\bgit\s+(reset\s+--hard|clean\s+-\S*f|push\s+(-f|--force))', Risk.danger, 'Throws away git changes or rewrites history.'),
  // CAUTION
  _Rule(r'\bsudo\b|\bpkexec\b|\bsu\s', Risk.caution, 'Runs as root (administrator) – it can change anything on the system.'),
  _Rule(r'(?<![2&\d])>(?!&)\s*[\w./~$]', Risk.caution, '">" overwrites the target file if it already exists.'),
  _Rule(r'\bmv\b', Risk.caution, 'mv can silently overwrite a file with the same name.'),
  _Rule(r'\b(apt|apt-get|dnf|yum|zypper|snap|flatpak)\s+(install|update|upgrade)\b|\bpacman\s+-S', Risk.caution,
      'Installs or updates software on your system.'),
  _Rule(r'\bpip3?\s+install\b|\bnpm\s+(i|install)\s+-g\b', Risk.caution, 'Installs packages from the internet.'),
  _Rule(r'\bchmod\b|\bchown\b', Risk.caution, 'Changes who can read/write/run files.'),
  _Rule(r'\bcrontab\s+-r\b', Risk.caution, 'Deletes all your scheduled cron jobs.'),
];

// ------------------------------------------------------------------ Windows rules
final _windowsRules = <_Rule>[
  _Rule(r'\bFormat-Volume\b|\bformat\s+[a-z]:|\bdiskpart\b|\bClear-Disk\b|\bInitialize-Disk\b', Risk.blocked,
      'Formats/erases a disk.'),
  _Rule(r'(Remove-Item|\bri\b|\brm\b|\bdel\b|\berase\b|\brd\b|\brmdir\b)[^\n]*([a-z]:\\?\s*$|[a-z]:\\\*|[a-z]:\\(Windows|Program Files|Users)\b|\$env:(SystemRoot|windir|USERPROFILE)\s*$)',
      Risk.blocked, 'Deletes Windows, Program Files, a whole drive or your user folder.'),
  _Rule(r'\bbcdedit\b|vssadmin\s+delete\s+shadows|wbadmin\s+delete', Risk.blocked,
      'Changes boot settings or deletes system backups (ransomware-style).'),
  _Rule(r'\b(Remove-Item|ri|rm|del|erase|rd|rmdir)\b[^\n]*-Recurse', Risk.danger,
      'Deletes a folder and everything inside it. Files skip the Recycle Bin.'),
  _Rule(r'\b(Remove-Item|ri|del|erase|rd|rmdir)\b', Risk.danger, 'Deletes files permanently (no Recycle Bin).'),
  _Rule(r'\b(Stop-Process|taskkill|kill|spps)\b', Risk.danger, 'Stops running programs – unsaved work is lost.'),
  _Rule(r'\b(Restart-Computer|Stop-Computer|shutdown)\b', Risk.danger, 'Restarts or shuts down the PC.'),
  _Rule(r'Set-ExecutionPolicy\s+(Unrestricted|Bypass)', Risk.danger, 'Allows ALL scripts to run – lowers Windows security.'),
  _Rule(r'Set-MpPreference[^\n]*Disable|Disable-NetFirewall|Set-NetFirewallProfile[^\n]*False|netsh\s+advfirewall\s+set[^\n]*off',
      Risk.danger, 'Turns off Windows Defender or the firewall.'),
  _Rule(r'\breg\s+(delete|add)\b|Remove-ItemProperty|Set-ItemProperty[^\n]*HK(LM|CU)', Risk.danger,
      'Edits the Windows registry – wrong changes can break Windows.'),
  _Rule(r'\b(iex|Invoke-Expression)\b|DownloadString|\|\s*iex', Risk.danger,
      'Runs code downloaded/built at runtime. Only for sources you trust.'),
  _Rule(r'Clear-History|Clear-EventLog|wevtutil\s+cl', Risk.danger, 'Deletes history or Windows event logs.'),
  _Rule(r'\b(nmap|masscan|hydra|sqlmap|nikto|hashcat|mimikatz)\b', Risk.danger,
      'Security/attack tool – only on systems you own or have written permission to test.'),
  _Rule(r'-Verb\s+RunAs|\brunas\b', Risk.caution, 'Runs as Administrator.'),
  _Rule(r'\b(winget|choco|scoop)\s+(install|upgrade)|Install-Module|Install-Package', Risk.caution,
      'Installs software from the internet.'),
  _Rule(r'\b(Set-Content|Out-File|Add-Content)\b|(?<![2&\d])>(?!&)', Risk.caution, 'Writes to (and may overwrite) a file.'),
  _Rule(r'\b(Move-Item|Rename-Item|mv|move)\b', Risk.caution, 'Moves/renames files – can overwrite existing ones.'),
];

final _linuxInteractive = RegExp(
    r'^\s*(sudo\s+)?(top|htop|btop|vim?|nvim|nano|emacs|less|more|man|watch|mc|ranger|journalctl\s+-f|tail\s+-\S*f|ping(?![^\n]*\s-c\s*\d)|ssh(\s+\S+)?\s*$|python3?\s*$|bash\s*$|mysql|psql|ftp|telnet|nc\s+-l|passwd|tmux|screen)\b',
    multiLine: true);
final _windowsInteractive =
    RegExp(r'^\s*(notepad|vim|nano|ssh(\s+\S+)?\s*$|ping\s+[^\n]*-t\b|Get-Content[^\n]*-Wait|python\s*$|powershell\s*$)', caseSensitive: false, multiLine: true);

RiskReport analyzeCommand(String cmd) {
  final win = Platform.isWindows;
  // Ignore comment text so "# deletes old logs" doesn't trigger rules
  final code = cmd.split('\n').map((l) {
    final i = l.indexOf(RegExp(r'(^|\s)#'));
    return i < 0 ? l : l.substring(0, i);
  }).join('\n');

  final notes = <SafetyNote>[];
  var level = Risk.safe;
  for (final r in win ? _windowsRules : _linuxRules) {
    if (r.re.hasMatch(code) && !notes.any((n) => n.text == r.note)) {
      notes.add(SafetyNote(r.level, r.note));
      if (r.level.index > level.index) level = r.level;
    }
  }
  final needsAdmin = win
      ? RegExp(r'-Verb\s+RunAs|\brunas\b', caseSensitive: false).hasMatch(code)
      : RegExp(r'(^|[;&|]\s*)(sudo|pkexec|su)\b', multiLine: true).hasMatch(code);
  final interactive = (win ? _windowsInteractive : _linuxInteractive).hasMatch(code);
  final placeholder = RegExp(r'<[a-zA-Z_][\w\s-]*>|\bYOUR_\w+|example\.com\b').hasMatch(code);

  if (needsAdmin) {
    notes.add(const SafetyNote(Risk.caution,
        'Needs your admin password, so it opens in a real terminal where you type the password yourself.'));
  }
  if (interactive) {
    notes.add(const SafetyNote(Risk.caution,
        'Interactive or never-ending command (editor, top, ping, tail -f…) – it opens in a terminal window instead.'));
  }
  if (placeholder) {
    notes.add(const SafetyNote(Risk.caution, 'Contains a placeholder like <ip_address> – replace it with a real value first.'));
  }
  if (notes.isEmpty) {
    notes.add(const SafetyNote(Risk.safe, 'No risky patterns found. Still read it – you are responsible for what runs.'));
  }
  return RiskReport(level, notes, needsAdmin, interactive, placeholder);
}

/// Languages of code blocks that can be run on this OS.
bool isRunnableLang(String lang) {
  final l = lang.toLowerCase().trim();
  return Platform.isWindows
      ? const {'powershell', 'ps', 'ps1', 'pwsh', 'cmd', 'bat'}.contains(l)
      : const {'bash', 'sh', 'shell', 'zsh', 'console', 'terminal'}.contains(l);
}

/// Remove "$ " prompts that models often put in front of commands.
String cleanCommand(String code) => code
    .split('\n')
    .map((l) => l.replaceFirst(RegExp(r'^\s*(\$|PS [^>]*>|>)\s+'), ''))
    .join('\n')
    .trim();


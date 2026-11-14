#!/usr/bin/env bash
# Installs Suho AI for the current user on any Linux distro.
#   ./install_linux.sh [path/to/model.gguf]   (or put the .gguf in ./models first)
# - installs the few system libraries the app needs (GTK3 + zenity for the file picker)
# - copies the app to ~/.local/share/suho-ai and adds a menu entry + `suho-ai` command
# - optionally copies the model next to the app so the setup wizard finds it automatically
# Ollama itself is installed from inside the app (Setup -> "Set up everything").
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$HERE/bundle"
[ -x "$BUNDLE/suho_ai" ] || BUNDLE="$HERE/../build/linux/x64/release/bundle"
[ -x "$BUNDLE/suho_ai" ] || { echo "❌ App bundle not found (run 'flutter build linux --release' first)"; exit 1; }

DEST="$HOME/.local/share/suho-ai"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo "== Checking system libraries =="
need=""
(ldconfig -p 2>/dev/null | grep -q libgtk-3.so.0 || [ -e /usr/lib/libgtk-3.so.0 ] || [ -e /usr/lib64/libgtk-3.so.0 ] \
  || [ -e /usr/lib/x86_64-linux-gnu/libgtk-3.so.0 ]) || need="$need gtk3"
command -v curl >/dev/null || need="$need curl"
command -v zenity >/dev/null || command -v kdialog >/dev/null || need="$need zenity"   # file picker (optional)

install_deps() {
  local gtk=gtk3 z=zenity
  if   command -v apt-get >/dev/null; then $SUDO apt-get update -qq && $SUDO apt-get install -y ${need//gtk3/libgtk-3-0}
  elif command -v dnf     >/dev/null; then $SUDO dnf install -y $need
  elif command -v yum     >/dev/null; then $SUDO yum install -y $need
  elif command -v pacman  >/dev/null; then $SUDO pacman -S --needed --noconfirm $need
  elif command -v zypper  >/dev/null; then $SUDO zypper --non-interactive install $need
  elif command -v apk     >/dev/null; then $SUDO apk add ${need//gtk3/gtk+3.0}
  elif command -v xbps-install >/dev/null; then $SUDO xbps-install -Sy ${need//gtk3/gtk+3}
  else return 1; fi
}

if [ -z "$need" ]; then
  echo "already installed ✓"
else
  echo "missing:$need"
  if ! install_deps; then
    if [[ "$need" == *gtk3* ]]; then echo "❌ GTK3 is required. Install it with your package manager and re-run."; exit 1; fi
    echo "⚠️ Could not install:$need (optional – only the 'Browse' file picker needs zenity). Continuing."
  fi
fi

echo "== Copying app to $DEST =="
rm -rf "$DEST"
mkdir -p "$DEST" "$HOME/.local/bin" "$HOME/.local/share/applications"
cp -r "$BUNDLE/." "$DEST/"
ln -sf "$DEST/suho_ai" "$HOME/.local/bin/suho-ai"

MODEL="${1:-}"
[ -z "$MODEL" ] && MODEL="$(ls "$HERE"/models/*.gguf 2>/dev/null | head -1 || true)"
if [ -n "$MODEL" ]; then
  echo "== Copying model $(basename "$MODEL") =="
  mkdir -p "$DEST/models"
  cp "$MODEL" "$DEST/models/"
fi

echo "== Adding icon, app-menu entry and desktop shortcut =="
for sz in 16 24 32 48 64 128 256 512; do
  src="$HERE/icons/suho_$sz.png"; [ -f "$src" ] || src="$HERE/../assets/icon/suho_$sz.png"
  [ -f "$src" ] || continue
  mkdir -p "$HOME/.local/share/icons/hicolor/${sz}x${sz}/apps"
  cp "$src" "$HOME/.local/share/icons/hicolor/${sz}x${sz}/apps/suho-ai.png"
done
if [ ! -f "$HOME/.local/share/icons/hicolor/256x256/apps/suho-ai.png" ]; then
  mkdir -p "$HOME/.local/share/icons/hicolor/256x256/apps"
  cp "$DEST/data/suho.png" "$HOME/.local/share/icons/hicolor/256x256/apps/suho-ai.png"
fi

# File name = the app's Wayland app_id, so GNOME/KDE docks show the icon on the running window.
DESKTOP_FILE="$HOME/.local/share/applications/ai.suho.suho_ai.desktop"
rm -f "$HOME/.local/share/applications/suho-ai.desktop"
cat > "$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Name=Suho AI
GenericName=AI Assistant
Comment=Offline Tanglish Linux / coding / cybersecurity assistant
Exec=$DEST/suho_ai
Icon=suho-ai
Terminal=false
Type=Application
Categories=Development;
Keywords=AI;chat;linux;security;tanglish;
StartupWMClass=ai.suho.suho_ai
DESKTOP
chmod +x "$DESKTOP_FILE"
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" || true

# Desktop shortcut (GNOME needs a desktop-icons extension; KDE/XFCE/Cinnamon/MATE show it directly)
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
if [ -d "$DESKTOP_DIR" ]; then
  cp "$DESKTOP_FILE" "$DESKTOP_DIR/suho-ai.desktop"
  chmod +x "$DESKTOP_DIR/suho-ai.desktop"
  command -v gio >/dev/null && gio set "$DESKTOP_DIR/suho-ai.desktop" metadata::trusted true 2>/dev/null || true
fi

echo "✅ Installed. Open 'Suho AI' from your app menu, or run: suho-ai"

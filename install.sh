#!/bin/bash
# Builds the Teams window (the host) and installs it for the current user.
# The Omarchy plugin itself needs no build; `omarchy plugin add` clones it and
# this script adds the one native piece the shell cannot provide.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
prefix="$data_home/omateams"
bindir="$prefix/bin"
build="${XDG_CACHE_HOME:-$HOME/.cache}/omateams/build"

usage() {
  cat <<USAGE
Usage: install.sh [--uninstall] [--no-deps]

Builds the omateams host from ./host with qmake6 and installs it to
$bindir (plus a symlink in ~/.local/bin), a desktop entry and an icon.
  --uninstall   remove everything install.sh created (keeps the Teams profile)
  --no-deps     skip the pacman dependency check
USAGE
}

install_deps=1
for arg in "$@"; do
  case "$arg" in
    --uninstall) exec "$here/uninstall.sh" ;;
    --no-deps) install_deps=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if (( install_deps )) && command -v pacman >/dev/null; then
  need=()
  for pkg in qt6-webengine qt6-declarative libnotify jq; do
    pacman -Qi "$pkg" &>/dev/null || need+=("$pkg")
  done
  { command -v g++ >/dev/null && command -v make >/dev/null; } || need+=(base-devel)
  if (( ${#need[@]} )); then
    echo "Installing build dependencies: ${need[*]}"
    sudo pacman -S --needed --noconfirm "${need[@]}"
  fi
fi

qmake=$(command -v qmake6 || true)
[[ -n $qmake ]] || qmake=/usr/lib/qt6/bin/qmake6
[[ -x $qmake ]] || { echo "install.sh: qmake6 not found (install qt6-base)" >&2; exit 1; }

version=$(jq -r '.version // "dev"' "$here/manifest.json" 2>/dev/null || echo dev)
echo "Building omateams $version ..."
mkdir -p "$build"
(
  cd "$build"
  "$qmake" "OMATEAMS_VERSION=$version" "$here/host/omateams.pro" >/dev/null
  make -j"$(nproc)" >/dev/null
)

# A running instance keeps the old binary mapped; stop it before replacing.
if [[ -x $bindir/omateams ]] && "$bindir/omateams" status 2>/dev/null | grep -q '"running":true'; then
  echo "Stopping the running Teams window ..."
  "$bindir/omateams" quit || true
  sleep 1
fi

install -Dm755 "$build/omateams" "$bindir/omateams"
mkdir -p "$HOME/.local/bin"
ln -sfn "$bindir/omateams" "$HOME/.local/bin/omateams"

# The icon is drawn in placeholder colors; recolor it from the active theme so
# the launcher tile matches the desktop. Icon caches mean a later theme switch
# shows the new colors after the next install.sh run (or `omateams icon`).
icon_dir="$data_home/icons/hicolor"
"$here/scripts/theme-icon.sh" "$here/assets/omateams.svg" "$build/omateams.svg"
install -Dm644 "$build/omateams.svg" "$icon_dir/scalable/apps/omateams.svg"
if command -v rsvg-convert >/dev/null; then
  mkdir -p "$icon_dir/256x256/apps"
  rsvg-convert -w 256 -h 256 "$build/omateams.svg" -o "$icon_dir/256x256/apps/omateams.png"
fi
gtk-update-icon-cache -q "$icon_dir" 2>/dev/null || true

mkdir -p "$data_home/applications"
sed "s|^Exec=omateams|Exec=$bindir/omateams|" "$here/assets/omateams.desktop" > "$data_home/applications/omateams.desktop"
update-desktop-database -q "$data_home/applications" 2>/dev/null || true

mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/omateams"

echo "Installed $bindir/omateams"
if [[ $here == "$HOME/.config/omarchy/plugins/"* ]]; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  echo "Enable the bar widget with:  omarchy plugin enable omateams"
else
  echo "Add the bar widget with:     omarchy plugin add https://github.com/Divanyx/omateams.git --enable"
fi
echo "Open Teams with:             omateams"

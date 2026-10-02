#!/bin/bash
# Builds the Teams window (the host) and installs it for the current user.
# The Omarchy plugin itself needs no build; `omarchy plugin add` clones it and
# its service runs this script with --if-needed when the shell loads it, which
# adds the one native piece the shell cannot provide. Running it by hand does
# the same and also installs missing build dependencies with pacman.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
prefix="$data_home/omateams"
bindir="$prefix/bin"
build="${XDG_CACHE_HOME:-$HOME/.cache}/omateams/build"

usage() {
  cat <<USAGE
Usage: install.sh [--uninstall] [--no-deps] [--if-needed]

Builds the omateams host from ./host with qmake6 and installs it to
$bindir (plus a symlink in ~/.local/bin), a desktop entry and an icon.
  --uninstall   remove everything install.sh created (keeps the Teams profile)
  --no-deps     skip the pacman dependency check
  --if-needed   build only when the sources or Qt changed since the last build;
                never prompts; exits 0 when the host is already current,
                10 after building it, 3 when build dependencies are missing
                (this is what the plugin runs when the shell loads it)
USAGE
}

install_deps=1
if_needed=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) exec "$here/uninstall.sh" ;;
    --no-deps) install_deps=0 ;;
    --if-needed) if_needed=1; install_deps=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

need=()
if command -v pacman >/dev/null; then
  for pkg in qt6-webengine qt6-declarative libnotify jq; do
    pacman -Qi "$pkg" &>/dev/null || need+=("$pkg")
  done
fi
{ command -v g++ >/dev/null && command -v make >/dev/null; } || need+=(base-devel)
if (( ${#need[@]} )); then
  if (( if_needed )); then
    echo "install.sh: missing build dependencies: ${need[*]}" >&2
    exit 3
  fi
  if (( install_deps )) && command -v pacman >/dev/null; then
    echo "Installing build dependencies: ${need[*]}"
    sudo pacman -S --needed --noconfirm "${need[@]}"
  fi
fi

qmake=$(command -v qmake6 || true)
[[ -n $qmake ]] || qmake=/usr/lib/qt6/bin/qmake6
[[ -x $qmake ]] || { echo "install.sh: qmake6 not found (install qt6-base)" >&2; exit 1; }

version=$(jq -r '.version // "dev"' "$here/manifest.json" 2>/dev/null || echo dev)

# The stamp names everything the binary depends on: the plugin version, the
# host sources and the Qt it was linked against. A plugin update or a Qt
# upgrade changes it, and the plugin's service then rebuilds on the next load.
stamp_file="$prefix/build-stamp"
stamp=$(
  {
    echo "$version"
    "$qmake" -query QT_VERSION
    cd "$here" && find host assets scripts manifest.json install.sh -type f -print0 | sort -z | xargs -0 sha256sum
  } | sha256sum | cut -d' ' -f1
)
if (( if_needed )) && [[ -x $bindir/omateams && -f $stamp_file && $(<"$stamp_file") == "$stamp" ]]; then
  exit 0
fi

echo "Building omateams $version ..."
# Always from scratch: make does not notice a changed qmake define such as the
# version, and an object built against an older Qt must not be reused.
rm -rf "$build"
mkdir -p "$build"
(
  cd "$build"
  "$qmake" "OMATEAMS_VERSION=$version" "$here/host/omateams.pro" >/dev/null
  make -j"$(nproc)" >/dev/null
)

# A running instance keeps the old binary mapped; stop it before replacing.
# The automatic build leaves it alone: install writes a new file, so the open
# window keeps working and picks up the new host on its next start.
if (( ! if_needed )) && [[ -x $bindir/omateams ]] && "$bindir/omateams" status 2>/dev/null | grep -q '"running":true'; then
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
printf '%s\n' "$stamp" > "$stamp_file"

echo "Installed $bindir/omateams"
(( if_needed )) && exit 10
if [[ $here == "$HOME/.config/omarchy/plugins/"* ]]; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  echo "Enable the bar widget with:  omarchy plugin enable omateams"
else
  echo "Add the bar widget with:     omarchy plugin add https://github.com/Divanyx/omateams.git --enable"
fi
echo "Open Teams with:             omateams"

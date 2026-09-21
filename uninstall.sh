#!/bin/bash
# Removes what install.sh created. The signed-in Teams profile under
# ~/.local/share/omateams/QtWebEngine stays unless --purge is given.
set -euo pipefail

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
prefix="$data_home/omateams"
purge=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    -h|--help) echo "Usage: uninstall.sh [--purge]   (--purge also deletes the signed-in profile and settings)"; exit 0 ;;
    *) echo "uninstall.sh: unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ -x $prefix/bin/omateams ]]; then
  "$prefix/bin/omateams" quit 2>/dev/null || true
fi

rm -f "$HOME/.local/bin/omateams"
rm -f "$data_home/applications/omateams.desktop"
rm -f "$data_home/icons/hicolor/scalable/apps/omateams.svg" "$data_home/icons/hicolor/256x256/apps/omateams.png"
gtk-update-icon-cache -q "$data_home/icons/hicolor" 2>/dev/null || true
update-desktop-database -q "$data_home/applications" 2>/dev/null || true
rm -rf "$prefix/bin" "${XDG_CACHE_HOME:-$HOME/.cache}/omateams"
rm -rf "${XDG_RUNTIME_DIR:-/tmp}/omateams"

if (( purge )); then
  rm -rf "$prefix" "${XDG_CONFIG_HOME:-$HOME/.config}/omateams" "${XDG_STATE_HOME:-$HOME/.local/state}/omateams"
  echo "Removed the host, the Teams profile and the settings."
else
  echo "Removed the host. The Teams profile stays in $prefix (delete with --purge)."
fi
echo "Remove the bar widget with:  omarchy plugin remove omateams"

#!/bin/bash
# Recolor the placeholder icon from the active Omarchy theme.
# Usage: theme-icon.sh <source.svg> <output.svg>
set -euo pipefail

src="$1"
out="$2"
colors="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/colors.toml"

# Reads `key = "#rrggbb"` from colors.toml; falls back to the placeholder.
theme_color() {
  local key="$1" fallback="$2" value=""
  if [[ -r $colors ]]; then
    value=$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[\"']?(#[0-9A-Fa-f]{6}).*/\\1/p" "$colors" | head -1)
  fi
  printf '%s' "${value:-$fallback}"
}

background=$(theme_color background "#10131a")
accent=$(theme_color accent "#9ece6a")
foreground=$(theme_color foreground "#dbe3ea")
dim=$(theme_color dark_foreground "$(theme_color muted "#6f7a8a")")

sed -e "s/#10131a/$background/g" -e "s/#9ece6a/$accent/g" -e "s/#dbe3ea/$foreground/g" -e "s/#6f7a8a/$dim/g" "$src" > "$out"

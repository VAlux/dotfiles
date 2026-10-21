#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_SRC="$DOTFILES_DIR/claude"
CLAUDE_DST="$HOME/.claude"
NVIM_SRC="$DOTFILES_DIR/nvim"
NVIM_DST="$HOME/.config/nvim"
GHOSTTY_SRC="$DOTFILES_DIR/ghostty"
GHOSTTY_DST="$HOME/.config/ghostty"
TUIOS_SRC="$DOTFILES_DIR/tuios"
# tuios uses the OS config dir: ~/Library/Application Support on macOS, $XDG_CONFIG_HOME elsewhere
if command -v tuios >/dev/null 2>&1; then
  TUIOS_DST="$(dirname "$(tuios config path)")"
elif [[ "$(uname)" == "Darwin" ]]; then
  TUIOS_DST="$HOME/Library/Application Support/tuios"
else
  TUIOS_DST="${XDG_CONFIG_HOME:-$HOME/.config}/tuios"
fi

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn()   { echo -e "${YELLOW}[bootstrap]${NC} $*"; }

# Back up an existing regular file before replacing it
backup_if_file() {
  local target="$1"
  if [[ -e "$target" && ! -L "$target" ]]; then
    local backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
    warn "Backing up existing file: $target → $backup"
    mv "$target" "$backup"
  fi
}

# Create a symlink, backing up any plain file that's in the way
make_link() {
  local src="$1"
  local dst="$2"

  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    log "Already linked: $dst"
    return
  fi

  backup_if_file "$dst"
  ln -sf "$src" "$dst"
  log "Linked: $dst → $src"
}

# ── settings.json (generated from template — contains $HOME path) ────────────
SETTINGS_DST="$CLAUDE_DST/settings.json"
backup_if_file "$SETTINGS_DST"
sed "s|__HOME__|$HOME|g" "$CLAUDE_SRC/settings.json.template" > "$SETTINGS_DST"
log "Generated: $SETTINGS_DST"

# ── symlinked files ──────────────────────────────────────────────────────────
make_link "$CLAUDE_SRC/keybindings.json"        "$CLAUDE_DST/keybindings.json"
make_link "$CLAUDE_SRC/statusline-command.sh"   "$CLAUDE_DST/statusline-command.sh"

# ── scripts directory ────────────────────────────────────────────────────────
mkdir -p "$CLAUDE_DST/scripts"
for script in "$CLAUDE_SRC/scripts/"*; do
  [[ -f "$script" ]] || continue
  make_link "$script" "$CLAUDE_DST/scripts/$(basename "$script")"
done

log "Done. Claude Code config is in sync."

# ════════════════════════════════════════════════════════════════════════════
# Neovim
# ════════════════════════════════════════════════════════════════════════════

# Symlink the whole config directory so new plugin files are tracked automatically
if [[ -d "$NVIM_DST" && ! -L "$NVIM_DST" ]]; then
  nvim_backup="$NVIM_DST.bak.$(date +%Y%m%d%H%M%S)"
  warn "Backing up existing directory: $NVIM_DST → $nvim_backup"
  mv "$NVIM_DST" "$nvim_backup"
fi
make_link "$NVIM_SRC" "$NVIM_DST"

# pack/ is excluded from dotfiles — clone manually-managed plugins if absent
COPILOT_DIR="$NVIM_SRC/pack/github/start/copilot.vim"
if [[ ! -d "$COPILOT_DIR" ]]; then
  log "Cloning copilot.vim..."
  mkdir -p "$NVIM_SRC/pack/github/start"
  git clone --depth 1 https://github.com/github/copilot.vim "$COPILOT_DIR"
else
  log "copilot.vim already present: $COPILOT_DIR"
fi

log "Done. Neovim config is in sync."

# ════════════════════════════════════════════════════════════════════════════
# Ghostty
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$GHOSTTY_DST"
make_link "$GHOSTTY_SRC/config" "$GHOSTTY_DST/config"

log "Done. Ghostty config is in sync."

# ════════════════════════════════════════════════════════════════════════════
# TUIOS
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$TUIOS_DST"
make_link "$TUIOS_SRC/config.toml" "$TUIOS_DST/config.toml"

log "Done. TUIOS config is in sync."

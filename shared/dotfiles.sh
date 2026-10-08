#!/usr/bin/env bash
# Dotfile symlinking -- shared by macOS and Ubuntu.
#
# This file contains no OS-specific logic. It is sourced by mac/dotfiles.sh and
# linux/dotfiles.sh, which may set EXTRA_CONFIG_DIRS to a list of additional
# directories whose entries should also be linked into ~/.config (macOS uses
# this for mac/configs/.config).
#
# ── What it does ──────────────────────────────────────────────────────────────
# 1. Backs up any existing non-symlink file before replacing it.
# 2. Symlinks each top-level dotfile in dotfiles/ -> $HOME/
# 3. Symlinks each dotfiles/.config/* entry individually. It never symlinks
#    ~/.config itself, because other tools own entries in there.
#
# Safe to re-run: idempotent.

BACKUP_ROOT="$HOME/.local/state/machinist/dotfiles-backups/$(date +%Y%m%d-%H%M%S)"
BACKED_UP_ANY=0

backup_target() {
    local target="$1"
    local relative="${target#"$HOME"/}"
    local backup_path="$BACKUP_ROOT/$relative"

    [[ ! -e "$target" && ! -L "$target" ]] && return 0

    # Skip symlinks that already point into this repo.
    #
    # Compared against REPO_ROOT rather than DOTFILES_DIR: platform-specific
    # configs can live outside dotfiles/, and matching only DOTFILES_DIR meant
    # those were re-copied into a fresh backup directory on every run.
    #
    # Plain readlink, not `readlink -f`: BSD readlink on macOS has no -f, and
    # the links we create point straight at their target, so one level is both
    # sufficient and portable.
    if [[ -L "$target" ]] && \
       [[ "$(readlink "$target" 2>/dev/null)" == "$REPO_ROOT"* ]]; then
        return 0
    fi

    # Created lazily: a re-run on an already-linked machine backs nothing up,
    # and an empty timestamped directory per run is just churn.
    mkdir -p "$BACKUP_ROOT" "$(dirname "$backup_path")"
    cp -a "$target" "$backup_path"
    BACKED_UP_ANY=1
}

link_path() {
    local source_path="$1"
    local target_path="$2"

    backup_target "$target_path"
    mkdir -p "$(dirname "$target_path")"
    rm -rf "$target_path"
    ln -sf "$source_path" "$target_path"
    log_success "Linked $(basename "$target_path")"
}

# Link every entry of $1 into ~/.config/.
link_config_entries() {
    local config_source="$1"
    local config_target="$HOME/.config"

    [[ -d "$config_source" ]] || return 0
    mkdir -p "$config_target"

    shopt -s dotglob nullglob
    local item name
    for item in "$config_source"/*; do
        name="$(basename "$item")"
        link_path "$item" "$config_target/$name"
    done
    shopt -u dotglob nullglob
}

install_home_dotfiles() {
    shopt -s dotglob nullglob
    local path name
    for path in "$DOTFILES_DIR"/*; do
        name="$(basename "$path")"

        # Handled separately by link_config_entries.
        [[ "$name" == ".config" ]] && continue
        # The dotfiles dir's own .gitignore is internal to this repo. The global
        # gitignore is .gitignore_global, referenced from .gitconfig.
        [[ "$name" == ".gitignore" ]] && continue
        # macOS drops these into any directory Finder has visited.
        [[ "$name" == ".DS_Store" ]] && continue

        link_path "$path" "$HOME/$name"
    done
    shopt -u dotglob nullglob
}

install_dotfiles() {
    if [[ ! -d "$DOTFILES_DIR" ]]; then
        log_error "dotfiles/ directory not found at $DOTFILES_DIR"
        log_info "Ensure you cloned the full repo: git clone git@github.com:burakdede/machinist.git"
        exit 1
    fi

    echo_header "Dotfiles"

    install_home_dotfiles
    link_config_entries "$DOTFILES_DIR/.config"

    # Platform-specific config dirs, e.g. mac/configs/.config.
    local extra
    for extra in ${EXTRA_CONFIG_DIRS:-}; do
        link_config_entries "$extra"
    done

    trust_repo_mise_config

    mkdir -p "$HOME/.git_template"
    log_success "Created ~/.git_template (required by init.templateDir in .gitconfig)"
    if [[ "${BACKED_UP_ANY:-0}" -eq 1 ]]; then
        log_info "Replaced files were backed up to $BACKUP_ROOT"
    else
        log_info "Nothing needed backing up; all targets were already our symlinks."
    fi
}

# mise discovers config by walking UP from the current directory, looking for
# .config/mise/config.toml in each ancestor. Our copy lives at
# <repo>/dotfiles/.config/mise/config.toml, so the moment you cd into the
# dotfiles directory to edit something -- the workflow this repo is built
# around -- mise finds it as a PROJECT config rather than the global one.
#
# Project configs require explicit trust, while ~/.config/mise/config.toml is
# trusted implicitly. Without this, every command run from inside the repo
# fails with "Config files ... are not trusted".
#
# Trust is recorded per machine under ~/.local/state/mise/trusted-configs, so
# it is not something that can be committed; it has to be granted at setup.
trust_repo_mise_config() {
    local mise_config="$DOTFILES_DIR/.config/mise/config.toml"

    [[ -f "$mise_config" ]] || return 0

    local mise_bin="$HOME/.local/bin/mise"
    [[ -x "$mise_bin" ]] || mise_bin="$(command -v mise 2>/dev/null || true)"
    if [[ -z "$mise_bin" ]]; then
        log_info "mise not installed yet; skipping trust. Re-run this step after the system step."
        return 0
    fi

    if "$mise_bin" trust "$mise_config" >/dev/null 2>&1; then
        log_success "Trusted the repo mise config for this machine"
    else
        log_warn "Could not trust $mise_config."
        log_warn "Run it by hand: mise trust $mise_config"
    fi
}

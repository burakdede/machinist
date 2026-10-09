#!/usr/bin/env bash
# Neovim and Zed installation and setup for macOS.
#
# Installs neovim via Homebrew (already in Brewfile as a safety net),
# creates vi/vim → nvim shims in ~/.local/bin, and bootstraps lazy.nvim plugins.
#
# ── Neovim configuration ──────────────────────────────────────────────────────
# Config lives in the shared dotfiles/ directory:
#   dotfiles/.config/nvim/init.lua         -- entry point
#   dotfiles/.config/nvim/lua/config/      -- options, keymaps, autocmds
#   dotfiles/.config/nvim/lua/plugins/     -- lazy.nvim plugin specs
#     tools.lua  -- core tools (telescope, treesitter, tmux-navigator, …)
#     lsp.lua    -- language server configs
#     ui.lua     -- theme, statusline, etc.
#
# ── Adding plugins ────────────────────────────────────────────────────────────
# Add a spec to the relevant lua/plugins/*.lua file, then run:
#   nvim --headless "+Lazy! sync" +qa
# or just open nvim and run :Lazy sync.
#
# ── Upgrading Neovim ─────────────────────────────────────────────────────────
#   brew upgrade neovim
#
# ── Upgrading Zed ────────────────────────────────────────────────────────────
#   brew upgrade --cask zed
#
# Skip:    MACHINIST_SKIP_NEOVIM=1 ./run.sh --only editor
# Upgrade: MACHINIST_UPGRADE=1     ./run.sh --only editor

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/utils.sh
source "$SCRIPT_DIR/../utils/utils.sh"

trap 'handle_error $? $LINENO' ERR

load_versions

NEOVIM_VERSION="${NEOVIM_VERSION:-}"

installed_nvim_version() {
    if command_exists nvim; then
        nvim --version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//'
    fi
}

install_neovim() {
    echo_header "Neovim"

    local got
    got="$(installed_nvim_version)"

    if [[ -n "$got" ]] && ! upgrade_enabled; then
        log_info "Neovim $got already installed. (MACHINIST_UPGRADE=1 to reinstall)"
        return 0
    fi

    log_info "Installing Neovim via Homebrew..."
    brew install neovim
    log_success "Neovim $(installed_nvim_version) installed."
    assert_neovim_floor
}

install_zed() {
	echo_header "Zed editor"

	if brew list --cask zed &>/dev/null; then
		if upgrade_enabled; then
			log_info "Updating Zed via Homebrew Cask..."
			brew upgrade --cask zed
		else
			log_info "Zed is already installed. (MACHINIST_UPGRADE=1 to update)"
		fi
	else
		log_info "Installing Zed via Homebrew Cask..."
		brew install --cask zed
	fi

    # Keep the CLI user-local so this step does not need to modify /usr/local.
	local cli=""
	for cli_path in \
		"/Applications/Zed.app/Contents/MacOS/cli" \
		"$HOME/Applications/Zed.app/Contents/MacOS/cli"; do
		if [[ -x "$cli_path" ]]; then
			cli="$cli_path"
			break
		fi
	done

	if [[ -n "$cli" ]]; then
		mkdir -p "$HOME/.local/bin"
		ln -sf "$cli" "$HOME/.local/bin/zed"
		log_success "Zed installed; zed CLI linked to ~/.local/bin/zed."
	else
		log_warn "Zed installed, but its bundled CLI was not found."
	fi
}

# macOS tracks Homebrew's stable Neovim rather than pinning an exact patch the
# way Linux does; pinning brew to a patch release needs a custom tap, which is
# more machinery than it is worth for an editor.
#
# What actually matters is the floor: nvim-treesitter's main branch requires
# Neovim >= 0.12, and silently degrades to regex syntax below it. So treat
# NEOVIM_VERSION from packages/versions.txt as a minimum and say so loudly if
# Homebrew is behind it.
assert_neovim_floor() {
    local want="${NEOVIM_VERSION:-}"
    local got
    got="$(installed_nvim_version)"

    [[ -z "$want" || -z "$got" ]] && return 0

    if version_ge "$got" "$want"; then
        log_success "Neovim $got meets the $want floor."
    else
        log_warn "Neovim $got is older than the $want floor in packages/versions.txt."
        log_warn "nvim-treesitter (main branch) needs >= 0.12 and will fall back to"
        log_warn "regex syntax below it. Try: brew upgrade neovim"
    fi
}

# Neovim installs LSP servers and treesitter parsers on first launch, which
# means the first real open is a multi-minute download while you wait. Worse,
# it fails quietly: gopls went missing for a long time because nothing ever
# triggered its install.
#
# Do it here instead. Slower bootstrap, instant first launch, and failures
# surface now rather than the first time you open a Go file.
preload_editor_tools() {
    echo_header "Neovim language servers and parsers"

    if ! command_exists nvim; then
        log_warn "nvim not found; skipping preload."
        return 0
    fi

    log_info "Installing treesitter parsers (this takes a few minutes)..."
    if nvim --headless -c 'lua
        local ok, ts = pcall(require, "nvim-treesitter")
        if not ok then vim.cmd("qa!") end
        local want = {"bash","c","cmake","css","diff","dockerfile","go","gomod",
                      "gowork","html","java","javascript","json","json5","kotlin",
                      "lua","luadoc","make","markdown","markdown_inline","python",
                      "regex","ron","rst","rust","scala","sql","toml","tsx",
                      "typescript","vim","vimdoc","yaml"}
        local have = ts.get_installed()
        local missing = vim.tbl_filter(function(p)
            return not vim.tbl_contains(have, p)
        end, want)
        if #missing > 0 then ts.install(missing):wait(900000) end
        print("parsers: " .. #ts.get_installed())
    ' -c 'qa' 2>&1 | tail -1; then
        log_success "Treesitter parsers ready."
    else
        log_warn "Parser install had problems. Check with :checkhealth nvim-treesitter"
    fi

    log_info "Installing LSP servers via Mason..."
    # Translate the lspconfig server names in lua/plugins/lsp.lua into mason
    # package names (lua_ls -> lua-language-server) and install them, waiting
    # on mason-registry rather than sleeping and hoping.
    nvim --headless -c 'lua
        local ok_map, mappings = pcall(require, "mason-lspconfig.mappings")
        local ok_reg, registry = pcall(require, "mason-registry")
        if not (ok_map and ok_reg) then
            print("mason not available")
            vim.cmd("qa!")
        end

        registry.refresh()
        local to_package = mappings.get_mason_map().lspconfig_to_package
        local servers = {
            "pyright","ruff","gopls","rust_analyzer","jdtls","ts_ls","eslint",
            "lua_ls","bashls","yamlls","jsonls","taplo","dockerls",
            "docker_compose_language_service","html","cssls","marksman",
        }

        local pending = 0
        for _, server in ipairs(servers) do
            local pkg_name = to_package[server]
            if pkg_name then
                local ok_pkg, pkg = pcall(registry.get_package, pkg_name)
                if ok_pkg and not pkg:is_installed() then
                    pending = pending + 1
                    pkg:install():once("closed", function()
                        pending = pending - 1
                    end)
                end
            end
        end

        -- Block until every install settles, with a ceiling so a hung
        -- download cannot wedge the bootstrap.
        vim.wait(900000, function() return pending == 0 end, 500)
        print("mason packages installed: " .. #registry.get_installed_packages())
    ' -c 'qa' 2>&1 | tail -1

    log_success "Editor tooling preloaded; :Mason and :checkhealth show details."
}

register_shims() {
    # On macOS there is no update-alternatives.  Instead create symlinks in
    # ~/.local/bin (which is prepended to PATH in .zshenv) so that vi and vim
    # resolve to nvim without touching system paths.
    local nvim_path
    nvim_path="$(command -v nvim 2>/dev/null || true)"
    if [[ -z "$nvim_path" ]]; then
        log_warn "nvim not found; skipping vi/vim shims."
        return 0
    fi

    mkdir -p "$HOME/.local/bin"
    ln -sf "$nvim_path" "$HOME/.local/bin/vi"
    ln -sf "$nvim_path" "$HOME/.local/bin/vim"
    log_success "vi and vim → nvim shims created in ~/.local/bin"
}

bootstrap_plugins() {
    if ! command_exists nvim; then
        log_warn "nvim not found; skipping plugin bootstrap."
        return 0
    fi

    local nvim_config="$HOME/.config/nvim/init.lua"
    if [[ ! -f "$nvim_config" ]]; then
        log_warn "$HOME/.config/nvim/init.lua not found; run dotfiles step first."
        return 0
    fi

    log_info "Bootstrapping Neovim plugins (headless lazy.nvim sync)..."
    nvim --headless "+Lazy! sync" +qa 2>&1 | grep -v "^$" || true
    log_success "Neovim plugins installed."
}

main() {
    check_root
    export PATH="$HOME/.local/bin:$PATH"

    if should_skip_step NEOVIM; then
        log_info "Skipping Neovim (MACHINIST_SKIP_NEOVIM is set)."
        return 0
    fi

    install_neovim
    register_shims
    bootstrap_plugins
    preload_editor_tools

	if should_skip_step ZED; then
		log_info "Skipping Zed (MACHINIST_SKIP_ZED is set)."
	else
		install_zed
	fi

    echo_header "Editor setup complete"
    log_success "Neovim is ready; Zed is available as the backup editor."
    log_info "Config: ~/.config/nvim/  (symlinked from dotfiles/)"
    log_info "Servers and parsers are preloaded, so the first launch is instant."
}

main

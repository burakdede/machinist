#!/usr/bin/env bash
# Neovim and Zed installation and system integration.
#
# Downloads the pinned stable Neovim release (see versions.txt) from GitHub,
# installs it to /usr/local/bin/nvim, and registers it with update-alternatives
# so that `vim`, `vi`, and `editor` all resolve to nvim.
#
# Skip:    MACHINIST_SKIP_NEOVIM=1 or MACHINIST_SKIP_ZED=1
# Upgrade: MACHINIST_UPGRADE=1  (re-installs even if nvim is present)
# Zed updates itself; re-run this step with MACHINIST_UPGRADE=1 to force the
# official installer to refresh it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../utils/utils.sh"

trap 'handle_error $? $LINENO' ERR

load_versions

# Neovim names its Linux release assets by GNU triple: nvim-linux-x86_64 and
# nvim-linux-arm64. Never hardcode one -- an arm64 Ubuntu VM (the usual case on
# an Apple Silicon Mac) would 404 on every install.
NVIM_ARCH="$(uname -m)"
case "$NVIM_ARCH" in
    x86_64)        NVIM_ASSET_ARCH="x86_64" ;;
    aarch64|arm64) NVIM_ASSET_ARCH="arm64" ;;
    *)             NVIM_ASSET_ARCH="$NVIM_ARCH" ;;
esac

NVIM_INSTALL_DIR="/usr/local"
NVIM_BIN="$NVIM_INSTALL_DIR/bin/nvim"
# Default falls back to latest if versions.txt doesn't pin one
NEOVIM_VERSION="${NEOVIM_VERSION:-}"

installed_nvim_version() {
    if command_exists nvim; then
        nvim --version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//'
    fi
}

install_neovim() {
    echo_header "Neovim"

    local want="${NEOVIM_VERSION:-}"
    if [[ "$want" == "latest" ]]; then
        want=""
    fi
    local got
    got="$(installed_nvim_version)"

    if [[ -n "$got" ]] && ! upgrade_enabled; then
        if [[ -z "$want" || "$got" == "$want" ]]; then
            log_info "Neovim $got is already installed. (MACHINIST_UPGRADE=1 to reinstall)"
            return 0
        fi
        log_info "Installed: $got  Pinned: $want -- reinstalling to match pin."
    fi

    log_info "Installing Neovim build dependencies..."
    sudo_run apt-get install -y --no-install-recommends \
        build-essential cmake gettext ninja-build unzip curl

    local temp_dir download_url archive_path
    temp_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$temp_dir'" RETURN

    # Build the asset URL directly from the pinned version (no API call needed).
    # Falls back to querying the GitHub API for the latest release when no version is pinned.
    if [[ -n "$want" ]]; then
        local tag="v${want}"
        local asset="nvim-linux-${NVIM_ASSET_ARCH}.tar.gz"
        download_url="https://github.com/neovim/neovim/releases/download/${tag}/${asset}"
        log_info "Downloading Neovim ${want} (pinned)..."
    else
        log_info "No version pinned -- fetching latest Neovim release metadata..."
        local metadata_file="$temp_dir/release.json"
        curl -fsSL "https://api.github.com/repos/neovim/neovim/releases/latest" \
            -o "$metadata_file"
        if jq -e '.message' "$metadata_file" &>/dev/null; then
            log_warn "GitHub API error: $(jq -r '.message' "$metadata_file"). Skipping."
            return 0
        fi
        download_url="$(jq -r \
            --arg re "nvim-linux-${NVIM_ASSET_ARCH}\\.tar\\.gz$" \
            '.assets[] | select(.name | test($re)) | .browser_download_url' \
            "$metadata_file" | head -n1)"
    fi

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        log_warn "Could not resolve Neovim download URL. Skipping."
        return 0
    fi

    archive_path="$temp_dir/nvim.tar.gz"
    curl -fsSL "$download_url" -o "$archive_path"

    log_info "Extracting and installing Neovim to $NVIM_INSTALL_DIR ..."
    tar -xzf "$archive_path" -C "$temp_dir"
    local extracted_dir
    extracted_dir="$(find "$temp_dir" -maxdepth 1 -type d -name 'nvim-*' | head -n1)"

    if [[ -z "$extracted_dir" ]]; then
        log_warn "Could not find extracted Neovim directory. Skipping."
        return 0
    fi

    sudo_run cp -rf "$extracted_dir/bin/."   "$NVIM_INSTALL_DIR/bin/"
    sudo_run cp -rf "$extracted_dir/lib/."   "$NVIM_INSTALL_DIR/lib/"   2>/dev/null || true
    sudo_run cp -rf "$extracted_dir/share/." "$NVIM_INSTALL_DIR/share/" 2>/dev/null || true
    sudo_run chmod 0755 "$NVIM_BIN"

    rm -rf "$temp_dir"
    log_success "Neovim $(installed_nvim_version) installed to $NVIM_BIN"
}

register_alternatives() {
    if [[ ! -x "$NVIM_BIN" ]]; then
        log_warn "$NVIM_BIN not found; skipping update-alternatives registration."
        return 0
    fi

    log_info "Registering Neovim with update-alternatives..."

    sudo_run update-alternatives --install /usr/bin/vim    vim    "$NVIM_BIN" 60
    sudo_run update-alternatives --set             vim            "$NVIM_BIN"

    sudo_run update-alternatives --install /usr/bin/vi     vi     "$NVIM_BIN" 60
    sudo_run update-alternatives --set             vi             "$NVIM_BIN"

    sudo_run update-alternatives --install /usr/bin/editor editor "$NVIM_BIN" 60
    sudo_run update-alternatives --set             editor         "$NVIM_BIN"

    log_success "vim, vi, and editor now resolve to nvim."
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

    log_info "Bootstrapping Neovim plugins (headless)..."
    nvim --headless "+Lazy! sync" +qa 2>&1 | grep -v "^$" || true
    log_success "Neovim plugins installed."
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

install_zed() {
	echo_header "Zed editor"

	if command_exists zed && ! upgrade_enabled; then
		log_info "Zed is already installed. (MACHINIST_UPGRADE=1 to update)"
		return 0
	fi

	log_info "Installing Zed with the official Linux installer..."
	curl --proto '=https' --tlsv1.2 -f https://zed.dev/install.sh | sh
	hash -r 2>/dev/null || true
	if command_exists zed; then
		log_success "Zed installed. It will use Zed's native auto-update path."
	else
		log_warn "Zed installer completed, but the zed command is not on PATH yet."
	fi
}

main() {
    check_root
    ensure_sudo
    export PATH="$HOME/.local/bin:$PATH"

    if ! should_skip_step NEOVIM; then
        install_neovim
        register_alternatives
        bootstrap_plugins
    preload_editor_tools
    else
        log_info "Skipping Neovim (MACHINIST_SKIP_NEOVIM is set)."
    fi

	if ! should_skip_step ZED; then
		install_zed
	else
		log_info "Skipping Zed (MACHINIST_SKIP_ZED is set)."
	fi

    echo_header "Editor setup complete"
    log_success "Neovim is ready; Zed is available as the backup editor."
}

main

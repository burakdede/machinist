#!/usr/bin/env bash
# System package and CLI bootstrap for Ubuntu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../utils/utils.sh"

trap 'handle_error $? $LINENO' ERR

load_versions

APT_PACKAGES_FILE="$SCRIPT_DIR/apt-packages.txt"
# Shared cross-platform JS tooling, plus the Ubuntu-only agent CLIs that
# macOS gets from Homebrew casks.
NPM_PACKAGES_FILE="$REPO_ROOT/packages/npm-packages.txt"
NPM_AGENT_CLIS_FILE="$SCRIPT_DIR/npm-packages.txt"
UV_TOOLS_FILE="$REPO_ROOT/packages/uv-tools.txt"
GITHUB_TOOLS_FILE="$SCRIPT_DIR/github-tools.txt"

# Machine architecture, in the three spellings upstreams use for release assets.
# DEB_ARCH   -- Debian naming:  amd64 / arm64   (also used for apt "arch=" pins)
# GNU_ARCH   -- GNU triple:     x86_64 / aarch64
# NODE_ARCH  -- Node/JS naming: x64 / arm64     (tree-sitter and friends use it)
GNU_ARCH="$(uname -m)"
if command -v dpkg >/dev/null 2>&1; then
    DEB_ARCH="$(dpkg --print-architecture)"
else
    # dpkg is absent when this file is sourced for linting or unit tests off
    # Ubuntu. Derive the Debian spelling from the GNU one rather than aborting
    # at load time.
    case "$GNU_ARCH" in
        x86_64)        DEB_ARCH="amd64" ;;
        aarch64|arm64) DEB_ARCH="arm64" ;;
        *)             DEB_ARCH="$GNU_ARCH" ;;
    esac
fi
case "$GNU_ARCH" in
    x86_64)        NODE_ARCH="x64" ;;
    aarch64|arm64) NODE_ARCH="arm64" ;;
    *)             NODE_ARCH="$GNU_ARCH" ;;
esac
MISE_BIN="$HOME/.local/bin/mise"
# Both loaded from packages/versions.txt by load_versions. No hardcoded
# fallbacks: a stale default here would be a second source of truth that
# silently disagrees with the pin file.
MISE_VERSION="${MISE_VERSION:-}"
RUST_VERSION="${RUST_VERSION:-}"

# python, node, go and the IaC tools are NOT pinned here. They live in the
# shared dotfiles/.config/mise/config.toml and are installed with `mise install`.

ubuntu_codename() {
    local os_release="${MACHINIST_OS_RELEASE_FILE:-/etc/os-release}"
    local distro_id=""
    local version_codename=""

    if [[ ! -r "$os_release" ]]; then
        log_warn "Ubuntu release metadata is unavailable: $os_release"
        return 1
    fi

    unset ID VERSION_CODENAME
    # shellcheck source=/dev/null
    . "$os_release"
    distro_id="${ID:-}"
    version_codename="${VERSION_CODENAME:-}"
    if [[ "$distro_id" != "ubuntu" ]]; then
        log_warn "Expected Ubuntu release metadata, found: ${distro_id:-unknown}"
        return 1
    fi
    if [[ ! "$version_codename" =~ ^[a-z][a-z0-9-]*$ ]]; then
        log_warn "Ubuntu release codename is missing or invalid."
        return 1
    fi

    printf '%s\n' "$version_codename"
}

ensure_core_packages() {
    sudo_run apt-get update
    sudo_run apt-get install -y --no-install-recommends \
        ca-certificates curl gpg jq lsb-release software-properties-common wget
}

upgrade_base_system() {
    if [[ "${MACHINIST_SYSTEM_UPGRADE:-0}" != "1" ]]; then
        log_info "Skipping broad APT upgrade; set MACHINIST_SYSTEM_UPGRADE=1 to enable."
        return 0
    fi

    echo_header "System updates"
    sudo_run apt-get update
    sudo_run apt-get upgrade -y
    sudo_run apt-get autoremove -y
}

install_apt_packages() {
    echo_header "APT packages"

    if [[ ! -f "$APT_PACKAGES_FILE" ]]; then
        log_warn "Missing ${APT_PACKAGES_FILE}; skipping APT package installation."
        return 0
    fi

    # while-read rather than mapfile: this file is sourced by the test suite,
    # which runs on macOS too, and mapfile is a bash 4 builtin.
    local packages=()
    while IFS= read -r pkg; do packages+=("$pkg"); done < <(read_list_file "$APT_PACKAGES_FILE")
    if [[ ${#packages[@]} -eq 0 ]]; then
        log_info "No APT packages declared."
        return 0
    fi

    log_info "Installing ${#packages[@]} APT packages."
    sudo_run apt-get install -y --no-install-recommends "${packages[@]}"
}

ensure_command_symlink() {
    local expected_name="$1"
    local source_command="$2"
    local source_path

    if command_exists "$expected_name"; then
        return 0
    fi

    if ! source_path="$(command -v "$source_command")"; then
        log_warn "Cannot create ${expected_name}; ${source_command} is not installed."
        return 0
    fi

    sudo_run ln -sf "$source_path" "/usr/local/bin/$expected_name"
}

ensure_agent_command_names() {
    echo_header "Command compatibility"
    ensure_command_symlink fd fdfind
    ensure_command_symlink bat batcat
}

setup_google_chrome_repo() {
    if command_exists google-chrome; then
        log_info "Google Chrome is already installed."
        return 0
    fi

    echo_header "Google Chrome"

    # Google publishes no arm64 Linux build of Chrome. Skip rather than add an
    # apt source that can never resolve.
    if [[ "$DEB_ARCH" != "amd64" ]]; then
        log_warn "Google Chrome has no ${DEB_ARCH} Linux build upstream. Skipping."
        log_info "Use the Firefox that Ubuntu ships by default, which is built for ${DEB_ARCH}."
        return 0
    fi

    sudo_run mkdir -p /etc/apt/keyrings
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' "$DEB_ARCH" | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    sudo_run chmod 644 /etc/apt/keyrings/google-chrome.gpg
    sudo_run apt-get update
    sudo_run apt-get install -y google-chrome-stable
}

setup_spotify_repo() {
    # Spotify publishes no arm64 Linux build.
    if [[ "$DEB_ARCH" != "amd64" ]]; then
        log_warn "Spotify has no ${DEB_ARCH} Linux build upstream. Skipping."
        return 0
    fi

    echo_header "Spotify"

    if dpkg -s spotify-client >/dev/null 2>&1; then
        log_info "Spotify is already installed."
        return 0
    fi

    sudo_run mkdir -p /etc/apt/keyrings
    # Spotify rotates signing keys periodically; try newest known key first,
    # then fall back to the previous one for compatibility.
    local key_installed=0
    local key_url
    for key_url in \
        "https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc" \
        "https://download.spotify.com/debian/pubkey_7A3A762FAFD4A51F.gpg"
    do
        if curl -fsSL "$key_url" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/spotify.gpg; then
            key_installed=1
            break
        fi
    done
    if [[ "$key_installed" -ne 1 ]]; then
        log_warn "Failed to install Spotify apt key. Skipping Spotify."
        return 0
    fi
    sudo_run chmod 644 /etc/apt/keyrings/spotify.gpg

    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/spotify.gpg] https://repository.spotify.com stable non-free\n' \
        "$DEB_ARCH" | sudo tee /etc/apt/sources.list.d/spotify.list >/dev/null

    sudo_run apt-get update
    if ! sudo_run apt-get install -y spotify-client; then
        log_warn "Failed to install spotify-client from apt repo."
    fi
}

setup_tailscale_repo() {
    echo_header "Tailscale"

    if command_exists tailscale; then
        log_info "Tailscale is already installed."
        return 0
    fi

    local codename
    if ! codename="$(ubuntu_codename)"; then
        log_warn "Skipping Tailscale because the Ubuntu codename is unavailable."
        return 0
    fi

    sudo_run mkdir -p /usr/share/keyrings
    if ! curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
        | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null; then
        log_warn "Failed to install Tailscale apt key. Skipping Tailscale."
        return 0
    fi

    if ! curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" \
        | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null; then
        log_warn "Failed to install Tailscale apt source. Skipping Tailscale."
        return 0
    fi

    sudo_run apt-get update
    if ! sudo_run apt-get install -y tailscale; then
        log_warn "Failed to install Tailscale from apt."
    fi
}

configure_timeshift_policy() {
    echo_header "Timeshift"

    if ! command_exists timeshift; then
        log_warn "Timeshift is not installed. Skipping Timeshift configuration."
        return 0
    fi

    local install_user root_uuid
    install_user="${SUDO_USER:-$USER}"
    root_uuid="$(findmnt -no UUID / 2>/dev/null || true)"

    if [[ -z "$install_user" ]]; then
        log_warn "Could not determine install user; skipping Timeshift configuration."
        return 0
    fi

    # This policy focuses on system snapshots plus user dotfiles:
    # - daily snapshots, keep 5
    # - include only hidden files under /home/<user>
    # - exclude regular home files
    #
    # Timeshift reads this config at /etc/timeshift/timeshift.json.
    sudo_run mkdir -p /etc/timeshift
    cat <<EOF | sudo tee /etc/timeshift/timeshift.json >/dev/null
{
  "backup_device_uuid" : "${root_uuid}",
  "parent_device_uuid" : "",
  "do_first_run" : "false",
  "btrfs_mode" : "false",
  "include_btrfs_home" : "false",
  "stop_cron_emails" : "true",
  "schedule_monthly" : "false",
  "schedule_weekly" : "false",
  "schedule_daily" : "true",
  "schedule_hourly" : "false",
  "schedule_boot" : "false",
  "count_monthly" : "0",
  "count_weekly" : "0",
  "count_daily" : "5",
  "count_hourly" : "0",
  "count_boot" : "0",
  "snapshot_size" : "0",
  "snapshot_count" : "0",
  "exclude" : [
    "- /home/*/**",
    "+ /home/${install_user}/.**",
    "- /home/${install_user}/.cache/**"
  ],
  "exclude-apps" : [ ]
}
EOF

    log_success "Timeshift policy configured: daily snapshots (keep 5), include /home/${install_user} hidden files only."
}

install_jetbrains_toolbox() {
    echo_header "JetBrains Toolbox"

    local install_root="$HOME/.local/share/JetBrains/Toolbox"
    local bin_path="$HOME/.local/bin/jetbrains-toolbox"

    if [[ -x "$bin_path" ]] && ! upgrade_enabled; then
        log_info "JetBrains Toolbox is already installed. (MACHINIST_UPGRADE=1 to reinstall)"
        return 0
    fi

    local metadata_url metadata_file download_url temp_dir archive_path extracted_dir toolbox_exec top_entry top_dir
    metadata_url="https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release"
    temp_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$temp_dir'" RETURN
    metadata_file="$temp_dir/toolbox.json"

    if ! curl -fsSL "$metadata_url" -o "$metadata_file"; then
        log_warn "Failed to fetch JetBrains Toolbox release metadata. Skipping."
        return 0
    fi

    download_url="$(jq -r '.TBA[0].downloads.linux.link // empty' "$metadata_file")"
    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        log_warn "Could not resolve JetBrains Toolbox Linux download URL. Skipping."
        return 0
    fi

    archive_path="$temp_dir/jetbrains-toolbox.tar.gz"
    if ! curl -fsSL "$download_url" -o "$archive_path"; then
        log_warn "Failed to download JetBrains Toolbox archive. Skipping."
        return 0
    fi

    mkdir -p "$install_root" "$HOME/.local/bin"
    top_entry="$(tar -tzf "$archive_path" | head -n1 || true)"
    top_dir="${top_entry%%/*}"
    tar -xzf "$archive_path" -C "$temp_dir"

    if [[ -n "$top_dir" && -d "$temp_dir/$top_dir" ]]; then
        extracted_dir="$temp_dir/$top_dir"
    else
        extracted_dir="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    fi
    if [[ -z "$extracted_dir" ]]; then
        log_warn "Could not extract JetBrains Toolbox archive. Skipping."
        return 0
    fi

    rm -rf "${install_root:?}/"*
    cp -R "$extracted_dir"/. "$install_root"/

    toolbox_exec="$install_root/jetbrains-toolbox"
    if [[ ! -x "$toolbox_exec" ]]; then
        if [[ -x "$install_root/bin/jetbrains-toolbox" ]]; then
            toolbox_exec="$install_root/bin/jetbrains-toolbox"
        else
            toolbox_exec="$(find "$install_root" -maxdepth 4 -type f -name 'jetbrains-toolbox' | head -n1 || true)"
            if [[ -n "$toolbox_exec" && ! -x "$toolbox_exec" ]]; then
                chmod +x "$toolbox_exec" || true
            fi
        fi
    fi

    if [[ -z "$toolbox_exec" || ! -x "$toolbox_exec" ]]; then
        log_warn "JetBrains Toolbox binary not found after install. Skipping."
        return 0
    fi

    ln -sf "$toolbox_exec" "$bin_path"

    # Best-effort desktop launcher.
    mkdir -p "$HOME/.local/share/applications"
    cat > "$HOME/.local/share/applications/jetbrains-toolbox.desktop" <<EOF
[Desktop Entry]
Name=JetBrains Toolbox
Exec=$toolbox_exec
Icon=jetbrains-toolbox
Type=Application
Categories=Development;IDE;
Terminal=false
StartupNotify=true
EOF

    log_success "JetBrains Toolbox installed: $bin_path"
}

setup_docker_repo() {
    echo_header "Docker Engine, CLI and Compose"

    if ! dpkg -s docker-ce >/dev/null 2>&1 || ! dpkg -s docker-ce-cli >/dev/null 2>&1 \
        || ! dpkg -s containerd.io >/dev/null 2>&1 || ! dpkg -s docker-compose-plugin >/dev/null 2>&1; then

        sudo_run mkdir -p /etc/apt/keyrings
        # --yes overwrites existing keyring file on re-runs without prompting
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo_run chmod a+r /etc/apt/keyrings/docker.gpg

        local codename
        if ! codename="$(ubuntu_codename)"; then
            log_warn "Skipping Docker because the Ubuntu codename is unavailable."
            return 0
        fi
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
            "$(dpkg --print-architecture)" "$codename" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

        sudo_run apt-get update
        sudo_run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        log_success "Docker Engine installed."
    else
        log_info "Docker Engine and Compose plugin are already installed."
    fi

    # Ensure daemon is enabled and running regardless of whether we just installed it.
    sudo_run systemctl enable docker
    if ! sudo systemctl is-active --quiet docker; then
        sudo_run systemctl start docker
        log_info "Docker daemon started."
    fi

    # Add current user to docker group so docker can be used without sudo.
    if ! id -nG "$USER" | grep -qw docker; then
        sudo_run usermod -aG docker "$USER"
        log_info "Added $USER to docker group -- re-login or run 'newgrp docker' to apply."
    else
        log_info "$USER is already in the docker group."
    fi

    log_success "Docker setup complete."
}

download_latest_release_asset() {
    local repo="$1"
    local asset_pattern="$2"
    local metadata_file="$3"

    # Pass GITHUB_TOKEN when available to raise rate limit from 60 to 1000 req/hour.
    local -a auth_header=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    # Use --retry so transient network errors don't abort the bootstrap.
    # --fail-with-body (-f) is not used here so the response body is captured
    # even on 4xx/5xx -- the jq guard below handles API error payloads.
    if ! curl -sSL --retry 3 --retry-delay 2 \
            "${auth_header[@]}" \
            "https://api.github.com/repos/${repo}/releases/latest" \
            -o "$metadata_file"; then
        log_warn "Failed to fetch release metadata for ${repo} after retries."
        echo ""
        return 0
    fi

    # Detect GitHub API error responses (rate limit, not found, etc.)
    if jq -e '.message' "$metadata_file" &>/dev/null; then
        log_warn "GitHub API error for ${repo}: $(jq -r '.message' "$metadata_file")"
        echo ""
        return 0
    fi

    local url
    url="$(jq -r --arg pattern "$asset_pattern" \
        '.assets[] | select(.name | test($pattern)) | .browser_download_url' \
        "$metadata_file" | head -n1)"

    # jq emits "null" string when a field exists but is null; treat it as empty
    if [[ "$url" == "null" ]]; then
        echo ""
    else
        echo "$url"
    fi
}

install_github_release_tools() {
    echo_header "GitHub release tools"

    if [[ ! -f "$GITHUB_TOOLS_FILE" ]]; then
        log_warn "Missing ${GITHUB_TOOLS_FILE}; skipping GitHub release tools."
        return 0
    fi

    local line command_name repo asset_pattern mode binary_name
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(trim "$line")"
        [[ -z "$line" ]] && continue

        IFS='|' read -r command_name repo asset_pattern mode binary_name <<< "$line"
        binary_name="${binary_name:-$command_name}"

        # Release assets are named per architecture; fill in this machine's.
        asset_pattern="${asset_pattern//\{deb_arch\}/$DEB_ARCH}"
        asset_pattern="${asset_pattern//\{gnu_arch\}/$GNU_ARCH}"
        asset_pattern="${asset_pattern//\{node_arch\}/$NODE_ARCH}"

        if command_exists "$command_name" && ! upgrade_enabled; then
            log_info "Tool already installed: $command_name (set MACHINIST_UPGRADE=1 to upgrade)"
            continue
        fi

        local temp_dir metadata_file download_url archive_path extracted_path
        temp_dir="$(mktemp -d)"
        # shellcheck disable=SC2064
        trap "rm -rf '$temp_dir'" RETURN
        metadata_file="$temp_dir/release.json"
        download_url="$(download_latest_release_asset "$repo" "$asset_pattern" "$metadata_file")"

        if [[ -z "$download_url" || "$download_url" == "null" ]]; then
            log_warn "Could not find a matching release asset for $command_name from $repo."
            rm -rf "$temp_dir"
            continue
        fi

        case "$mode" in
            raw)
                archive_path="$temp_dir/$binary_name"
                curl -fsSL "$download_url" -o "$archive_path"
                sudo_run install -m 0755 "$archive_path" "/usr/local/bin/$command_name"
                ;;
            tar.gz)
                archive_path="$temp_dir/archive.tar.gz"
                curl -fsSL "$download_url" -o "$archive_path"
                tar -xzf "$archive_path" -C "$temp_dir"
                extracted_path="$(find "$temp_dir" -type f -name "$binary_name" | head -n1)"
                if [[ -z "$extracted_path" ]]; then
                    log_warn "Downloaded $command_name but could not locate $binary_name in the archive."
                    rm -rf "$temp_dir"
                    continue
                fi
                sudo_run install -m 0755 "$extracted_path" "/usr/local/bin/$command_name"
                ;;
            tar.xz)
                archive_path="$temp_dir/archive.tar.xz"
                curl -fsSL "$download_url" -o "$archive_path"
                # -J is xz; xz-utils is in apt-packages.txt.
                tar -xJf "$archive_path" -C "$temp_dir"
                extracted_path="$(find "$temp_dir" -type f -name "$binary_name" | head -n1)"
                if [[ -z "$extracted_path" ]]; then
                    log_warn "Downloaded $command_name but could not locate $binary_name in the archive."
                    rm -rf "$temp_dir"
                    continue
                fi
                sudo_run install -m 0755 "$extracted_path" "/usr/local/bin/$command_name"
                ;;
            gz)
                # A single gzip-compressed binary, not a tarball.
                archive_path="$temp_dir/$binary_name.gz"
                curl -fsSL "$download_url" -o "$archive_path"
                gunzip -f "$archive_path"
                sudo_run install -m 0755 "$temp_dir/$binary_name" "/usr/local/bin/$command_name"
                ;;
            *)
                log_warn "Unsupported install mode '$mode' for $command_name."
                rm -rf "$temp_dir"
                continue
                ;;
        esac

        rm -rf "$temp_dir"
    done < "$GITHUB_TOOLS_FILE"
}

install_uv() {
    echo_header "uv"

    if command_exists uv && ! upgrade_enabled; then
        log_info "uv is already installed. (MACHINIST_UPGRADE=1 to upgrade)"
        return 0
    fi

    curl --proto '=https' --tlsv1.2 -LsSf --retry 3 --retry-delay 2 https://astral.sh/uv/install.sh | sh
}

install_uv_tools() {
    echo_header "uv tools"

    if [[ ! -f "$UV_TOOLS_FILE" ]]; then
        log_warn "Missing ${UV_TOOLS_FILE}; skipping uv tools."
        return 0
    fi

    local entry package_name source
    while IFS= read -r entry; do
        package_name="${entry%%|*}"
        source=""
        [[ "$entry" == *"|"* ]] && source="${entry#*|}"

        log_info "Installing uv tool: $package_name"
        if [[ -n "$source" ]]; then
            uv tool install --quiet --from "$source" "$package_name" \
                || uv tool upgrade "$package_name" \
                || log_warn "Could not install $package_name from $source"
        else
            uv tool install --quiet "$package_name" || uv tool upgrade "$package_name"
        fi
    done < <(read_list_file "$UV_TOOLS_FILE")
}

install_claude_code() {
    echo_header "Claude Code"

    if command_exists claude; then
        log_info "Claude Code is already installed."
        return 0
    fi

    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 https://claude.ai/install.sh | bash
}

install_mise() {
    echo_header "mise"

    local want="${MISE_VERSION:-}"
    local got=""
    if [[ -x "$MISE_BIN" ]]; then
        got="$("$MISE_BIN" --version 2>/dev/null | awk '{print $2}')"
    fi

    if [[ -n "$got" ]] && ! upgrade_enabled; then
        if [[ -z "$want" || "$got" == "$want" ]]; then
            log_info "mise $got is already installed."
        else
            log_info "mise installed: $got  pinned: $want -- reinstalling."
            if [[ -n "$want" ]]; then
                MISE_VERSION="$want" curl --proto '=https' --tlsv1.2 -fsSL https://mise.run | sh
            else
                curl --proto '=https' --tlsv1.2 -fsSL https://mise.run | sh
            fi
        fi
    elif [[ ! -x "$MISE_BIN" ]]; then
        if [[ -n "$want" ]]; then
            log_info "Installing mise $want (pinned)..."
            MISE_VERSION="$want" curl --proto '=https' --tlsv1.2 -fsSL https://mise.run | sh
        else
            curl --proto '=https' --tlsv1.2 -fsSL https://mise.run | sh
        fi
    fi

    # No longer appends an activation line to ~/.bashrc: that file is now a
    # tracked dotfile (dotfiles/.bashrc) which activates mise itself, and
    # appending to it would fight the symlink.
    export PATH="$HOME/.local/bin:$PATH"
    eval "$("$MISE_BIN" activate bash)"
}

# Install every tool pinned in the shared mise config
# (dotfiles/.config/mise/config.toml): python, node, go and the IaC tooling.
#
# Deliberately `mise install`, NOT `mise use --global`. The latter rewrites
# ~/.config/mise/config.toml, which is a symlink into this repo, so it would
# silently edit tracked config during a bootstrap run.
install_mise_runtimes() {
    echo_header "Runtimes and tools via mise"
    install_mise

    if [[ ! -f "$HOME/.config/mise/config.toml" ]]; then
        log_warn "No ~/.config/mise/config.toml yet. Run the dotfiles step first."
        return 0
    fi

    # Force a precompiled Python build. Without these mise falls back to
    # compiling CPython from source, which takes many minutes on a fresh
    # machine and needs a full build toolchain.
    MISE_PYTHON_COMPILE=0 \
    MISE_PYTHON_PRECOMPILED_FLAVOR=install_only_stripped \
        "$MISE_BIN" install
    log_success "mise tools installed."
}



setup_ufw() {
    echo_header "ufw firewall"

    # Skip the destructive reset if ufw is already active -- resetting wipes all
    # user-added rules and is only necessary on a fresh machine.
    if sudo ufw status | grep -q "^Status: active"; then
        log_info "ufw is already active; skipping reset to preserve existing rules."
        return 0
    fi

    sudo_run ufw --force reset
    sudo_run ufw default deny incoming
    sudo_run ufw default allow outgoing
    sudo_run ufw allow ssh
    sudo_run ufw --force enable

    log_info "ufw enabled: deny incoming, allow outgoing, SSH allowed."
}



install_rust() {
    echo_header "Rust via rustup"

    if command_exists rustup; then
        log_info "rustup is already installed."
        rustup toolchain install "$RUST_VERSION" --profile minimal --no-self-update
        rustup default "$RUST_VERSION"
        return 0
    fi

    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    rustup toolchain install "$RUST_VERSION" --profile minimal --no-self-update
    rustup default "$RUST_VERSION"
}


install_cloud_clis() {
    echo_header "Cloud CLIs"

    install_aws_cli
    install_gcloud
}

# AWS ships no GitHub release, and Ubuntu's `awscli` package is still version
# 1, so neither github-tools.txt nor APT can serve this.
#
# The official installer is the documented route and needs no root: it honours
# XDG_DATA_HOME and XDG_BIN_HOME, which .zshenv already sets, so the CLI lands
# in ~/.local/share/aws-cli with a symlink in ~/.local/bin -- a directory this
# repo already puts on PATH for every shell.
#
# Unpinned on purpose, matching macOS, where Homebrew's awscli tracks latest
# and is not in packages/versions.txt. The installer takes `--version X.Y.Z`
# if that ever needs to change; pin both platforms together or not at all.
install_aws_cli() {
    if command_exists aws && ! upgrade_enabled; then
        log_info "aws is already installed ($(aws --version 2>&1 | awk '{print $1}'))."
        return 0
    fi

    log_info "Installing the AWS CLI via the official installer..."
    if curl --proto '=https' --tlsv1.2 -fsSL https://awscli.amazonaws.com/v2/install.sh \
        | bash -s -- --quiet; then
        log_success "aws installed to ${XDG_DATA_HOME:-$HOME/.local/share}/aws-cli"
    else
        log_warn "The AWS CLI installer failed; continuing without it."
    fi
}

# Google ships no GitHub release either. The versioned archive is the
# documented install that needs no root -- the apt repo would mean another
# third-party source plus root, for one tool.
install_gcloud() {
    if command_exists gcloud && ! upgrade_enabled; then
        log_info "gcloud is already installed."
        return 0
    fi

    # Google names the 64-bit ARM build "arm", not "arm64" or "aarch64".
    local gcloud_arch
    case "$GNU_ARCH" in
        x86_64)        gcloud_arch="x86_64" ;;
        aarch64|arm64) gcloud_arch="arm" ;;
        *)
            log_warn "Google publishes no Cloud CLI build for ${GNU_ARCH}. Skipping."
            return 0
            ;;
    esac

    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local bin_home="$HOME/.local/bin"
    local url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-${gcloud_arch}.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    log_info "Installing the Google Cloud CLI from the versioned archive..."
    if ! curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$tmp_dir/gcloud.tar.gz"; then
        log_warn "Could not download the Google Cloud CLI. Skipping."
        rm -rf "$tmp_dir"
        return 0
    fi

    mkdir -p "$data_home" "$bin_home"

    # Replace the tree rather than unpacking over it. The archive is a full SDK
    # and files left behind by an older release are how a half-upgraded, subtly
    # broken gcloud happens.
    rm -rf "${data_home:?}/google-cloud-sdk"
    tar -xzf "$tmp_dir/gcloud.tar.gz" -C "$data_home"
    rm -rf "$tmp_dir"

    # --path-update=false because PATH belongs to the dotfiles: .zshenv already
    # puts ~/.local/bin ahead of everything, and letting the installer append
    # its own block to ~/.bashrc would fight the tracked config.
    "$data_home/google-cloud-sdk/install.sh" \
        --quiet --path-update=false --usage-reporting=false

    local tool
    for tool in gcloud gsutil bq; do
        ln -sf "$data_home/google-cloud-sdk/bin/$tool" "$bin_home/$tool"
    done

    log_success "gcloud installed to $data_home/google-cloud-sdk"
}


install_npm_clis() {
    echo_header "Node-based tooling"

    install_mise_runtimes

    local list package_name
    for list in "$NPM_PACKAGES_FILE" "$NPM_AGENT_CLIS_FILE"; do
        if [[ ! -f "$list" ]]; then
            log_warn "Missing ${list}; skipping those npm CLIs."
            continue
        fi

        while IFS= read -r package_name; do
            # Entries may be `package|command`; npm only wants the package.
            package_name="${package_name%%|*}"
            log_info "Installing npm package: $package_name"
            # No version here: mise resolves node from the shared config.
            "$MISE_BIN" exec -- npm install --global "$package_name"
        done < <(read_list_file "$list")
    done
}

# Playwright drives a real browser for visual verification; the npm package
# alone cannot do anything without one. Browser binaries are pinned to the
# playwright package version, so this runs after every upgrade -- `install` is
# a no-op when the matching browser is already cached.
#
# Chromium only: it covers screenshots, navigation and DOM assertions, and
# adding Firefox plus WebKit would triple the ~400MB for little day-to-day
# gain. Projects needing cross-browser run `npx playwright install` themselves.
install_playwright_browser() {
    echo_header "Playwright browser"

    if ! "$MISE_BIN" exec -- playwright --version >/dev/null 2>&1; then
        log_warn "playwright CLI not found; skipping the browser download."
        log_info "It comes from packages/npm-packages.txt -- re-run the system step."
        return 0
    fi

    # --with-deps pulls the shared libraries headless Chromium needs on
    # Ubuntu (fonts, libnss3, libasound2 and friends). It uses apt, so it
    # needs sudo; fall back to the browser alone if that is unavailable.
    if sudo -n true 2>/dev/null || [[ -n "${MACHINIST_SUDO_OK:-}" ]]; then
        if "$MISE_BIN" exec -- playwright install --with-deps chromium; then
            log_success "Chromium and its system deps ready"
            return 0
        fi
    fi

    if "$MISE_BIN" exec -- playwright install chromium; then
        log_success "Chromium ready (system deps not installed)"
        log_info "If it fails to launch, run: playwright install-deps chromium"
    else
        log_warn "Could not install the Chromium build. Retry with:"
        log_info "  playwright install --with-deps chromium"
    fi
}

install_nerd_fonts() {
    echo_header "JetBrains Mono Nerd Font"

    local fonts_dir="$HOME/.local/share/fonts"
    local marker="$fonts_dir/JetBrainsMonoNerdFont-Regular.ttf"

    if [[ -f "$marker" ]] && ! upgrade_enabled; then
        log_info "JetBrains Mono Nerd Font is already installed."
        return 0
    fi

    local want="${NERD_FONTS_VERSION:-}"
    local temp_dir zip_path download_url
    temp_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$temp_dir'" RETURN

    if [[ -n "$want" ]]; then
        download_url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${want}/JetBrainsMono.zip"
        log_info "Downloading JetBrains Mono Nerd Font v${want} (pinned)..."
    else
        log_info "Fetching latest Nerd Fonts release metadata..."
        local metadata_file="$temp_dir/release.json"
        curl -fsSL "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" \
            -o "$metadata_file"
        if jq -e '.message' "$metadata_file" &>/dev/null; then
            log_warn "GitHub API error for nerd-fonts. Skipping fonts."
            return 0
        fi
        download_url="$(jq -r \
            '.assets[] | select(.name == "JetBrainsMono.zip") | .browser_download_url' \
            "$metadata_file" | head -n1)"
    fi

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        log_warn "Could not resolve Nerd Fonts download URL. Skipping."
        return 0
    fi

    zip_path="$temp_dir/JetBrainsMono.zip"
    curl -fsSL "$download_url" -o "$zip_path"

    mkdir -p "$fonts_dir"
    unzip -o -q "$zip_path" "*.ttf" -d "$fonts_dir"
    fc-cache -f "$fonts_dir"
    rm -rf "$temp_dir"
    log_success "JetBrains Mono Nerd Font installed to $fonts_dir"
}

main() {
    check_root
    ensure_sudo

    # Ensure user-local bin is on PATH for uv, mise, and other tools installed
    # into ~/.local/bin. Export once here rather than in individual functions.
    export PATH="$HOME/.local/bin:$PATH"

    ensure_core_packages
    upgrade_base_system
    install_apt_packages
    ensure_agent_command_names

    if ! should_skip_step DOCKER; then
        setup_docker_repo
    fi

    if ! should_skip_step CHROME; then
        setup_google_chrome_repo
    fi

    if ! should_skip_step SPOTIFY; then
        setup_spotify_repo
    fi

    if ! should_skip_step TAILSCALE; then
        setup_tailscale_repo
    fi

    if ! should_skip_step JETBRAINS_TOOLBOX; then
        install_jetbrains_toolbox
    fi

    if ! should_skip_step TIMESHIFT; then
        configure_timeshift_policy
    fi

    if ! should_skip_step GITHUB_RELEASE_TOOLS; then
        install_github_release_tools
    fi

    if ! should_skip_step CLOUD_CLIS; then
        install_cloud_clis
    fi

    if ! should_skip_step UV; then
        install_uv
        install_uv_tools
    fi

    if ! should_skip_step CLAUDE; then
        install_claude_code
    fi

    if ! should_skip_step NPM_TOOLS; then
        install_npm_clis
        install_playwright_browser
    fi

    # python, node, go and the IaC tooling all come from the shared mise
    # config in one call; there is no per-runtime step any more.
    if ! should_skip_step MISE_TOOLS; then
        install_mise_runtimes
    fi

    if ! should_skip_step RUST; then
        install_rust
    fi

    if ! should_skip_step UFW; then
        setup_ufw
    fi

    if ! should_skip_step FONTS; then
        install_nerd_fonts
    fi

    echo_header "System bootstrap complete"
    log_success "Base packages, agent-oriented CLIs, and runtime managers are installed."
}

main

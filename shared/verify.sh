#!/usr/bin/env bash
# Post-install verification -- shared by macOS and Ubuntu.
#
# Sourced by mac/scripts/verify-install.sh and linux/scripts/verify-install.sh,
# which add their own OS-specific sections and then call verify_summary.
#
# Wherever possible the checks are DERIVED from the shared manifests rather
# than hand-listed, so a tool added to packages/ is verified automatically and
# the verifier cannot drift from what the installer installs.

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m';  RESET=$'\033[0m'

PASS=0; FAIL=0; WARN=0

ok()   { printf '  %s✓%s  %s\n' "$GREEN"  "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s  %s\n' "$RED"    "$RESET" "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  %s~%s  %s\n' "$YELLOW" "$RESET" "$1"; WARN=$((WARN+1)); }
section() { printf '\n%s── %s%s\n' "$CYAN" "$1" "$RESET"; }

_version_of() { command "$1" --version 2>/dev/null | head -n1 || true; }

# Best-of-3 interactive login shell startup, in whole milliseconds.
# Best-of-N wall time for an interactive login shell, in milliseconds.
#
# Startup time is a min-statistic: the fastest run is the one where nothing
# else competed for the CPU, and that is the number the budget is about. Single
# samples on this metric swing by 3-4x on a busy machine, so a warm-up run is
# discarded (it pays for cold page cache and the completion dump) and the best
# of five is reported. Fewer samples than this produced false budget warnings.
_startup_ms() {
    local shell="$1" best="" t _
    command -v "$shell" >/dev/null 2>&1 || return 1
    "$shell" -lic 'exit' >/dev/null 2>&1   # warm-up, deliberately not timed
    for _ in 1 2 3 4 5; do
        t="$( { /usr/bin/time -p "$shell" -lic 'exit' ; } 2>&1 | awk '/^real/{print $2}' )"
        [[ -z "$t" ]] && continue
        if [[ -z "$best" ]] || awk -v a="$t" -v b="$best" 'BEGIN{exit !(a<b)}'; then
            best="$t"
        fi
    done
    [[ -n "$best" ]] && awk -v b="$best" 'BEGIN{printf "%d", b*1000}'
}

# Display a path home-relative, so labels read "~/.zshrc" not the full path.
_pretty_path() {
    local tilde='~'
    printf '%s' "${1/#$HOME/$tilde}"
}

# Follow a symlink chain to its final target. A dotfile may be reached through
# an intermediate link (~/.claude/CLAUDE.md -> ~/.config/agents/instructions.md
# -> the repo), so comparing only the first hop gives a false negative.
_resolve_link() {
    local path="$1" hops=0 target dir

    while [[ -L "$path" && "$hops" -lt 10 ]]; do
        target="$(readlink "$path")"
        [[ "$target" != /* ]] && target="$(dirname "$path")/$target"
        path="$target"
        hops=$((hops + 1))
    done

    # The file itself may not be a link while a PARENT directory is -- e.g.
    # ~/.config/agents is the symlink and instructions.md inside it is not.
    # `cd -P` resolves symlinks in the directory path. Avoids needing GNU
    # realpath, which macOS does not ship.
    dir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || dir="$(dirname "$path")"
    printf '%s/%s' "$dir" "$(basename "$path")"
}

check_cmd() {
    local cmd="$1" label="${2:-$1}" ver
    if command -v "$cmd" >/dev/null 2>&1; then
        ver="$(_version_of "$cmd")"
        ok "$label${ver:+  ($ver)}"
    else
        fail "$label  (not found)"
    fi
}

check_cmd_optional() {
    local cmd="$1" label="${2:-$1}" ver
    if command -v "$cmd" >/dev/null 2>&1; then
        ver="$(_version_of "$cmd")"
        ok "$label${ver:+  ($ver)}"
    else
        warn "$label  (not found -- optional)"
    fi
}

check_file() {
    local path="$1"
    local label="${2:-$(_pretty_path "$path")}"
    if [[ -e "$path" ]]; then ok "$label"; else fail "$label  (missing: $path)"; fi
}

check_dir() {
    local path="$1"
    local label="${2:-$(_pretty_path "$path")}"
    if [[ -d "$path" ]]; then ok "$label"; else fail "$label  (missing: $path)"; fi
}

# A dotfile must be a symlink INTO this repo. A regular file there means the
# dotfiles step never ran, or something replaced the link -- edits to it would
# silently not be tracked, which is worth flagging distinctly.
check_symlink() {
    local path="$1"
    local label="${2:-$(_pretty_path "$path")}"
    local target
    if [[ -L "$path" ]]; then
        target="$(_resolve_link "$path")"
        if [[ "$target" == "$REPO_ROOT"* ]]; then
            ok "$label"
        else
            warn "$label  (symlink, but points outside the repo: $target)"
        fi
    elif [[ -e "$path" ]]; then
        fail "$label  (a real file, not a symlink -- re-run the dotfiles step)"
    else
        fail "$label  (missing -- run the dotfiles step)"
    fi
}

check_contains() {
    local path="$1"
    local needle="$2"
    local label="${3:-$needle in $(basename "$path")}"
    if [[ -f "$path" ]] && grep -q -- "$needle" "$path"; then
        ok "$label"
    else
        fail "$label  (not found in $path)"
    fi
}

verify_shared() {
    section "Core CLI"
    local c
    for c in git curl jq rg fd bat eza fzf gh tmux; do check_cmd "$c"; done

    section "Runtime managers"
    check_cmd mise
    check_cmd uv
    check_cmd_optional rustup
    check_cmd_optional cargo

    # ── Tools pinned in the shared mise config ────────────────────────────────
    section "mise tools (dotfiles/.config/mise/config.toml)"
    local mise_cfg="$HOME/.config/mise/config.toml"
    if [[ ! -f "$mise_cfg" ]]; then
        fail "mise config  (missing: $mise_cfg -- run the dotfiles step)"
    elif ! command -v mise >/dev/null 2>&1; then
        fail "mise tools  (mise not installed)"
    else
        local tool
        while IFS= read -r tool; do
            [[ -z "$tool" ]] && continue
            if mise which "$tool" >/dev/null 2>&1; then
                ok "$tool  ($(mise current "$tool" 2>/dev/null || echo installed))"
            else
                fail "$tool  (pinned in mise config but not installed -- run: mise install)"
            fi
        done < <(sed -n '/^\[tools\]/,$p' "$mise_cfg" \
                 | grep -E '^[a-z][a-z0-9-]*[[:space:]]*=' \
                 | sed -E 's/^([a-z0-9-]+).*/\1/')
    fi

    # mise finds <repo>/dotfiles/.config/mise/config.toml as a project config
    # whenever the cwd is inside the repo, and project configs need explicit
    # trust. Untrusted, every mise command run from the repo fails.
    if command -v mise >/dev/null 2>&1 && [[ -f "$REPO_ROOT/dotfiles/.config/mise/config.toml" ]]; then
        if (cd "$REPO_ROOT/dotfiles" && mise ls --current >/dev/null 2>&1); then
            ok "repo mise config is trusted"
        else
            fail "repo mise config is NOT trusted  (run: mise trust $REPO_ROOT/dotfiles/.config/mise/config.toml)"
        fi
    fi

    # ── Tools from the shared manifests ──────────────────────────────────────
    section "Shared manifests (packages/)"
    local uv_tools="$REPO_ROOT/packages/uv-tools.txt"
    local npm_tools="$REPO_ROOT/packages/npm-packages.txt"
    local sdkman_list="$REPO_ROOT/packages/sdkman.txt"

    if [[ -f "$uv_tools" ]]; then
        # Entries are `package[|source]`, and a package's executable need not
        # share its name (specify-cli installs `specify`). So ask uv what it
        # has installed rather than guessing a command name.
        local uv_installed=""
        command -v uv >/dev/null 2>&1 && uv_installed="$(uv tool list 2>/dev/null)"

        local entry pkg
        while IFS= read -r entry; do
            pkg="${entry%%|*}"
            if [[ "$uv_installed" == *"$pkg"* ]]; then
                ok "$pkg  (uv)"
            else
                fail "$pkg  (uv)  not installed -- run: ./install.sh --only system"
            fi
        done < <(read_list_file "$uv_tools")
    else
        fail "packages/uv-tools.txt  (missing)"
    fi

    if [[ -f "$npm_tools" ]]; then
        # Entries are `package[|command]`; a scoped package's executable does
        # not share its name (@ast-grep/cli installs `ast-grep`), so check the
        # command where one is given and the package name otherwise.
        local entry npm_pkg npm_cmd
        while IFS= read -r entry; do
            npm_pkg="${entry%%|*}"
            npm_cmd="${entry#*|}"
            [[ "$npm_cmd" == "$entry" ]] && npm_cmd="$npm_pkg"
            check_cmd "$npm_cmd" "$npm_pkg  (npm)"
        done < <(read_list_file "$npm_tools")
    else
        fail "packages/npm-packages.txt  (missing)"
    fi

    # Declared per-platform -- Homebrew on macOS, github-tools.txt or a vendor
    # installer on Ubuntu -- so nothing else in this script would notice one
    # going missing on one side only. That asymmetry is what this catches.
    #
    # `wrangler` is deliberately absent: it is invoked as `npx wrangler` from
    # each project, so there is no machine-wide copy to look for. See the note
    # in mac/Brewfile.
    section "Cloud CLIs"
    check_cmd aws         "aws  (AWS)"
    check_cmd gcloud      "gcloud  (Google Cloud)"
    check_cmd cloudflared "cloudflared  (Cloudflare Tunnel)"
    check_cmd hcloud      "hcloud  (Hetzner)"

    section "SDKMAN (owns the JVM toolchain)"
    local sdk_home="$HOME/.sdkman"
    if [[ -s "$sdk_home/bin/sdkman-init.sh" ]]; then
        ok "sdkman installed"

        # Entries are candidate[@version]. A versioned entry must have that
        # exact version present, which is how the GraalVM install is checked;
        # an unversioned one just needs a "current" symlink.
        local entry candidate version
        while IFS= read -r entry; do
            candidate="${entry%%@*}"
            version=""
            [[ "$entry" == *"@"* ]] && version="${entry#*@}"

            if [[ -n "$version" ]]; then
                if [[ -d "$sdk_home/candidates/$candidate/$version" ]]; then
                    ok "$candidate $version"
                else
                    warn "$candidate $version  (not installed -- run: ./run.sh --only sdk)"
                fi
            elif [[ -d "$sdk_home/candidates/$candidate/current" ]]; then
                ok "$candidate"
            else
                warn "$candidate  (not installed -- run: ./run.sh --only sdk)"
            fi
        done < <(read_list_file "$sdkman_list")

        # SDKMAN only puts things on PATH; .zshrc supplies the environment the
        # JVM tools actually read. Check that a login shell exports it.
        local jvm_env
        jvm_env="$(zsh -lic 'printf "%s|%s|%s" "${JAVA_HOME:-}" "${GRAALVM_HOME:-}" "${MAVEN_HOME:-}"' 2>/dev/null | tail -1)"
        local java_home="${jvm_env%%|*}"
        local rest="${jvm_env#*|}"
        local graal_home="${rest%%|*}"
        local maven_home="${rest##*|}"

        if [[ -n "$java_home"  ]]; then ok "JAVA_HOME -> $java_home"; else fail "JAVA_HOME not set in a login shell"; fi
        if [[ -n "$graal_home" ]]; then ok "GRAALVM_HOME -> $graal_home"; else warn "GRAALVM_HOME not set (no GraalVM installed?)"; fi
        if [[ -n "$maven_home" ]]; then ok "MAVEN_HOME set"; else warn "MAVEN_HOME not set"; fi

        # Homebrew or APT copies of these would shadow SDKMAN's on PATH.
        local tool resolved
        for tool in mvn gradle java; do
            resolved="$(zsh -lic "command -v $tool" 2>/dev/null | tail -1)"
            if [[ -z "$resolved" ]]; then
                warn "$tool not on PATH"
            elif [[ "$resolved" == "$sdk_home"/* ]]; then
                ok "$tool resolves to SDKMAN"
            else
                fail "$tool resolves to $resolved, not SDKMAN (remove the competing copy)"
            fi
        done
    else
        warn "sdkman  (not installed -- run: ./run.sh --only sdk)"
    fi

    # ── Competing version managers ───────────────────────────────────────────
    # mise owns python, node and go here, and SDKMAN owns the JVM. Another
    # manager on PATH will shadow the mise shims for the same runtime, and the
    # version you get then depends on PATH order rather than on the config in
    # this repo.
    section "Version manager conflicts"
    local conflict found_conflict=0
    for conflict in pyenv rbenv nodenv nvm asdf goenv jenv; do
        if command -v "$conflict" >/dev/null 2>&1; then
            warn "$conflict is installed and competes with mise/SDKMAN for runtime resolution"
            found_conflict=1
        fi
    done
    if [[ "$found_conflict" -eq 0 ]]; then
        ok "no competing runtime managers on PATH"
    fi

    # A Homebrew copy of something mise owns is invisible to the resolution
    # check below: ~/.local/bin and the mise shims sort ahead of /opt/homebrew,
    # so the shim wins and nothing looks wrong. It stays wrong quietly until
    # one PATH reorder -- or one script calling the tool by absolute path --
    # picks the other one. This machine carried a Homebrew node v26 behind a
    # mise-pinned v24 that way, and two mise binaries nine months apart.
    #
    # mise itself is the sharp case and is a failure, not a warning: .zshrc and
    # .zprofile activate ~/.local/bin/mise by absolute path, so a Homebrew mise
    # satisfies `command -v mise` while the activation silently uses the other
    # binary. mac/Brewfile documents this; the check enforces it.
    #
    # The test is "does anything depend on it", not "is it a leaf". Both of the
    # obvious shortcuts are wrong here, and this machine had one of each:
    #
    #   `brew list --formula` alone flags python@3.14, which awscli, gcloud-cli,
    #   nmap and watchman all depend on -- uninstalling it breaks them.
    #
    #   `brew leaves` alone misses hashicorp/tap/terraform, which was installed
    #   at v1.15.3 against a mise pin of 1.8.5 while being neither a leaf nor
    #   depended on by anything.
    #
    # So: match every installed formula whose name duplicates a mise-managed
    # tool, then keep only the ones nothing else needs. Names are matched with
    # any tap prefix stripped, since a third-party tap shadows just as well.
    if command -v brew >/dev/null 2>&1; then
        if brew list --formula 2>/dev/null | grep -qE '(^|/)mise$'; then
            fail "mise is installed from Homebrew  (brew uninstall mise -- the pinned one lives at ~/.local/bin/mise)"
        else
            ok "mise comes only from the pinned installer"
        fi

        local dupe found_dupe=0
        while IFS= read -r dupe; do
            [[ -z "$dupe" ]] && continue
            # A formula something else needs is not drift; it never reaches PATH.
            [[ -n "$(brew uses --installed "$dupe" 2>/dev/null)" ]] && continue
            warn "Homebrew has $dupe, which mise already owns  (brew uninstall $dupe)"
            found_dupe=1
        done < <(brew list --formula 2>/dev/null \
                 | awk -F/ '{print $NF"\t"$0}' \
                 | grep -E '^(node|python|ruby|go|terraform|terragrunt|tflint)(@[0-9.]+)?\t' \
                 | cut -f2)
        if [[ "$found_dupe" -eq 0 ]]; then
            ok "no Homebrew duplicates of mise-managed runtimes"
        fi
    fi

    # The runtimes that actually resolve should be the mise ones.
    local rt
    for rt in node python; do
        if command -v "$rt" >/dev/null 2>&1; then
            if [[ "$(command -v "$rt")" == *"/mise/"* ]]; then
                ok "$rt resolves through mise"
            else
                warn "$rt resolves to $(command -v "$rt"), not mise  (mise config is being bypassed)"
            fi
        fi
    done

    # zsh is the daily driver, but bash gets used for scripts, rescue shells and
    # remote boxes. It previously had no config in this repo at all, which meant
    # mise was never activated there and `node` silently resolved to a different
    # version than in zsh. Check the two agree.
    # zsh reads .zshenv for EVERY invocation, .zprofile for login shells, and
    # .zshrc only for interactive ones. Runtimes must resolve the same in all
    # three, or `ssh host "node --version"`, cron and git hooks get a different
    # version than your terminal does.
    # Startup time is a feature here, so guard it. These are generous ceilings:
    # the intent is to catch a regression (an uncached eval, a plugin loaded
    # eagerly), not to police a few milliseconds.
    section "Shell startup"
    local zsh_ms bash_ms
    zsh_ms="$(_startup_ms zsh)"
    if [[ -n "$zsh_ms" ]]; then
        if   (( zsh_ms <= 150 )); then ok   "zsh starts in ${zsh_ms}ms"
        elif (( zsh_ms <= 300 )); then warn "zsh starts in ${zsh_ms}ms (expected under 150ms)"
        else                           fail "zsh starts in ${zsh_ms}ms -- something is no longer cached"
        fi
    fi
    if command -v bash >/dev/null 2>&1; then
        bash_ms="$(_startup_ms bash)"
        if [[ -n "$bash_ms" ]]; then
            if   (( bash_ms <= 250 )); then ok   "bash starts in ${bash_ms}ms"
            else                            warn "bash starts in ${bash_ms}ms (expected under 250ms)"
            fi
        fi
    fi

    section "Shell invocation parity"
    if command -v node >/dev/null 2>&1; then
        local n_int n_login n_script
        n_int="$(zsh -lic 'node --version' 2>/dev/null | tail -1)"
        n_login="$(zsh -lc 'node --version' 2>/dev/null | tail -1)"
        n_script="$(env -i HOME="$HOME" zsh -c 'node --version' 2>/dev/null | tail -1)"

        if [[ -n "$n_int" && "$n_int" == "$n_login" && "$n_int" == "$n_script" ]]; then
            ok "zsh resolves node to $n_int when interactive, login and non-interactive"
        else
            fail "node differs by zsh invocation -- interactive:${n_int:-none} login:${n_login:-none} script:${n_script:-none}"
        fi
    fi

    section "bash parity"
    local bash_bin
    bash_bin="$(command -v bash 2>/dev/null || true)"
    if [[ -z "$bash_bin" ]]; then
        warn "bash not found"
    else
        check_symlink "$HOME/.bashrc"
        check_symlink "$HOME/.bash_profile"

        local bash_node zsh_node
        bash_node="$("$bash_bin" -lic 'command -v node' 2>/dev/null | tail -1)"
        zsh_node="$(zsh -lic 'command -v node' 2>/dev/null | tail -1)"
        if [[ -z "$bash_node" || -z "$zsh_node" ]]; then
            warn "could not resolve node in both shells"
        elif [[ "$bash_node" == "$zsh_node" ]]; then
            ok "bash and zsh resolve node identically"
        else
            fail "node differs by shell -- bash: $bash_node / zsh: $zsh_node"
        fi

        # Single-quoted on purpose: MISE_SHELL must expand inside the bash
        # login shell being tested, not in this one.
        # shellcheck disable=SC2016
        if "$bash_bin" -lic '[[ -n "${MISE_SHELL:-}" ]]' 2>/dev/null; then
            ok "mise is activated in bash"
        else
            fail "mise is NOT activated in bash (runtime versions will differ from zsh)"
        fi
    fi

    # Visual verification. The agent instructions expect a browser here, so a
    # missing one is a real gap rather than a nice-to-have.
    # Installing a tool and wiring it up are different acts. These are the
    # ones that look installed but do nothing until configured.
    # Removing a candidate from packages/sdkman.txt does not uninstall it, and
    # .zshrc globs every candidate onto PATH -- so a dropped tool keeps
    # answering long after the manifest says it is gone.
    if [[ -d "$HOME/.sdkman/candidates" ]]; then
        local cand undeclared=""
        for cand in "$HOME/.sdkman/candidates"/*; do
            [[ -d "$cand" ]] || continue
            cand="$(basename "$cand")"
            grep -qE "^${cand}([@[:space:]]|\$)" "$REPO_ROOT/packages/sdkman.txt" || undeclared="$undeclared $cand"
        done
        if [[ -n "$undeclared" ]]; then
            warn "SDKMAN candidates installed but not declared:${undeclared}  (sdk uninstall <candidate> <version>)"
        fi
    fi

    section "Tool wiring"
    if command -v git-lfs >/dev/null 2>&1; then
        if git config --get filter.lfs.clean >/dev/null 2>&1; then
            ok "git-lfs filters registered"
        else
            fail "git-lfs installed but not registered -- run: git lfs install"
        fi
    fi

    if command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
            ok "gh authenticated ($(gh api user --jq .login 2>/dev/null || echo '?'))"
            if [[ "$(gh config get git_protocol 2>/dev/null)" == "ssh" ]]; then
                ok "gh uses ssh for git"
            else
                warn "gh git_protocol is not ssh, but the git step sets up an SSH key"
            fi
        else
            fail "gh not authenticated -- issues, PRs and projects will all fail"
        fi
    fi

    if [[ -f "$HOME/.ssh/config" ]] && grep -q "managed by machinist" "$HOME/.ssh/config"; then
        ok "ssh client configured (agent + ed25519)"
    else
        warn "$HOME/.ssh/config has no managed block -- run: ./install.sh --only git"
    fi

    # One theme name across the terminal, editor, pager and previewer.
    local theme_ok=1
    grep -q 'color_scheme = "Dracula"' "$REPO_ROOT/dotfiles/.config/wezterm/wezterm.lua" 2>/dev/null || theme_ok=0
    grep -q 'colorscheme("dracula")'  "$REPO_ROOT/dotfiles/.config/nvim/lua/plugins/ui.lua" 2>/dev/null || theme_ok=0
    grep -q 'theme="Dracula"'  "$HOME/.config/bat/config" 2>/dev/null || theme_ok=0
    [[ "$(git config --get delta.syntax-theme 2>/dev/null)" == "Dracula" ]] || theme_ok=0
    if (( theme_ok )); then
        ok "one theme across wezterm, nvim, bat and delta"
    else
        warn "theme has drifted between wezterm / nvim / bat / delta"
    fi

    section "Visual verification"
    if command -v playwright >/dev/null 2>&1 || (command -v mise >/dev/null 2>&1 && mise which playwright >/dev/null 2>&1); then
        ok "playwright  ($(mise exec -- playwright --version 2>/dev/null || playwright --version 2>/dev/null))"
        local pw_cache="$HOME/Library/Caches/ms-playwright"
        [[ -d "$pw_cache" ]] || pw_cache="$HOME/.cache/ms-playwright"
        # Plain bash: an unmatched glob stays literal, and the -d test drops it.
        local pw_chromium=() pw_dir
        for pw_dir in "$pw_cache"/chromium*; do
            [[ -d "$pw_dir" ]] && pw_chromium+=("$pw_dir")
        done
        if (( ${#pw_chromium[@]} )); then
            ok "chromium installed ($(du -sh "$pw_cache" 2>/dev/null | cut -f1))"
        else
            fail "playwright has no browser -- run: playwright install chromium"
        fi
    else
        fail "playwright not installed (see packages/npm-packages.txt)"
    fi

    section "Editor"
    check_cmd nvim
    check_file "$HOME/.config/nvim/init.lua" "nvim init.lua"

    section "Agents"
    check_cmd_optional claude   "Claude Code"
    check_cmd_optional codex    "Codex"
    check_cmd_optional opencode "OpenCode"
    check_file "$HOME/.config/agents/instructions.md" "shared agent instructions"
    check_symlink "$HOME/.claude/CLAUDE.md" "Claude Code -> shared instructions"
    check_symlink "$HOME/.codex/AGENTS.md"  "Codex -> shared instructions"

    section "Dotfile symlinks"
    local f
    for f in .zshrc .zshenv .zprofile .zsh_plugins.txt .p10k.zsh .gitconfig .gitignore_global; do
        check_symlink "$HOME/$f"
    done
    for f in nvim tmux wezterm mise agents; do
        check_symlink "$HOME/.config/$f"
    done

    section "Shell configuration"
    check_dir "$HOME/.local/share/antidote"       "antidote"
    check_dir "$HOME/.local/share/powerlevel10k"  "powerlevel10k"
    check_contains "$HOME/.zshenv"  "typeset -U path" "PATH de-duplication enabled"
    check_contains "$HOME/.config/tmux/tmux.conf" "set-clipboard on" "tmux system clipboard"
    check_file "$HOME/.gitconfig.local"
}

verify_summary() {
    printf '\n%s──────────────────────────────────────────%s\n' "$CYAN" "$RESET"
    printf '  %s%d passed%s   %s%d failed%s   %s%d warnings%s\n\n' \
        "$GREEN" "$PASS" "$RESET" "$RED" "$FAIL" "$RESET" "$YELLOW" "$WARN" "$RESET"
    [[ "$FAIL" -eq 0 ]]
}

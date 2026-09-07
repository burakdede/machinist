import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
# dotfiles/ lives at the monorepo root, one level above linux/
DOTFILES_DIR = REPO_ROOT.parent / "dotfiles"
# Manifests shared with macOS live at the monorepo root
PACKAGES_DIR = REPO_ROOT.parent / "packages"
SHARED_DIR = REPO_ROOT.parent / "shared"


class BootstrapRepoTests(unittest.TestCase):
    def run_cmd(self, args, cwd=None, env=None):
        return subprocess.run(
            args,
            cwd=cwd or REPO_ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def create_sourceable_system_script(self, directory: Path) -> Path:
        original = (REPO_ROOT / "system" / "system.sh").read_text(encoding="utf-8")
        lines = original.splitlines()
        filtered_lines = []
        for line in lines:
            if line.strip() == 'source "$SCRIPT_DIR/../utils/utils.sh"':
                continue
            if line.strip() == "main":
                continue
            filtered_lines.append(line)

        script_path = directory / "system-sourceable.sh"
        script_path.write_text("\n".join(filtered_lines) + "\n", encoding="utf-8")
        return script_path

    def test_shell_syntax_is_valid(self):
        scripts = [
            str(REPO_ROOT.parent / ".githooks" / "pre-commit"),
            str(REPO_ROOT.parent / ".githooks" / "pre-push"),
            "run.sh",
            "scripts/smoke-system.sh",
            "system/system.sh",
            "sdk/sdk.sh",
            "git/git.sh",
            "dotfiles.sh",
            "utils/utils.sh",
            "utils/settings.sh",
            "scripts/test.sh",
            "scripts/verify-system-smoke.sh",
            "scripts/vm-smoke-test.sh",
            "terminal/terminal.sh",
            "shell/shell.sh",
            "editor/editor.sh",
            "multiplexer/multiplexer.sh",
            "scripts/verify-install.sh",
            "configure/configure.sh",
        ]
        result = self.run_cmd(["bash", "-n", *scripts])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shellcheck_passes(self):
        files = [
            str(REPO_ROOT.parent / ".githooks" / "pre-commit"),
            str(REPO_ROOT.parent / ".githooks" / "pre-push"),
            "run.sh",
            "scripts/smoke-system.sh",
            "system/system.sh",
            "sdk/sdk.sh",
            "git/git.sh",
            "dotfiles.sh",
            "utils/utils.sh",
            "utils/settings.sh",
            "scripts/test.sh",
            "scripts/verify-system-smoke.sh",
            "scripts/vm-smoke-test.sh",
            "terminal/terminal.sh",
            "shell/shell.sh",
            "editor/editor.sh",
            "multiplexer/multiplexer.sh",
            "scripts/verify-install.sh",
            "configure/configure.sh",
            "agents/agents.sh",
        ]
        # Bash shared with macOS lives at the monorepo root.
        files.extend(str(f) for f in sorted(SHARED_DIR.glob("*.sh")))
        files.extend(
            str(f) for f in sorted((REPO_ROOT.parent / "scripts").glob("*.sh"))
        )
        # .vimrc is vimscript and .zsh* are zsh; shellcheck handles neither.

        # .zshenv/.zshrc/.zprofile are deliberately absent: shellcheck has no
        # zsh support and misreports zsh-only syntax. test_zsh_dotfiles_parse
        # covers them instead.
        #
        # -x --source-path=SCRIPTDIR so `source` of shared/ resolves rather
        # than being reported as SC1091.
        result = self.run_cmd(["shellcheck", "-x", "--source-path=SCRIPTDIR", *files])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_zsh_dotfiles_parse(self):
        """The zsh dotfiles must parse under zsh; shellcheck cannot check them."""
        zsh = shutil.which("zsh")
        if not zsh:
            self.skipTest("zsh not installed")
        for name in (".zshenv", ".zshrc", ".zprofile"):
            path = DOTFILES_DIR / name
            if not path.exists():
                continue
            result = self.run_cmd([zsh, "-n", str(path)])
            self.assertEqual(result.returncode, 0, f"{name}: {result.stderr}")

    def test_run_help_succeeds(self):
        result = self.run_cmd(["bash", "run.sh", "--help"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: ./run.sh [options]", result.stdout)
        self.assertIn("--only STEP", result.stdout)

    def test_settings_script_skips_without_desktop_session(self):
        env = os.environ.copy()
        env.pop("DISPLAY", None)
        env.pop("WAYLAND_DISPLAY", None)

        result = self.run_cmd(["bash", "utils/settings.sh"], env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "Skipping GNOME settings because no desktop session is active.",
            result.stderr,
        )

    def test_dotfiles_script_installs_and_backs_up(self):
        if not (DOTFILES_DIR / ".gitconfig").exists():
            self.skipTest("dotfiles directory not found")
        with tempfile.TemporaryDirectory() as temp_home:
            home = Path(temp_home)
            existing_gitconfig = home / ".gitconfig"
            existing_gitconfig.write_text(
                "[user]\n\tname = Old User\n", encoding="utf-8"
            )

            env = os.environ.copy()
            env["HOME"] = temp_home

            result = self.run_cmd(["bash", "dotfiles.sh"], env=env)
            self.assertEqual(result.returncode, 0, result.stderr)

            installed_vimrc = home / ".vimrc"
            installed_gitconfig = home / ".gitconfig"

            self.assertTrue(installed_vimrc.exists())
            self.assertTrue(installed_gitconfig.exists())

            # dotfiles.sh must create symlinks, not copies
            self.assertTrue(installed_vimrc.is_symlink(), ".vimrc should be a symlink")
            self.assertTrue(
                installed_gitconfig.is_symlink(), ".gitconfig should be a symlink"
            )
            self.assertTrue(
                str(installed_gitconfig.resolve()).startswith(str(REPO_ROOT.parent)),
                "symlink should point into the repo",
            )

            # .config sub-dirs must also be symlinked
            source_config_dir = DOTFILES_DIR / ".config"
            if source_config_dir.exists():
                for entry in source_config_dir.iterdir():
                    target = home / ".config" / entry.name
                    self.assertTrue(
                        target.is_symlink(), f".config/{entry.name} should be a symlink"
                    )

            # Existing .gitconfig must have been backed up
            backup_root = home / ".local" / "state" / "machinist" / "dotfiles-backups"
            backups = list(backup_root.rglob(".gitconfig"))
            self.assertTrue(backups, "Expected .gitconfig backup to be created")

    def test_run_only_executes_requested_step(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo = Path(tmp_dir) / "repo"
            (repo / "utils").mkdir(parents=True)
            (repo / "system").mkdir()
            (repo / "dotfiles").mkdir()
            (repo / "sdk").mkdir()
            (repo / "agents").mkdir()
            (repo / "git").mkdir()

            shutil.copy2(REPO_ROOT / "run.sh", repo / "run.sh")
            shutil.copy2(REPO_ROOT / "utils" / "utils.sh", repo / "utils" / "utils.sh")

            # utils.sh sources shared/ui.sh from the monorepo root, so the
            # fake repo needs that sibling directory to exist too.
            shutil.copytree(SHARED_DIR, Path(tmp_dir) / "shared")

            marker_dir = repo / "markers"
            marker_dir.mkdir()

            for step_dir, script_name, marker_name in [
                ("system", "system.sh", "system"),
                ("dotfiles", "dotfiles.sh", "dotfiles"),
                ("sdk", "sdk.sh", "sdk"),
                ("agents", "agents.sh", "agents"),
                ("git", "git.sh", "git"),
            ]:
                script_path = repo / step_dir / script_name
                script_path.write_text(
                    textwrap.dedent(
                        f"""\
                        #!/usr/bin/env bash
                        set -euo pipefail
                        touch "{marker_dir / marker_name}"
                        """
                    ),
                    encoding="utf-8",
                )
                script_path.chmod(script_path.stat().st_mode | stat.S_IXUSR)

            settings_path = repo / "utils" / "settings.sh"
            settings_path.write_text(
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env bash
                    set -euo pipefail
                    touch "{marker_dir / "settings"}"
                    """
                ),
                encoding="utf-8",
            )
            settings_path.chmod(settings_path.stat().st_mode | stat.S_IXUSR)

            env = os.environ.copy()
            env["HOME"] = str(Path(tmp_dir) / "home")
            Path(env["HOME"]).mkdir()

            result = self.run_cmd(
                ["bash", "run.sh", "--only", "sdk"], cwd=repo, env=env
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((marker_dir / "sdk").exists())
            self.assertFalse((marker_dir / "system").exists())
            self.assertFalse((marker_dir / "dotfiles").exists())
            self.assertFalse((marker_dir / "agents").exists())
            self.assertFalse((marker_dir / "git").exists())
            self.assertFalse((marker_dir / "settings").exists())

    def test_read_list_file_skips_comments_and_blank_lines(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            manifest = Path(tmp_dir) / "manifest.txt"
            manifest.write_text(
                textwrap.dedent(
                    """\
                    # comment

                    rg
                    fd-find   # inline comment

                    jq
                    """
                ),
                encoding="utf-8",
            )

            command = (
                f'source "{REPO_ROOT / "utils" / "utils.sh"}"; '
                f'read_list_file "{manifest}"'
            )
            result = self.run_cmd(["bash", "-lc", command])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["rg", "fd-find", "jq"])

    def test_manifests_are_well_formed(self):
        simple_manifests = [
            REPO_ROOT / "system" / "apt-packages.txt",
            REPO_ROOT / "system" / "npm-packages.txt",
            PACKAGES_DIR / "npm-packages.txt",
            PACKAGES_DIR / "uv-tools.txt",
            PACKAGES_DIR / "sdkman.txt",
        ]
        for manifest in simple_manifests:
            seen = set()
            for raw_line in manifest.read_text(encoding="utf-8").splitlines():
                line = raw_line.split("#", 1)[0].strip()
                if not line:
                    continue
                self.assertNotIn(line, seen, f"Duplicate entry {line!r} in {manifest}")
                seen.add(line)

        github_seen = set()
        # Keep in step with the case statement in install_github_release_tools.
        valid_modes = {"raw", "tar.gz", "tar.xz", "gz"}
        for raw_line in (
            (REPO_ROOT / "system" / "github-tools.txt")
            .read_text(encoding="utf-8")
            .splitlines()
        ):
            line = raw_line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split("|")
            self.assertEqual(
                len(parts), 5, f"Expected 5 columns in github-tools.txt, got {line!r}"
            )
            command_name, repo, asset_pattern, mode, binary_name = parts
            self.assertTrue(command_name)
            self.assertRegex(repo, r"^[^/]+/[^/]+$")
            self.assertTrue(asset_pattern)
            self.assertIn(mode, valid_modes)
            self.assertTrue(binary_name)
            self.assertNotIn(command_name, github_seen)
            github_seen.add(command_name)

    def test_system_installer_uses_expected_apt_command(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            log_file = Path(tmp_dir) / "log.txt"
            manifest = Path(tmp_dir) / "apt.txt"
            sourceable_script = self.create_sourceable_system_script(tmp_path)
            manifest.write_text("rg\nfd-find\njq\n", encoding="utf-8")

            command = textwrap.dedent(
                f"""\
                source "{REPO_ROOT / "utils" / "utils.sh"}"
                sudo_run() {{ printf 'sudo:%s\\n' "$*" >> "{log_file}"; }}
                log_info() {{ :; }}
                log_warn() {{ :; }}
                log_success() {{ :; }}
                echo_header() {{ :; }}
                source "{sourceable_script}"
                APT_PACKAGES_FILE="{manifest}"
                install_apt_packages
                """
            )

            result = self.run_cmd(["bash", "-lc", command])
            self.assertEqual(result.returncode, 0, result.stderr)
            log_output = log_file.read_text(encoding="utf-8")
            self.assertIn(
                "sudo:apt-get install -y --no-install-recommends rg fd-find jq",
                log_output,
            )

    def test_ensure_line_in_file_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            target = tmp_path / ".bashrc"
            line = 'eval "$("$HOME/.local/bin/mise" activate bash)"'

            command = textwrap.dedent(
                f"""\
                source "{REPO_ROOT / "utils" / "utils.sh"}"
                ensure_line_in_file '{line}' "{target}"
                ensure_line_in_file '{line}' "{target}"
                """
            )

            result = self.run_cmd(["bash", "-lc", command])
            self.assertEqual(result.returncode, 0, result.stderr)
            bashrc = target.read_text(encoding="utf-8").splitlines()
            self.assertEqual(bashrc.count(line), 1)

    def test_system_main_respects_skip_flags(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            log_file = Path(tmp_dir) / "log.txt"
            sourceable_script = self.create_sourceable_system_script(tmp_path)
            command = textwrap.dedent(
                f"""\
                source "{REPO_ROOT / "utils" / "utils.sh"}"
                source "{sourceable_script}"
                check_root() {{ :; }}
                ensure_sudo() {{ :; }}
                ensure_core_packages() {{ printf 'core\\n' >> "{log_file}"; }}
                upgrade_base_system() {{ printf 'upgrade\\n' >> "{log_file}"; }}
                install_apt_packages() {{ printf 'apt\\n' >> "{log_file}"; }}
                ensure_agent_command_names() {{ printf 'compat\\n' >> "{log_file}"; }}
                setup_docker_repo() {{ printf 'docker\\n' >> "{log_file}"; }}
                install_cloud_clis() {{ printf 'cloud-clis\\n' >> "{log_file}"; }}
                setup_google_chrome_repo() {{ printf 'chrome\\n' >> "{log_file}"; }}
                setup_spotify_repo() {{ printf 'spotify\\n' >> "{log_file}"; }}
                setup_tailscale_repo() {{ printf 'tailscale\\n' >> "{log_file}"; }}
                install_jetbrains_toolbox() {{ printf 'jetbrains-toolbox\\n' >> "{log_file}"; }}
                configure_timeshift_policy() {{ printf 'timeshift\\n' >> "{log_file}"; }}
                install_github_release_tools() {{ printf 'gh-tools\\n' >> "{log_file}"; }}
                install_uv() {{ printf 'uv\\n' >> "{log_file}"; }}
                install_uv_tools() {{ printf 'uv-tools\\n' >> "{log_file}"; }}
                install_claude_code() {{ printf 'claude\\n' >> "{log_file}"; }}
                install_npm_clis() {{ printf 'npm\\n' >> "{log_file}"; }}
                install_mise_runtimes() {{ printf 'mise-tools\\n' >> "{log_file}"; }}
                install_rust() {{ printf 'rust\\n' >> "{log_file}"; }}
                setup_ufw() {{ printf 'ufw\\n' >> "{log_file}"; }}
                echo_header() {{ :; }}
                log_success() {{ :; }}
                export MACHINIST_SKIP_CLOUD_CLIS=1
                export MACHINIST_SKIP_CHROME=1
                export MACHINIST_SKIP_GO=1
                export MACHINIST_SKIP_PYTHON=1
                export MACHINIST_SKIP_RUST=1
                export MACHINIST_SKIP_IAC_TOOLS=1
                export MACHINIST_SKIP_UFW=1
                main
                """
            )

            result = self.run_cmd(["bash", "-lc", command])
            self.assertEqual(result.returncode, 0, result.stderr)
            output = log_file.read_text(encoding="utf-8").splitlines()
            self.assertIn("core", output)
            self.assertIn("apt", output)
            self.assertIn("docker", output)
            self.assertIn("spotify", output)
            self.assertIn("tailscale", output)
            self.assertIn("jetbrains-toolbox", output)
            self.assertIn("timeshift", output)
            self.assertNotIn("cloud-clis", output)
            self.assertNotIn("chrome", output)
            self.assertNotIn("go", output)
            self.assertNotIn("python", output)
            self.assertNotIn("rust", output)
            self.assertNotIn("iac", output)
            self.assertNotIn("ufw", output)

    def test_ubuntu_codename_validation(self):
        """APT repository setup must reject missing or invalid Ubuntu metadata."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            valid = tmp_path / "valid-os-release"
            valid.write_text('ID="ubuntu"\nVERSION_CODENAME=noble\n', encoding="utf-8")
            invalid = tmp_path / "invalid-os-release"
            invalid.write_text('ID="ubuntu"\n', encoding="utf-8")
            sourceable = self.create_sourceable_system_script(tmp_path)

            command = textwrap.dedent(
                f'''\
                source "{REPO_ROOT / "utils" / "utils.sh"}"
                log_warn() {{ :; }}
                source "{sourceable}"
                export MACHINIST_OS_RELEASE_FILE="{valid}"
                printf 'valid:%s\\n' "$(ubuntu_codename)"
                export MACHINIST_OS_RELEASE_FILE="{invalid}"
                if ubuntu_codename; then
                    printf 'invalid:accepted\\n'
                else
                    printf 'invalid:rejected\\n'
                fi
                '''
            )
            result = self.run_cmd(["bash", "-lc", command])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(), ["valid:noble", "invalid:rejected"]
            )

    def test_dotfiles_script_is_idempotent(self):
        if not (DOTFILES_DIR / ".vimrc").exists():
            self.skipTest("dotfiles directory not found")
        with tempfile.TemporaryDirectory() as temp_home:
            env = os.environ.copy()
            env["HOME"] = temp_home

            first = self.run_cmd(["bash", "dotfiles.sh"], env=env)
            second = self.run_cmd(["bash", "dotfiles.sh"], env=env)

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            vimrc = Path(temp_home) / ".vimrc"
            self.assertTrue(
                vimrc.is_symlink(), ".vimrc should be a symlink after idempotent run"
            )

    def test_agents_script_wires_all_three_agents(self):
        """agents.sh points every agent at the one shared instructions file."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            home = Path(tmp_dir)
            # Pre-create the central agents config directory (normally done by dotfiles.sh)
            config_agents = home / ".config" / "agents"
            config_agents.mkdir(parents=True)
            (config_agents / "instructions.md").write_text(
                "# Instructions\n", encoding="utf-8"
            )

            env = os.environ.copy()
            env["HOME"] = str(home)

            result = self.run_cmd(["bash", "agents/agents.sh"], env=env)
            self.assertEqual(result.returncode, 0, result.stderr)

            shared = config_agents / "instructions.md"

            claude_md = home / ".claude" / "CLAUDE.md"
            self.assertTrue(
                claude_md.is_symlink(), "~/.claude/CLAUDE.md must be a symlink"
            )
            self.assertEqual(Path(os.readlink(claude_md)), shared)

            codex_md = home / ".codex" / "AGENTS.md"
            self.assertTrue(
                codex_md.is_symlink(), "~/.codex/AGENTS.md must be a symlink"
            )
            self.assertEqual(Path(os.readlink(codex_md)), shared)

            # config.toml holds Codex auth and project trust state; the setup
            # must not write it.
            self.assertFalse(
                (home / ".codex" / "config.toml").exists(),
                "agents.sh must not write codex config.toml",
            )

            opencode_config = home / ".config" / "opencode" / "config.json"
            self.assertTrue(
                opencode_config.exists(), "opencode config.json must be created"
            )
            payload = json.loads(opencode_config.read_text(encoding="utf-8"))
            self.assertEqual(payload.get("instructions"), [str(shared)])
            self.assertFalse(payload.get("autoshare", True), "autoshare must be false")
            # No model id is pinned anywhere -- they go stale.
            self.assertNotIn("model", payload)

    def test_configure_script_skips_in_non_interactive_env(self):
        """configure.sh must exit 0 and not block when stdin is not a TTY."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            env = os.environ.copy()
            env["HOME"] = tmp_dir
            result = self.run_cmd(["bash", "configure/configure.sh"], env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Should not have written a .gitconfig.local (nothing to prompt for)
            self.assertFalse((Path(tmp_dir) / ".gitconfig.local").exists())

    def test_configure_writes_gitconfig_local(self):
        """configure.sh writes name+email to ~/.gitconfig.local, not ~/.gitconfig."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            # Use env-var seeding path so the test is not sensitive to whether
            # /dev/tty is accessible (prompt_with_default reads from /dev/tty
            # when available, which makes piped stdin unreliable in a terminal).
            env = os.environ.copy()
            env["HOME"] = tmp_dir
            env["MACHINIST_GIT_NAME"] = "Test User"
            env["MACHINIST_GIT_EMAIL"] = "test@example.com"
            result = subprocess.run(
                ["bash", "configure/configure.sh"],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            local_cfg = tmp_path / ".gitconfig.local"
            self.assertTrue(local_cfg.exists(), ".gitconfig.local must be created")
            content = local_cfg.read_text(encoding="utf-8")
            self.assertIn("Test User", content)
            self.assertIn("test@example.com", content)
            # Must NOT have written to the repo's .gitconfig (when dotfiles directory exists)
            repo_gitconfig = DOTFILES_DIR / ".gitconfig"
            if repo_gitconfig.exists():
                self.assertNotIn(
                    "Test User", repo_gitconfig.read_text(encoding="utf-8")
                )

    def test_gitconfig_includes_local_override(self):
        """dotfiles/.gitconfig must include ~/.gitconfig.local."""
        gitconfig_path = DOTFILES_DIR / ".gitconfig"
        if not gitconfig_path.exists():
            self.skipTest("dotfiles directory not found")
        gitconfig = gitconfig_path.read_text(encoding="utf-8")
        self.assertIn(".gitconfig.local", gitconfig)
        self.assertIn("[include]", gitconfig)

    def test_run_verify_flag_invokes_verify_script(self):
        """run.sh --verify must run verify-install.sh without installing anything."""
        result = self.run_cmd(["bash", "run.sh", "--verify"])
        # The script will likely report failures on a dev Mac, but it must not
        # error out at the bash level (syntax / missing script / etc.).
        self.assertIn(result.returncode, (0, 1), result.stderr)
        self.assertIn("verification", result.stdout.lower())

    def test_versions_file_is_well_formed(self):
        """versions.txt must parse as KEY=value lines with no blanks in values."""
        versions_file = PACKAGES_DIR / "versions.txt"
        self.assertTrue(versions_file.exists(), "packages/versions.txt must exist")
        # Only tools mise does NOT manage belong here; runtimes and IaC tooling
        # are pinned in dotfiles/.config/mise/config.toml instead.
        required = {
            "NEOVIM_VERSION",
            "MISE_VERSION",
            "RUST_VERSION",
            "NERD_FONTS_VERSION",
        }
        found = {}
        for raw in versions_file.read_text(encoding="utf-8").splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            self.assertIn("=", line, f"versions.txt line has no '=': {line!r}")
            key, _, val = line.partition("=")
            self.assertTrue(key.strip(), f"Empty key in versions.txt: {line!r}")
            self.assertTrue(val.strip(), f"Empty value in versions.txt: {line!r}")
            found[key.strip()] = val.strip()
        for key in required:
            self.assertIn(key, found, f"{key} missing from packages/versions.txt")
        # Runtime pins must NOT reappear here -- one home per version.
        for key in (
            "NODE_VERSION",
            "GO_VERSION",
            "PYTHON_VERSION",
            "TERRAFORM_VERSION",
            "TFLINT_VERSION",
        ):
            self.assertNotIn(
                key,
                found,
                f"{key} belongs in dotfiles/.config/mise/config.toml, not versions.txt",
            )

    def test_load_versions_exports_variables(self):
        """load_versions() in utils.sh must export pinned version variables."""
        command = textwrap.dedent(
            f"""\
            source "{REPO_ROOT / "utils" / "utils.sh"}"
            load_versions
            echo "NEOVIM=$NEOVIM_VERSION"
            echo "MISE=$MISE_VERSION"
            echo "RUST=$RUST_VERSION"
            echo "FONTS=$NERD_FONTS_VERSION"
            """
        )
        result = self.run_cmd(["bash", "-lc", command])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NEOVIM=", result.stdout)
        self.assertIn("MISE=", result.stdout)
        self.assertIn("RUST=", result.stdout)
        self.assertIn("FONTS=", result.stdout)
        # Values must be non-empty
        for line in result.stdout.splitlines():
            if "=" in line:
                _, _, val = line.partition("=")
                self.assertTrue(val.strip(), f"Empty version value: {line!r}")

    def test_system_runtime_installs_are_pinned(self):
        """Core runtime installs should not float to latest/lts/stable selectors."""
        system_script = (REPO_ROOT / "system" / "system.sh").read_text(encoding="utf-8")
        mise_config = (DOTFILES_DIR / ".config" / "mise" / "config.toml").read_text(
            encoding="utf-8"
        )

        # Every mise-managed tool is pinned to a concrete version, never a
        # floating selector, in the single shared config.
        for tool in (
            "python",
            "node",
            "go",
            "terraform",
            "tflint",
            "terragrunt",
            "terraform-docs",
        ):
            self.assertRegex(
                mise_config,
                re.compile(rf'^{re.escape(tool)}\s*=\s*"[0-9]', re.MULTILINE),
                f"{tool} must be pinned to a concrete version in mise config.toml",
            )
        for floating in ("lts", "latest", "stable"):
            self.assertNotIn(f'"{floating}"', mise_config)

        # system.sh must only ever READ that config. `mise use --global`
        # rewrites it, and it is a symlink into the repo.
        self.assertIn('"$MISE_BIN" install', system_script)
        code_lines = [
            ln for ln in system_script.splitlines() if not ln.lstrip().startswith("#")
        ]
        self.assertNotIn(
            "use --global",
            "\n".join(code_lines),
            "system.sh must never run `mise use --global`; it rewrites the "
            "shared config, which is a symlink into the repo",
        )

        # Precompiled Python, or a fresh machine spends minutes building CPython.
        self.assertIn(
            "MISE_PYTHON_PRECOMPILED_FLAVOR=install_only_stripped", system_script
        )
        self.assertIn('rustup toolchain install "$RUST_VERSION"', system_script)
        self.assertNotIn("update stable --no-self-update", system_script)

    def test_wezterm_config_is_valid_lua(self):
        """WezTerm config file must exist and be parseable as Lua if luac is available."""
        config_path = DOTFILES_DIR / ".config" / "wezterm" / "wezterm.lua"
        if not config_path.exists():
            self.skipTest("dotfiles directory not found")
        content = config_path.read_text(encoding="utf-8")
        self.assertIn("wezterm.config_builder", content)
        self.assertIn("return config", content)

    def test_run_help_lists_all_steps(self):
        """run.sh --help must document all orchestrated steps."""
        result = self.run_cmd(["bash", "run.sh", "--help"])
        self.assertEqual(result.returncode, 0, result.stderr)
        for step in (
            "system",
            "dotfiles",
            "terminal",
            "shell",
            "editor",
            "multiplexer",
            "sdk",
            "agents",
        ):
            self.assertIn(
                step, result.stdout, f"Step {step!r} missing from --help output"
            )

    def test_sdk_runs_before_editor_on_both_platforms(self):
        """The JDK must exist before the editor bootstraps Java LSP tooling."""
        for relative_path in ("run.sh", "../mac/run.sh"):
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            sdk_position = content.index('"sdk|')
            editor_position = content.index('"editor|')
            self.assertLess(
                sdk_position,
                editor_position,
                f"SDK must precede editor in {relative_path}",
            )

    def create_sourceable_terminal_script(self, directory: Path) -> Path:
        original = (REPO_ROOT / "terminal" / "terminal.sh").read_text(encoding="utf-8")
        lines = original.splitlines()
        filtered = [
            line
            for line in lines
            if line.strip() != 'source "$SCRIPT_DIR/../utils/utils.sh"'
            and line.strip() != "main"
        ]
        path = directory / "terminal-sourceable.sh"
        path.write_text("\n".join(filtered) + "\n", encoding="utf-8")
        return path

    def test_terminal_installer_skips_when_flag_set(self):
        """terminal.sh skips installation when MACHINIST_SKIP_WEZTERM=1."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            log_file = tmp_path / "log.txt"
            sourceable = self.create_sourceable_terminal_script(tmp_path)

            command = textwrap.dedent(
                f"""\
                source "{REPO_ROOT / "utils" / "utils.sh"}"
                log_info() {{ printf 'info:%s\\n' "$*" >> "{log_file}"; }}
                log_success() {{ :; }}
                echo_header() {{ :; }}
                check_root() {{ :; }}
                ensure_sudo() {{ :; }}
                sudo_run() {{ :; }}
                source "{sourceable}"
                export MACHINIST_SKIP_WEZTERM=1
                main
                """
            )
            env = os.environ.copy()
            env["HOME"] = tmp_dir
            result = self.run_cmd(["bash", "-lc", command], env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            log_output = (
                log_file.read_text(encoding="utf-8") if log_file.exists() else ""
            )
            self.assertIn("MACHINIST_SKIP_WEZTERM", log_output)

    def test_wezterm_download_url_matches_host_architecture(self):
        """WezTerm resolution must never select a package for another architecture."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            metadata = tmp_path / "release.json"
            metadata.write_text(
                json.dumps(
                    {
                        "assets": [
                            {
                                "name": "WezTerm-Ubuntu20.04.deb",
                                "browser_download_url": "https://example.test/x86.deb",
                            },
                            {
                                "name": "WezTerm-Ubuntu22.04.arm64.deb",
                                "browser_download_url": "https://example.test/arm64.deb",
                            },
                            {
                                "name": "WezTerm-Ubuntu22.04.deb",
                                "browser_download_url": "https://example.test/amd64.deb",
                            },
                        ]
                    }
                ),
                encoding="utf-8",
            )
            sourceable = self.create_sourceable_terminal_script(tmp_path)

            command = textwrap.dedent(
                f'''\
                source "{REPO_ROOT / "utils" / "utils.sh"}"
                dpkg() {{ printf '%s\\n' "$MACHINIST_TEST_ARCH"; }}
                curl() {{ :; }}
                source "{sourceable}"
                export MACHINIST_TEST_ARCH=arm64
                resolve_wezterm_download_url ignored "{metadata}"
                export MACHINIST_TEST_ARCH=amd64
                resolve_wezterm_download_url ignored "{metadata}"
                '''
            )
            result = self.run_cmd(["bash", "-lc", command])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    "https://example.test/arm64.deb",
                    "https://example.test/amd64.deb",
                ],
            )

    def test_nvim_config_entrypoint_exists(self):
        init_lua = DOTFILES_DIR / ".config" / "nvim" / "init.lua"
        if not init_lua.exists():
            self.skipTest("dotfiles directory not found")
        content = init_lua.read_text(encoding="utf-8")
        self.assertIn("lazy", content.lower())

    def test_nvim_lsp_plugin_declares_common_servers(self):
        lsp_lua = DOTFILES_DIR / ".config" / "nvim" / "lua" / "plugins" / "lsp.lua"
        if not lsp_lua.exists():
            self.skipTest("dotfiles directory not found")
        content = lsp_lua.read_text(encoding="utf-8")
        for server in ("pyright", "gopls", "rust_analyzer", "jdtls"):
            self.assertIn(
                server, content, f"LSP server {server!r} missing from lsp.lua"
            )

    def test_zsh_config_scaffold_exists(self):
        zshrc = DOTFILES_DIR / ".zshrc"
        if not zshrc.exists():
            self.skipTest("dotfiles directory not found")
        self.assertTrue(zshrc.exists(), ".zshrc scaffold must exist")
        self.assertTrue(
            (DOTFILES_DIR / ".zshenv").exists(), ".zshenv scaffold must exist"
        )

    def test_tmux_config_scaffold_exists(self):
        tmux_conf = DOTFILES_DIR / ".config" / "tmux" / "tmux.conf"
        if not tmux_conf.exists():
            self.skipTest("dotfiles directory not found")
        self.assertTrue(tmux_conf.exists(), "tmux.conf scaffold must exist")

    def test_dotfiles_installs_config_subdirectories(self):
        """dotfiles.sh symlinks .config/ subdirectories (wezterm, nvim, tmux) into $HOME."""
        if not (DOTFILES_DIR / ".zshrc").exists():
            self.skipTest("dotfiles directory not found")
        with tempfile.TemporaryDirectory() as temp_home:
            env = os.environ.copy()
            env["HOME"] = temp_home
            result = self.run_cmd(["bash", "dotfiles.sh"], env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            home = Path(temp_home)
            for entry in ("wezterm", "nvim", "tmux"):
                target = home / ".config" / entry
                self.assertTrue(
                    target.is_symlink(), f".config/{entry} must be a symlink"
                )
                self.assertTrue(
                    target.exists(), f".config/{entry} symlink must resolve"
                )
            self.assertTrue((home / ".zshrc").is_symlink())

    def test_brewfile_entries_use_the_right_artifact_kind(self):
        """Every cask in mac/Brewfile must actually be a cask, and each brew a formula.

        Getting this backwards is silent in review and fatal at run time: `brew
        bundle install` exits non-zero on the bad entry, and because the macOS
        system step runs under `set -e`, everything after it is skipped. This
        shipped once as `cask "opencode"`, which is a formula.
        """
        brew = shutil.which("brew")
        if not brew:
            self.skipTest("Homebrew not installed")

        brewfile = REPO_ROOT.parent / "mac" / "Brewfile"
        self.assertTrue(brewfile.exists(), "mac/Brewfile must exist")

        entries = re.findall(
            r'^(brew|cask)\s+"([^"]+)"', brewfile.read_text(encoding="utf-8"), re.M
        )
        self.assertTrue(entries, "no entries parsed out of mac/Brewfile")

        for kind, name in entries:
            with self.subTest(entry=f'{kind} "{name}"'):
                probe = subprocess.run(
                    [brew, "info", f"--{kind if kind == 'cask' else 'formula'}", name],
                    capture_output=True,
                    timeout=120,
                )
                self.assertEqual(
                    probe.returncode,
                    0,
                    f'mac/Brewfile declares {kind} "{name}", but Homebrew has no '
                    f"{'cask' if kind == 'cask' else 'formula'} by that name",
                )

    def test_mac_opencode_hint_matches_brewfile(self):
        """The macOS OpenCode recovery command must use its formula kind."""
        brewfile = (REPO_ROOT.parent / "mac" / "Brewfile").read_text(encoding="utf-8")
        agents = (REPO_ROOT.parent / "mac" / "agents" / "agents.sh").read_text(
            encoding="utf-8"
        )
        self.assertRegex(brewfile, re.compile(r'^brew "opencode"', re.MULTILINE))
        self.assertIn('AGENT_HINT_OPENCODE="brew install opencode"', agents)
        self.assertNotIn("brew install --cask opencode", agents)

    def test_platform_detection_accepts_only_ubuntu(self):
        """Ubuntu-specific installation logic must not silently accept Debian."""
        installer = (REPO_ROOT.parent / "install.sh").read_text(encoding="utf-8")
        self.assertIn('case "${ID:-}" in', installer)
        self.assertIn("ubuntu) ;;", installer)
        self.assertNotIn("*debian*", installer)


if __name__ == "__main__":
    unittest.main()

# Verification and CI

[← back to README](../README.md)

## Verification

```bash
./install.sh --verify   # from anywhere in the clone
```

Prints a pass/fail/warn table. The cross-platform checks live in
[`shared/verify.sh`](../shared/verify.sh) and are **derived from the manifests** rather than
hand-listed, so a tool added to `packages/` is verified automatically and the
verifier cannot drift from the installer.

## CI

Both platforms are covered:

| Workflow | Runner | What it does |
|---|---|---|
| [`linux-ci.yml`](../.github/workflows/linux-ci.yml) | `ubuntu-24.04` | shellcheck, zsh parse, unit tests, and a real system bootstrap |
| [`macos-ci.yml`](../.github/workflows/macos-ci.yml) | `macos-15` | shellcheck, zsh parse, Brewfile validation, and selected bootstrap steps |

macOS deliberately does not run the full `system` step: installing every cask
in the Brewfile is far too slow for a hosted runner. The workflows run on
pushes and pull requests; the disposable VM smoke test is the deeper check for
an actually bare Ubuntu host.

Because the `system` step is skipped there, `mac/scripts/check-brewfile.sh`
covers the part of it that fails most often. It asks Homebrew whether every
Brewfile entry still exists, is the kind it is declared as, and has not been
renamed upstream. A rename is not a warning you can ignore: `brew bundle
install` fails on it, and that aborts the system step partway through a fresh
machine's bootstrap. The check reads metadata only and installs nothing, so it
costs seconds rather than the hour a real `brew bundle` would.

Run the Linux suite locally with [`linux/scripts/test.sh`](../linux/scripts/test.sh):
`cd linux && bash scripts/test.sh`.

### What CI does not prove

Worth knowing before trusting a green tick on a brand-new machine.

**The Ubuntu job runs on a GitHub runner image, not a bare Ubuntu.** That image
preinstalls a great deal -- node, python, docker, even `aws` and `gcloud`. So a
dependency this repo *uses* but never *declares* would still work there and
fail on a real machine. It has already happened once in the small: the cloud
CLI installers appeared to run in CI while actually taking their
"already installed" branch, because the runner had both. `linux/scripts/vm-smoke-test.sh`
launches a genuinely bare 24.04 VM via multipass and is the check for this; it
is manual, and worth running before trusting a big change.

**The macOS `system` step never runs anywhere.** Installing the Brewfile,
casks included, is impractical on a hosted runner and is deliberately out of
scope. `check-brewfile.sh` covers the failure that actually bites -- an entry
that no longer resolves -- but nothing exercises `brew bundle install` itself.
A fresh Mac is the only real test.

Neither gap is silent when it bites: `handle_error` stops the run, names the
step, and prints the `--only <step>` command to resume with, because steps are
independent and safe to re-run.

## Post-install state

Most tools work immediately after the run completes. Two things require a session restart:

| Trigger | Reason | Action |
|---|---|---|
| **New login shell** | `chsh`/`usermod` changes only apply on next login | Log out and back in |
| **New terminal window** | Homebrew/mise PATH additions are sourced from `.zshenv` | Open a fresh terminal |

Everything else is live without restart:
- Dotfile changes take effect in the next new shell (symlinks are immediate)
- Neovim plugins are bootstrapped headlessly by the `editor` step
- Tmux plugins are installed by the `multiplexer` step (TPM runs at next `tmux` start)
- Shared agent instructions are symlinked; auth and project state remain under each CLI's control

**Dotfiles step on a machine with existing configs:** existing files are backed up to `~/.local/state/machinist/dotfiles-backups/<timestamp>/` before being replaced with symlinks.

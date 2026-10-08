# Getting Started

## Intended Flow

The default order is defined in [`linux/run.sh`](../run.sh):

1. `system`
2. `dotfiles`
3. `configure`
4. `shell`
5. `sdk`
6. `editor`
7. `multiplexer`
8. `terminal`
9. `agents`

Run [`linux/run.sh`](../run.sh) from `linux/`; a plain `./run.sh` is the normal
entrypoint on a fresh machine.

## Base Install

Install Git, clone the repository, and run:

```bash
./run.sh
```

This path is meant to work for a generic Ubuntu developer workstation with `sudo` access.

For unattended execution, pass Git identity so the configure step is non-blocking:

```bash
MACHINIST_GIT_NAME="Your Name" MACHINIST_GIT_EMAIL="you@example.com" ./run.sh
```

## Optional Steps

Default run includes all steps, including:

- GitHub SSH setup (`git`)
- GNOME desktop preferences (`settings`)

If you want a non-interactive or server-style path, skip them:

```bash
./run.sh --skip-git --skip-settings
```

## Running Individual Steps

Use `--only` when you want to rerun or isolate a module:

```bash
./run.sh --only system
./run.sh --only dotfiles
./run.sh --only configure
./run.sh --only agents
```

`run.sh` will warn when you select a step without its usual dependency.

## Verification

To check the installed toolchain without making changes:

```bash
./run.sh --verify
```

For repository gates:

```bash
bash scripts/test.sh
```

Every `run.sh` execution writes a timestamped log by default:

- `~/.local/state/machinist/logs/run-YYYYMMDD-HHMMSS.log`

If that location is not writable, `run.sh` automatically falls back to:

- `${TMPDIR:-/tmp}/machinist-logs/run-YYYYMMDD-HHMMSS.log`

You can set a custom path explicitly:

```bash
MACHINIST_LOG_FILE="$HOME/.local/state/machinist/logs/my-run.log" ./run.sh
```

## After Bootstrap

Typical follow-up actions:

- open a new shell so `mise` and shell changes are active everywhere
- pick your zsh profile (`antidote-p10k` by default, or `zsh4humans`)
- review agent links and add credentials through the agents' own setup
- rerun any optional steps you intentionally skipped the first time
- adjust manifests or dotfiles only after the base install is stable

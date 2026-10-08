# Git configuration

[← back to README](../README.md)

## Git configuration

[`dotfiles/.gitconfig`](../dotfiles/.gitconfig) is symlinked to `~/.gitconfig` and includes
`~/.gitconfig.local` at the end, which is where your name, email and
credential helper live. That file is machine-local and never committed; the
`configure` step writes it for you.

Opinionated defaults worth knowing about:

| Setting | Effect |
|---|---|
| `pull.rebase = true` | `git pull` rebases, never merges |
| `rerere.enabled = true` | Conflict resolutions are recorded and replayed on the next rebase |
| `push.default = current` + `push.autoSetupRemote` | `git push` on a new branch just works, no `--set-upstream` |
| `fetch.prune = true` | Deleted upstream branches disappear locally on fetch |
| `merge.conflictstyle = zdiff3` | Conflict markers include the common ancestor |
| `init.defaultBranch = main` | |

`format.pretty` and `diff.word-diff` are deliberately **not** set globally.
Both look appealing but apply far wider than intended: `format.pretty` also
governs `git show`, where a one-line format hides the commit body and author,
and a global `word-diff` makes `git diff` output stop round-tripping through
`git apply`. Use the `l` / `lg` and `dw` aliases instead.

Note that git silently ignores any alias that shadows a builtin, so `add`,
`diff`, `pull`, `remote` and `tag` cannot be aliased. Those are `rv` and `ta`
here; `pull` and `diff` behaviour comes from config instead.

## What the git step wires up

The platform implementation is [`mac/git/git.sh`](../mac/git/git.sh) or
[`linux/git/git.sh`](../linux/git/git.sh).

Installing `git-lfs`, `gh` and an SSH key is not the same as having them work.
The step also does the wiring that each one needs before it does anything:

- **git-lfs filters.** `git lfs install --skip-repo` registers the clean and
  smudge filters in `~/.gitconfig`. Without them an LFS clone gives you
  pointer files instead of content, and nothing warns you.
- **`gh` uses SSH.** The step generates an ed25519 key and uploads it, so
  `gh` is set to `git_protocol = ssh` to match. Left at the default it clones
  over HTTPS and prompts for credentials the key would have covered.
- **`~/.ssh/config`.** A `# managed by machinist` block is *prepended* with
  `AddKeysToAgent yes`, `IdentityFile ~/.ssh/id_ed25519`, and `UseKeychain yes`
  on macOS. Prepended, because ssh honours the **first** value it sees for a
  keyword, so appending to a file that already has a `Host *` block does
  nothing. If more than one `Host *` block exists the step says so rather than
  guessing which one you meant.

**The global gitignore is deliberately small.**
[`dotfiles/.gitignore_global`](../dotfiles/.gitignore_global)
covers OS metadata, editor scratch files and local tool state only. Build
output and language artefacts are a property of the project, not the machine,
and belong in the project's own `.gitignore`.

This is a change in policy: the file used to be a 1040-line gitignore.io dump
covering 20+ languages, which globally ignored `pom.xml`, `Cargo.lock`,
`bower.json`, `target/`, `build/`, `lib/`, `bin/`, `dist/` and `out/`. Files
matching those patterns silently failed to be added in *every* repository on
the machine. If you were relying on that, add the patterns to the individual
projects that need them.

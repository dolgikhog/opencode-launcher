# start-opencode

Run OpenCode CLI inside a sandboxed Docker container. Your project is mounted at `/workspace`, config and auth keys persist across runs, and SSH/git access works out of the box.

## Project Structure

```
.
├── start-opencode              # Main script (builds + runs the container)
├── completions/
│   └── _start-opencode         # Zsh autocompletion
└── .gitignore
```

## Prerequisites

- Docker
- Bash

## Installation

Clone the repo and make the script available on your PATH:

```bash
git clone <repo-url>
ln -s "$(pwd)/start-opencode" /usr/local/bin/start-opencode
```

## Usage

```bash
start-opencode <path-to-project>
```

Rebuild the Docker image from scratch:

```bash
start-opencode --rebuild <path-to-project>
```

## Zsh Autocompletion

Add the completions directory to your `fpath` in `~/.zshrc` (before `compinit`):

```zsh
fpath=(/path/to/this-repo/completions $fpath)
autoload -Uz compinit && compinit
```

Or symlink the file directly:

```bash
mkdir -p ~/.zsh/completions
ln -sf /path/to/this-repo/completions/_start-opencode ~/.zsh/completions/_start-opencode
```

Then ensure `~/.zshrc` has:

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

Restart your shell or run `exec zsh` to pick up changes.

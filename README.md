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

## Web Mode

Run OpenCode as a web application accessible from your browser:

```bash
start-opencode --web <path-to-project>
```

This starts the container with a web server on port `3000` by default. Open `http://localhost:3000` in your browser to access the interface.

### Custom port

```bash
start-opencode --web --web-port 8080 <path-to-project>
```

### Authentication

To protect the web interface with a password, use the `--server-password` flag:

```bash
start-opencode --web --server-password mySecretPassword <path-to-project>
```

When a password is set, your browser will prompt you for credentials on first visit. The default username is `opencode`. To use a custom username:

```bash
start-opencode --web --server-password mySecretPassword --server-username admin <path-to-project>
```

> **Note:** If you don't set a password, the web interface will be accessible to anyone who can reach the port. Always use `--server-password` when exposing the server on a network.

### Combining flags

```bash
start-opencode --rebuild --web --web-port 8080 --server-password myPassword --server-username admin <path-to-project>
```

## GitHub CLI Authentication

The container uses the `GH_TOKEN` environment variable to authenticate with GitHub. To enable `gh` commands inside the container, generate a personal access token and export it before running the script:

```bash
export GH_TOKEN="ghp_your_token_here"
start-opencode <path-to-project>
```

Or pass it inline:

```bash
GH_TOKEN="ghp_your_token_here" start-opencode <path-to-project>
```

To generate a token, visit [GitHub Settings > Developer settings > Personal access tokens](https://github.com/settings/tokens) and create a token with the scopes you need (e.g. `repo`, `read:org`).

For persistence, add `export GH_TOKEN="ghp_..."` to your `~/.zshrc` or `~/.bashrc`.

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

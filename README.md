# start-opencode.sh

Run OpenCode CLI inside a sandboxed Docker container. Your project is mounted at `/workspace`, config and auth keys persist across runs, and SSH/git access works out of the box.

## Project Structure

```
.
├── start-opencode.sh           # Main script (builds + runs the container)
├── opencode.json               # Base OpenCode config (plugins, models, shared settings)
├── config/                     # Base agents, skills, commands, plugins (applied to all projects)
│   ├── agents/
│   ├── skills/
│   ├── commands/
│   └── plugins/
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
ln -s "$(pwd)/start-opencode.sh" /usr/local/bin/start-opencode
```

## Usage

```bash
start-opencode <path-to-project>
```

Rebuild the Docker image from scratch:

```bash
start-opencode --rebuild <path-to-project>
```

## Configuration

OpenCode configuration is layered. The script provides a **base config** that applies to all projects, while each project can have its own **project config** that overrides or extends the base. OpenCode merges them automatically.

### Per-project isolation

Each project gets its own fully isolated environment on the host at `~/.opencode_docker_config/<project-name>-<hash>/`. This means auth tokens, sessions, plugin cache, and all other state are completely separate between projects. The directory name combines the project folder name with a short hash of its absolute path for uniqueness.

Only the base config from this repo (`opencode.json` and `config/`) is shared across projects -- mounted read-only into every container.

### Base config (this repo)

- **`opencode.json`** -- shared settings applied to every project: plugins, default model, permissions, etc.
- **`config/`** -- shared agents, skills, commands, and plugins applied to every project.

Edit these files to change the defaults for all projects.

### Project config (in each project)

Each project can optionally include:

- **`opencode.json`** at the project root -- project-specific plugins and provider settings.
- **`.opencode/`** directory -- project-specific agents, skills, commands.

Project config overrides base config for conflicting keys. Non-conflicting settings from both are preserved.

### Example

Base `opencode.json` (this repo):

```json
{
  "plugin": ["some-shared-plugin"],
  "model": "anthropic/claude-sonnet-4-5"
}
```

Project `opencode.json` (in your project root):

```json
{
  "plugin": ["opencode-gemini-auth@latest"],
  "provider": {
    "google": { ... }
  }
}
```

Both plugin arrays are merged. The project gets shared plugins plus its own.

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
start-opencode --rebuild --web --web-port 8080 --server-password myPassword --server-username admin --env "MY_VAR=value" <path-to-project>
```

## Custom Environment Variables

Pass arbitrary environment variables into the container with `--env`:

```bash
start-opencode --env "MY_VAR=value" <path-to-project>
```

Multiple variables can be passed by repeating the flag:

```bash
start-opencode --env "OPENCODE_HEADLESS=1" --env "OPENCODE_GEMINI_PROJECT_ID=my-project" <path-to-project>
```

This is useful for configuring plugins or features that rely on environment variables (e.g. Google OAuth for Gemini Code Assist -- see [GOOGLE_AUTH.md](GOOGLE_AUTH.md)).

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

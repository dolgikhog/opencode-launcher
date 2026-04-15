# start-opencode.sh

Run [OpenCode](https://github.com/nicepkg/opencode) CLI inside a sandboxed Docker container. Your project is mounted at `/workspace`, config and auth keys persist across runs, and SSH/git access works out of the box.

## Why a container?

Modern AI coding agents run directly on your machine — they can read any file your user can, access environment variables (API keys, tokens, credentials), browse your home directory, and execute arbitrary shell commands. That's a lot of trust to place in a tool that's essentially an LLM deciding what to do next.

Running OpenCode inside a Docker container solves this by giving the agent **only what it needs** for a particular project:

- **Security** — the agent can only see the project directory you explicitly mount. Your home directory, other projects, host credentials, and system files are invisible. Environment variables are passed in selectively, not inherited wholesale.
- **Ready to go** — the container ships pre-configured with tools (git, gh, node, python, ripgrep, etc.), plugins, agent configs, and LSP servers. Anyone on the team can `start-opencode <project>` without setting up anything themselves.
- **Consistent environment** — same toolchain regardless of whether the host is macOS, Ubuntu, or Arch. No "works on my machine" issues for the AI agent.
- **Per-project isolation** — each project gets its own state directory (auth tokens, sessions, plugin cache). One project's config never leaks into another.
- **Clean teardown** — when the container stops, everything outside `/workspace` disappears. No leftover processes, temp files, or daemon state on the host.
- **Web access** — run OpenCode as a web app accessible from your phone or tablet on the same network, with authentication and LAN-only binding handled automatically.

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

This starts the container with a web server on port `3000` by default. The server automatically binds to your local network IP, so you can access it from any device on the same WiFi/LAN (phone, tablet, another laptop) while keeping it inaccessible from the public internet.

The startup output will show the access URL, e.g.:

```
  Access URL:
    http://192.168.1.50:3000

  Bound to LAN only (192.168.1.50)
  Use this URL from any device on your network.
```

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

### Why LAN-only by default?

The web server is bound to your machine's local network IP rather than `0.0.0.0` (all interfaces). This is intentional — when working with company projects, you don't want the interface publicly reachable. Binding to the LAN IP means:

- **Same WiFi/LAN**: your phone, tablet, or other laptops can connect.
- **Outside your network**: nobody can reach it.

This is enforced at the Docker port-mapping level (`-p <lan-ip>:3000:3000`), not within OpenCode itself — so it works regardless of what the application does internally. The OpenCode server inside the container still listens on `0.0.0.0`, but Docker only forwards traffic arriving on your LAN IP.

If auto-detection fails (e.g. no network), it falls back to `0.0.0.0` with a warning.

### Combining flags

```bash
start-opencode --rebuild --with-omo --web --web-port 8080 --server-password myPassword --server-username admin --env "MY_VAR=value" --env-redact "SECRET_KEY=abc" --expose-port 5173 <path-to-project>
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

### Sensitive variables (`--env-redact`)

For environment variables containing secrets (API keys, tokens, passwords), use `--env-redact` instead of `--env`. The variable is passed into the container identically, but its value is masked in all startup logs:

```bash
start-opencode --env-redact "SECRET_API_KEY=sk-abc123" <path-to-project>
```

In the logs you'll see `SECRET_API_KEY=***REDACTED***` instead of the actual value. You can mix `--env` and `--env-redact` freely:

```bash
start-opencode --env "NODE_ENV=production" --env-redact "DATABASE_URL=postgres://..." <path-to-project>
```

> **Note:** `--server-password` is automatically redacted in logs — you don't need to do anything extra for it.

### Showing redacted values (`--expose-env`)

If you need to debug environment variable issues and want to see all values including redacted ones, pass `--expose-env`:

```bash
start-opencode --expose-env --env-redact "SECRET_API_KEY=sk-abc123" <path-to-project>
```

This overrides all redaction and shows raw values in the startup logs. Only use this for debugging — don't leave it on in normal usage.

## Exposing Additional Ports

If your project runs a dev server, database, or any other service that needs to be reachable from the host, use `--expose-port`:

```bash
start-opencode --expose-port 5173 <path-to-project>
```

This maps host port 5173 to container port 5173. Repeat the flag for multiple ports:

```bash
start-opencode --expose-port 5173 --expose-port 5432 <path-to-project>
```

## GitHub CLI Authentication

The container uses the `GH_TOKEN` environment variable to authenticate with GitHub. Pass it like any other secret:

```bash
start-opencode --env-redact "GH_TOKEN=ghp_your_token_here" <path-to-project>
```

To generate a token, visit [GitHub Settings > Developer settings > Personal access tokens](https://github.com/settings/tokens) and create a token with the scopes you need (e.g. `repo`, `read:org`).

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

## oh-my-opencode Integration (`--with-omo`)

Enable the [oh-my-opencode](https://github.com/nicepkg/oh-my-opencode) agent plugin with `--with-omo`:

```bash
start-opencode --with-omo <path-to-project>
```

This does two things:

1. **Installs the oh-my-opencode plugin** — adds it to the container's `opencode.json` and writes an `oh-my-openagent.jsonc` config with agent model assignments (Sisyphus, Oracle, Prometheus, etc.) and LSP settings (e.g. Kotlin LSP with JVM tuning).
2. **Injects Docker context into the agent's system prompt** — so the agent knows it's running inside a container and can act accordingly (see below).

### Docker context awareness

When `--with-omo` is active, the script assembles a runtime context string and embeds it into the agent's system prompt via oh-my-openagent's `prompt_append` field. The agent learns what container it's in, what tools are installed, which credentials are available (SSH, GitHub CLI, git config), whether it's in web mode, and what constraints apply (no sudo, ephemeral filesystem outside `/workspace`).

This context is assembled dynamically at launch time based on what the script actually passes into the container — so if you don't mount SSH keys, the agent knows SSH isn't available.

#### Why `prompt_append` and not native OpenCode config?

OpenCode has a `contextPaths` config key in its source code that would do exactly this — point to an arbitrary markdown file and inject it into the system prompt. However, the released versions don't recognize this key yet (the project-level `opencode.json` rejects it as `Unrecognized key: "contextPaths"`).

The next option was using a `file://` URI in oh-my-openagent's `prompt_append` field, pointing to a generated markdown file mounted at `/etc/opencode/`. This also failed — oh-my-openagent has a security check (`isWithinProject`) that rejects file URIs pointing outside the project root (`/workspace`).

The working solution: the script builds the context string in bash, JSON-escapes it, and inlines it directly into `oh-my-openagent.jsonc` as the `sisyphus.prompt_append` value. No external file references, no project directory pollution. The context lives in the per-project config directory alongside `oh-my-openagent.jsonc` and gets appended to the Sisyphus agent's system prompt at startup.

When OpenCode ships `contextPaths` support in a release, this can be simplified to a single config entry pointing to a mounted markdown file.

#!/bin/bash

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
# Coloured, timestamped log functions.  Every message is prefixed with a
# level tag and an ISO-8601-ish timestamp so that it is easy to correlate
# events when troubleshooting.
#
# Levels:
#   DEBUG – verbose detail, useful when diagnosing build or mount problems
#   INFO  – normal operational messages (default visibility)
#   WARN  – non-fatal issues the user should be aware of
#   ERROR – fatal problems that will cause the script to exit
# ---------------------------------------------------------------------------
_CLR_RESET='\033[0m'
_CLR_GREY='\033[0;90m'
_CLR_BLUE='\033[0;34m'
_CLR_YELLOW='\033[0;33m'
_CLR_RED='\033[0;31m'
_CLR_GREEN='\033[0;32m'
_CLR_CYAN='\033[0;36m'

_log_ts() { date '+%H:%M:%S'; }

log_debug() { echo -e "${_CLR_GREY}[$(_log_ts)] [DEBUG] $*${_CLR_RESET}"; }
log_info()  { echo -e "${_CLR_BLUE}[$(_log_ts)] [INFO]${_CLR_RESET}  $*"; }
log_ok()    { echo -e "${_CLR_GREEN}[$(_log_ts)] [OK]${_CLR_RESET}    $*"; }
log_warn()  { echo -e "${_CLR_YELLOW}[$(_log_ts)] [WARN]${_CLR_RESET}  $*" >&2; }
log_error() { echo -e "${_CLR_RED}[$(_log_ts)] [ERROR]${_CLR_RESET} $*" >&2; }

# Print a section banner to visually separate phases of execution
log_section() {
  echo ""
  echo -e "${_CLR_CYAN}── $* ──${_CLR_RESET}"
}

# ---------------------------------------------------------------------------
# Redaction helpers
# ---------------------------------------------------------------------------
# These functions operate on structured data (word lists / arrays) rather than
# flattened strings, which avoids the fragile regex problem where e.g. an SSH
# "-i" flag gets mistaken for a docker "-e" flag.
#
# _redact_raw_args  – sanitises the saved $* string for the deferred log.
#                     Walks word-by-word; after --env-redact or
#                     --server-password the next word's value is replaced.
#
# _redact_docker_args – iterates the DOCKER_ARGS array.  After a "-e" element
#                       it checks whether the key is in REDACTED_KEYS; if so
#                       the value portion is replaced with ***REDACTED***.
# ---------------------------------------------------------------------------
_redact_raw_args() {
  local -a words=($*)
  local out="" redact_next=false mask_next=false
  for w in "${words[@]}"; do
    if [ "$redact_next" = true ]; then
      # KEY=VALUE → KEY=***REDACTED***
      out+="${w%%=*}=***REDACTED*** "
      redact_next=false
    elif [ "$mask_next" = true ]; then
      out+="***REDACTED*** "
      mask_next=false
    elif [ "$w" = "--env-redact" ]; then
      out+="$w "
      redact_next=true
    elif [ "$w" = "--server-password" ]; then
      out+="$w "
      mask_next=true
    else
      out+="$w "
    fi
  done
  echo "${out% }"
}

_redact_docker_args() {
  local -a args=("$@")
  local out="" i=0 len=${#args[@]}
  while [ $i -lt $len ]; do
    local elem="${args[$i]}"
    if [ "$elem" = "-e" ] && [ $((i+1)) -lt $len ]; then
      local pair="${args[$((i+1))]}"
      local key="${pair%%=*}"
      if _is_redacted_key "$key"; then
        out+="$elem ${key}=***REDACTED*** "
      else
        out+="$elem $pair "
      fi
      i=$((i+2))
    else
      out+="$elem "
      i=$((i+1))
    fi
  done
  echo "${out% }"
}

# Check if a key name is in the REDACTED_KEYS array
_is_redacted_key() {
  local needle="$1"
  for k in "${REDACTED_KEYS[@]}"; do
    [ "$k" = "$needle" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REBUILD=false
WEB_MODE=false
WITH_OMO=false
EXPOSE_ENV=false
WEB_PORT=3000
SERVER_PASSWORD=""
SERVER_USERNAME=""
CUSTOM_ENVS=()
REDACTED_KEYS=()
EXPOSE_PORTS=()

USAGE="Usage: start-opencode [--rebuild] [--env KEY=VALUE]... [--env-redact KEY=VALUE]... [--expose-env] [--expose-port <port>]... [--with-omo] [--web [--web-port <port>] [--server-password <password>] [--server-username <username>]] <path-to-project>"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
log_section "Parsing arguments"
# Save raw args for logging after we know whether --expose-env was passed
_RAW_ARGS="$*"

PROJECT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      REBUILD=true
      log_info "Flag: --rebuild enabled"
      shift
      ;;
    --env)
      CUSTOM_ENVS+=("$2")
      log_info "Flag: --env '$2'"
      shift 2
      ;;
    --env-redact)
      CUSTOM_ENVS+=("$2")
      REDACTED_KEYS+=("${2%%=*}")
      log_info "Flag: --env-redact '${2%%=*}=***REDACTED***'"
      shift 2
      ;;
    --expose-port)
      EXPOSE_PORTS+=("$2")
      log_info "Flag: --expose-port '$2'"
      shift 2
      ;;
    --with-omo)
      WITH_OMO=true
      log_info "Flag: --with-omo enabled"
      shift
      ;;
    --expose-env)
      EXPOSE_ENV=true
      log_info "Flag: --expose-env enabled (sensitive values will be shown in logs)"
      shift
      ;;
    --web)
      WEB_MODE=true
      log_info "Flag: --web enabled"
      shift
      ;;
    --web-port)
      WEB_PORT="$2"
      log_info "Flag: --web-port '$2'"
      shift 2
      ;;
    --server-password)
      SERVER_PASSWORD="$2"
      log_info "Flag: --server-password (set, value hidden)"
      shift 2
      ;;
    --server-username)
      SERVER_USERNAME="$2"
      log_info "Flag: --server-username '$2'"
      shift 2
      ;;
    --*)
      log_error "Unknown option: $1"
      echo "$USAGE"
      exit 1
      ;;
    *)
      PROJECT_ARG="$1"
      log_info "Project path argument: '$1'"
      shift
      ;;
  esac
done

# Deferred log: now that we know whether --expose-env was passed, log raw args
if [ "$EXPOSE_ENV" = true ]; then
  log_debug "Raw arguments: $_RAW_ARGS"
else
  log_debug "Raw arguments: $(_redact_raw_args "$_RAW_ARGS")"
fi

# Ensure a project path was provided
if [ -z "$PROJECT_ARG" ]; then
  log_error "No project path provided."
  echo "$USAGE"
  exit 1
fi

# ---------------------------------------------------------------------------
# Project path resolution
# ---------------------------------------------------------------------------
log_section "Resolving project path"
log_debug "Raw project argument: '$PROJECT_ARG'"

PROJECT_PATH=$(realpath "$PROJECT_ARG")
log_info "Resolved absolute path: $PROJECT_PATH"

# Verify the directory exists
if [ ! -d "$PROJECT_PATH" ]; then
  log_error "Directory '$PROJECT_PATH' does not exist."
  exit 1
fi
log_ok "Project directory exists"

# ---------------------------------------------------------------------------
# Config directory setup
# ---------------------------------------------------------------------------
log_section "Setting up configuration"

IMAGE_NAME="opencode-sandbox"
# Each project gets its own isolated home directory (auth, sessions, cache, etc.)
# Derive a stable subdirectory from the project path: <basename>-<short-hash>
PROJECT_HASH=$(printf '%s' "$PROJECT_PATH" | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12)
PROJECT_NAME=$(basename "$PROJECT_PATH")
CONFIG_DIR="$HOME/.opencode_docker_config/${PROJECT_NAME}-${PROJECT_HASH}"

log_debug "Docker image name: $IMAGE_NAME"
log_debug "Project name:      $PROJECT_NAME"
log_debug "Project hash:      $PROJECT_HASH"
log_info  "Config directory:   $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"
log_ok "Config directory ready"

# Resolve the directory where this script (and base config files) live
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_CONFIG="$SCRIPT_DIR/opencode.json"
BASE_CONFIG_DIR="$SCRIPT_DIR/config"
log_debug "Script directory:   $SCRIPT_DIR"
log_debug "Base config file:   $BASE_CONFIG (exists: $([ -f "$BASE_CONFIG" ] && echo yes || echo no))"
log_debug "Base config dir:    $BASE_CONFIG_DIR (exists: $([ -d "$BASE_CONFIG_DIR" ] && echo yes || echo no))"

# ---------------------------------------------------------------------------
# Docker image build
# ---------------------------------------------------------------------------
log_section "Docker image"

# If --rebuild was passed, force remove the existing image
if [ "$REBUILD" = true ] && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  log_warn "Rebuild requested – removing existing Docker image '$IMAGE_NAME'..."
  docker rmi -f "$IMAGE_NAME"
  log_ok "Existing image removed"
elif [ "$REBUILD" = true ]; then
  log_info "Rebuild requested but image '$IMAGE_NAME' does not exist – will build fresh"
fi

# Build the Docker image if it hasn't been built yet
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  log_info "Docker image '$IMAGE_NAME' not found. Building it now (this only happens once)..."
  log_debug "Building from embedded Dockerfile (stdin heredoc)"

  # Embeds the Dockerfile directly to keep this a single-file solution
  docker build -t "$IMAGE_NAME" - << 'EOF'
FROM ubuntu:24.04

# Prevent interactive prompts during package installations
ENV DEBIAN_FRONTEND=noninteractive

# Install essential dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    openssh-client \
    default-jre \
    nodejs \
    npm \
    python3 \
    build-essential \
    ca-certificates \
    jq \
    unzip \
    zip \
    ripgrep \
    less \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# Install OpenCode CLI and make it globally accessible for the non-root user
# Try to fetch the latest version from GitHub API; fall back to a known-good
# version when the API is unavailable (e.g. rate-limited during Docker build).
RUN FALLBACK_VERSION="1.2.26" && \
    LATEST=$(curl -sf https://api.github.com/repos/anomalyco/opencode/releases/latest \
      | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' || true) && \
    VERSION="${LATEST:-$FALLBACK_VERSION}" && \
    echo "Installing OpenCode version: $VERSION" && \
    curl -fsSL https://opencode.ai/install | bash -s -- --version "$VERSION" && \
    BIN_PATH=$(find /root -name "opencode" -type f -executable | head -n 1) && \
    mv "$BIN_PATH" /usr/local/bin/opencode && \
    chmod +x /usr/local/bin/opencode

# Install uv (Python package runner)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    mv /root/.local/bin/uv /usr/local/bin/uv && \
    mv /root/.local/bin/uvx /usr/local/bin/uvx

# Install oh-my-opencode plugin globally
RUN npm install -g oh-my-opencode

# Install gosu for privilege dropping in the entrypoint
RUN curl -fsSL https://github.com/tianon/gosu/releases/download/1.17/gosu-$(dpkg --print-architecture) \
      -o /usr/local/bin/gosu && \
    chmod +x /usr/local/bin/gosu && \
    gosu nobody true

# Install Kotlin Language Server (official JetBrains standalone build).
# Bundles its own JVM — no separate JDK required.
#
# WORKAROUND (2026-04): OpenCode's LSP client fails the initialize handshake
# with the raw kotlin-lsp.sh launcher because:
#   1. The bundled JVM emits --add-opens warnings to stderr (com.apple.*,
#      sun.lwawt.*, etc.) that confuse the LSP client's stream reader.
#   2. kotlin-lsp.sh tries to chmod the JRE binary at runtime, which fails
#      as non-root and adds more noise to stderr.
#   3. JVM cold start benefits from tuned flags (-XX:TieredStopAtLevel=1,
#      -XX:+UseSerialGC, -Xverify:none) to reduce startup time.
# The fix is a thin wrapper at /usr/local/bin/kotlin-lsp that suppresses
# stderr (2>/dev/null) and sets JVM startup flags, then execs the real
# launcher. Both "kotlin-lsp" and "kotlin-ls" point to this wrapper.
#
# TODO: Periodically check if this workaround is still needed:
#   - OpenCode LSP client: https://github.com/anomalyco/opencode/issues/13328
#   - Kotlin LSP stderr:   https://github.com/Kotlin/kotlin-lsp/issues
#   If OpenCode fixes its stderr handling or JetBrains suppresses the JVM
#   warnings, the wrapper can be replaced with a direct symlink.
RUN KOTLIN_LSP_VERSION="262.2310.0" && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) KOTLIN_ARCH="x64" ;; \
      arm64) KOTLIN_ARCH="aarch64" ;; \
      *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    echo "Installing Kotlin LSP $KOTLIN_LSP_VERSION for $KOTLIN_ARCH" && \
    curl -fsSL "https://download-cdn.jetbrains.com/kotlin-lsp/${KOTLIN_LSP_VERSION}/kotlin-lsp-${KOTLIN_LSP_VERSION}-linux-${KOTLIN_ARCH}.zip" \
      -o /tmp/kotlin-lsp.zip && \
    unzip -q /tmp/kotlin-lsp.zip -d /opt/kotlin-lsp && \
    chmod +x /opt/kotlin-lsp/kotlin-lsp.sh /opt/kotlin-lsp/jre/bin/* && \
    sed -i 's|chmod +x "$LOCAL_JRE_PATH/bin/java"|# chmod not needed — set at build time|' /opt/kotlin-lsp/kotlin-lsp.sh && \
    printf '#!/bin/sh\nexport JAVA_OPTS="${JAVA_OPTS:--Xmx3g} -XX:+TieredCompilation -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -Xverify:none"\nexec /opt/kotlin-lsp/kotlin-lsp.sh --stdio 2>/dev/null\n' > /usr/local/bin/kotlin-lsp && \
    chmod +x /usr/local/bin/kotlin-lsp && \
    ln -s /usr/local/bin/kotlin-lsp /usr/local/bin/kotlin-ls && \
    rm /tmp/kotlin-lsp.zip

# Entrypoint script: runs as root, dynamically registers the target uid/gid in
# /etc/passwd and /etc/group (so tools like npm, bun, gh, and git can resolve
# the current user), then drops privileges back to that uid/gid before exec-ing
# opencode.  This is required when the container is started with a host uid
# that doesn't exist inside the image (e.g. -u 502:20 from a macOS host).
RUN printf '#!/bin/sh\nset -e\nTARGET_UID=${OPENCODE_UID:-$(id -u)}\nTARGET_GID=${OPENCODE_GID:-$(id -g)}\nHOME_DIR="${HOME:-/home/opencode_user}"\nif ! getent group "$TARGET_GID" > /dev/null 2>&1; then\n  echo "opencode_grp:x:${TARGET_GID}:" >> /etc/group\nfi\nif ! getent passwd "$TARGET_UID" > /dev/null 2>&1; then\n  echo "opencode_user:x:${TARGET_UID}:${TARGET_GID}:OpenCode User:${HOME_DIR}:/bin/sh" >> /etc/passwd\nfi\nexec gosu "${TARGET_UID}:${TARGET_GID}" opencode "$@"\n' > /usr/local/bin/opencode-entrypoint.sh && chmod +x /usr/local/bin/opencode-entrypoint.sh

# Set default workspace
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/opencode-entrypoint.sh"]
EOF

  if [ $? -ne 0 ]; then
    log_error "Failed to build the Docker image. See build output above for details."
    exit 1
  fi
  log_ok "Docker image '$IMAGE_NAME' built successfully"
else
  log_ok "Docker image '$IMAGE_NAME' already exists – skipping build"
fi

# ---------------------------------------------------------------------------
# Auth Sharing & OMO Injection
# ---------------------------------------------------------------------------
log_section "Environment Customization"

# Share host OpenCode auth if available to prevent "auth fatigue"
HOST_OC_CONFIG="$HOME/.config/opencode"
CONTAINER_OC_CONFIG="$CONFIG_DIR/.config/opencode"
mkdir -p "$CONTAINER_OC_CONFIG"

if [ -f "$HOST_OC_CONFIG/auth.json" ]; then
  cp "$HOST_OC_CONFIG/auth.json" "$CONTAINER_OC_CONFIG/auth.json"
  log_info "Copied auth.json from host to sandbox"
else
  log_debug "No host auth.json found at $HOST_OC_CONFIG"
fi

if [ "$WITH_OMO" = true ]; then
  log_info "Injecting oh-my-opencode configurations for Copilot"
  
      # Gracefully add the plugin without overwriting existing config
      if [ ! -f "$CONTAINER_OC_CONFIG/opencode.json" ]; then
        echo '{}' > "$CONTAINER_OC_CONFIG/opencode.json"
      fi
      TMP_JSON=$(mktemp)
      JQ_FILTER='.plugin = ((.plugin // []) + ["oh-my-opencode"] | unique) | del(.workspaces)'

      if command -v jq >/dev/null 2>&1; then
        log_debug "Using host jq for config merge"
        jq "$JQ_FILTER" "$CONTAINER_OC_CONFIG/opencode.json" > "$TMP_JSON" || true
      elif command -v python3 >/dev/null 2>&1; then
        log_debug "Using host python3 for config merge"
        python3 -c "import json, sys; d=json.load(open(sys.argv[1])) if open(sys.argv[1]).read().strip() else {}; d['plugin']=list(dict.fromkeys(d.get('plugin', [])+['oh-my-opencode'])); d.pop('workspaces', None); json.dump(d, open(sys.argv[2], 'w'))" "$CONTAINER_OC_CONFIG/opencode.json" "$TMP_JSON" || true
      else
        log_debug "Using dockerized jq for config merge"
        docker run --rm -i --entrypoint jq "$IMAGE_NAME" "$JQ_FILTER" < "$CONTAINER_OC_CONFIG/opencode.json" > "$TMP_JSON" || true
      fi

      if [ -s "$TMP_JSON" ] && [ "$(cat "$TMP_JSON")" != "null" ]; then
        mv "$TMP_JSON" "$CONTAINER_OC_CONFIG/opencode.json"
      else
        log_warn "Failed to merge opencode.json configuration safely, leaving as-is"
        rm -f "$TMP_JSON"
      fi

  # Create OMO config with explicitly allowed Copilot models
  cat > "$CONTAINER_OC_CONFIG/oh-my-openagent.jsonc" << 'EOF'
{
  "agents": {
    "sisyphus": { "model": "github-copilot/claude-opus-4.6" },
    "prometheus": { "model": "github-copilot/claude-opus-4.6" },
    "oracle": { "model": "github-copilot/claude-opus-4.6" },
    "explore": { "model": "github-copilot/claude-haiku-4.5" },
    "librarian": { "model": "github-copilot/claude-haiku-4.5" },
    "atlas": { "model": "github-copilot/claude-sonnet-4.6" },
    "multimodal-looker": { "model": "github-copilot/gemini-3.1-pro-preview" },
    "hephaestus": { "model": "github-copilot/claude-opus-4.6" }
  },
  "lsp": {
    "kotlin-ls": {
      "command": ["kotlin-lsp"],
      "extensions": [".kt", ".kts"],
      "env": {
        "JAVA_OPTS": "-Xmx3g -XX:+TieredCompilation -XX:TieredStopAtLevel=2 -XX:+UseG1GC"
      }
    }
  }
}
EOF
fi

# ---------------------------------------------------------------------------
# Docker run arguments
# ---------------------------------------------------------------------------
log_section "Assembling container configuration"

# Build the docker run command
# In web mode we omit --rm so that if the container crashes we can still
# read its logs with `docker logs`.  We remove it explicitly after a clean
# stop in the web-mode section below.
if [ "$WEB_MODE" = true ]; then
  DOCKER_RUN_MODE="-d"
  log_info "Run mode: detached (web server)"
else
  DOCKER_RUN_MODE="-it"
  log_info "Run mode: interactive TTY"
fi

DOCKER_ARGS=(
  $DOCKER_RUN_MODE
  -e HOME=/home/opencode_user
  -e "OPENCODE_UID=$(id -u)"
  -e "OPENCODE_GID=$(id -g)"
  -e "GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=no -i /home/opencode_user/.ssh/id_ed25519 -i /home/opencode_user/.ssh/id_rsa"
  # Workaround for OpenCode#13328: JVM-based LSPs (Kotlin) need more time for diagnostics
  -e "OPENCODE_EXPERIMENTAL_LSP_DIAGNOSTICS_TIMEOUT_MS=30000"
  -v "$PROJECT_PATH:/workspace"
  -v "$CONFIG_DIR:/home/opencode_user"
)
log_debug "Container user: $(id -u):$(id -g) (passed via OPENCODE_UID/OPENCODE_GID for entrypoint privilege drop)"
log_debug "Mount: $PROJECT_PATH -> /workspace"
log_debug "Mount: $CONFIG_DIR -> /home/opencode_user"
log_debug "Env: HOME=/home/opencode_user"
log_debug "Env: OPENCODE_UID=$(id -u), OPENCODE_GID=$(id -g)"

# Only mount .ssh if the directory exists
if [ -d "$HOME/.ssh" ]; then
  DOCKER_ARGS+=(-v "$HOME/.ssh:/home/opencode_user/.ssh:ro")
  log_info "Mount: ~/.ssh -> /home/opencode_user/.ssh (read-only)"
else
  log_warn "No ~/.ssh directory found – SSH keys will not be available in the container"
fi

# Only mount .gitconfig if the file exists on the host.
# Because CONFIG_DIR is itself bind-mounted as /home/opencode_user, Docker
# cannot always create a nested mountpoint for .gitconfig on the fly.  We
# work around this by ensuring a regular file exists at the target path
# *before* the container starts:
#   1. Remove any stale directory that Docker may have created on a previous
#      run (Docker creates missing bind-mount targets as directories).
#   2. Touch a placeholder file so the bind-mount has a valid mountpoint.
if [ -d "$CONFIG_DIR/.gitconfig" ]; then
  log_warn "Removing stale .gitconfig directory from config dir (leftover from previous run)"
  rm -rf "$CONFIG_DIR/.gitconfig"
fi

if [ -f "$HOME/.gitconfig" ]; then
  # Pre-create the mountpoint as a regular file inside the config dir so
  # Docker doesn't fail with an "outside of rootfs" error when the config
  # dir is itself a bind mount.
  if [ ! -f "$CONFIG_DIR/.gitconfig" ]; then
    log_debug "Pre-creating .gitconfig placeholder in config dir"
    touch "$CONFIG_DIR/.gitconfig"
  fi
  DOCKER_ARGS+=(-v "$HOME/.gitconfig:/home/opencode_user/.gitconfig:ro")
  log_info "Mount: ~/.gitconfig -> /home/opencode_user/.gitconfig (read-only)"
else
  log_debug "No ~/.gitconfig found – skipping mount"
fi

# Pass through custom environment variables (--env / --env-redact)
if [ ${#CUSTOM_ENVS[@]} -gt 0 ]; then
  log_info "Passing ${#CUSTOM_ENVS[@]} custom environment variable(s):"
  for env_pair in "${CUSTOM_ENVS[@]}"; do
    DOCKER_ARGS+=(-e "$env_pair")
    env_key="${env_pair%%=*}"
    if _is_redacted_key "$env_key" && [ "$EXPOSE_ENV" != true ]; then
      log_debug "  Env: $env_key=***REDACTED***"
    else
      log_debug "  Env: $env_pair"
    fi
  done
else
  log_debug "No custom environment variables"
fi

# Expose additional ports (--expose-port)
if [ ${#EXPOSE_PORTS[@]} -gt 0 ]; then
  log_info "Exposing ${#EXPOSE_PORTS[@]} additional port(s):"
  for port in "${EXPOSE_PORTS[@]}"; do
    DOCKER_ARGS+=(-p "${port}:${port}")
    log_info "  Port mapping: host ${port} -> container ${port}"
  done
else
  log_debug "No additional ports to expose"
fi

# Mount base config if present (merged with project config by OpenCode)
if [ -f "$BASE_CONFIG" ]; then
  DOCKER_ARGS+=(
    -v "$BASE_CONFIG:/etc/opencode/opencode.json:ro"
    -e "OPENCODE_CONFIG=/etc/opencode/opencode.json"
  )
  log_info "Mount: base config $BASE_CONFIG -> /etc/opencode/opencode.json (read-only)"
else
  log_debug "No base config file found at $BASE_CONFIG – skipping"
fi

if [ -d "$BASE_CONFIG_DIR" ]; then
  DOCKER_ARGS+=(
    -v "$BASE_CONFIG_DIR:/etc/opencode/config:ro"
    -e "OPENCODE_CONFIG_DIR=/etc/opencode/config"
  )
  log_info "Mount: base config dir $BASE_CONFIG_DIR -> /etc/opencode/config (read-only)"
else
  log_debug "No base config directory found at $BASE_CONFIG_DIR – skipping"
fi

# ---------------------------------------------------------------------------
# Web mode configuration
# ---------------------------------------------------------------------------
# Extra args for web mode
OPENCODE_CMD=()
if [ "$WEB_MODE" = true ]; then
  log_section "Web mode setup"

  # Web mode runs a server — use detached mode instead of interactive TTY
  DOCKER_ARGS+=(--name "opencode-web-${WEB_PORT}" -p "${WEB_PORT}:${WEB_PORT}")
  log_info "Container name: opencode-web-${WEB_PORT}"
  log_info "Port mapping: host ${WEB_PORT} -> container ${WEB_PORT}"

  if [ -n "$SERVER_PASSWORD" ]; then
    DOCKER_ARGS+=(-e "OPENCODE_SERVER_PASSWORD=${SERVER_PASSWORD}")
    REDACTED_KEYS+=("OPENCODE_SERVER_PASSWORD")
    log_info "Server authentication: enabled (password set)"
  else
    log_warn "Server authentication: DISABLED (no --server-password provided)"
  fi

  if [ -n "$SERVER_USERNAME" ]; then
    DOCKER_ARGS+=(-e "OPENCODE_SERVER_USERNAME=${SERVER_USERNAME}")
    log_debug "Server username: $SERVER_USERNAME"
  else
    log_debug "Server username: opencode (default)"
  fi

  OPENCODE_CMD=(web --port "$WEB_PORT" --hostname 0.0.0.0)
  log_debug "OpenCode command: ${OPENCODE_CMD[*]}"
fi

# ---------------------------------------------------------------------------
# Launch container
# ---------------------------------------------------------------------------
log_section "Starting container"

# Print startup info
if [ "$WEB_MODE" = true ]; then
  log_info "Launching OpenCode web interface for: $PROJECT_PATH"
else
  log_info "Launching OpenCode (interactive) for: $PROJECT_PATH"
fi

if [ "$EXPOSE_ENV" = true ]; then
  log_debug "Full docker args: docker run ${DOCKER_ARGS[*]} $IMAGE_NAME ${OPENCODE_CMD[*]}"
else
  log_debug "Full docker args: docker run $(_redact_docker_args "${DOCKER_ARGS[@]}") $IMAGE_NAME ${OPENCODE_CMD[*]}"
fi

# Run the container
if [ "$WEB_MODE" = true ]; then
  CONTAINER_NAME="opencode-web-${WEB_PORT}"
  # Remove any existing container with the same name (running or stopped)
  if docker ps -a -q -f "name=^${CONTAINER_NAME}$" | grep -q .; then
    log_warn "Removing existing container '$CONTAINER_NAME'..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    log_ok "Old container removed"
  fi

  log_info "Starting detached container..."
  # Note: --rm is intentionally omitted in web mode so we can read logs if
  # the container crashes immediately.  We clean it up manually below.
  CONTAINER_ID=$(docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${OPENCODE_CMD[@]}" 2>&1)
  RUN_EXIT=$?

  if [ $RUN_EXIT -ne 0 ]; then
    log_error "docker run failed (exit $RUN_EXIT)."
    log_error "Docker output: $CONTAINER_ID"
    exit 1
  fi

  log_ok "Container started: ${CONTAINER_ID:0:12}"

  # Wait for the server to become ready or detect a crash early (timeout: 15s)
  log_info "Waiting for web server to become ready (timeout: 15s)..."
  SERVER_READY=false
  for i in $(seq 1 30); do
    # First check if container is still running
    if ! docker ps -q -f "id=$CONTAINER_ID" | grep -q .; then
      log_error "Container exited unexpectedly. Crash logs:"
      echo "-----------------------------------------"
      docker logs "$CONTAINER_NAME" 2>&1 || docker logs "$CONTAINER_ID" 2>&1 || true
      echo "-----------------------------------------"
      log_error "Hint: fix the issue, then re-run the script (old container will be auto-removed)."
      exit 1
    fi
    LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
    if echo "$LOGS" | grep -qi "listening\|started\|ready\|serving"; then
      SERVER_READY=true
      log_ok "Server is ready (detected after ~$((i / 2))s)"
      break
    fi
    sleep 0.5
  done

  if [ "$SERVER_READY" = false ]; then
    log_warn "Server may not be ready yet – timed out waiting for startup message"
    log_warn "Check logs with: docker logs -f $CONTAINER_NAME"
  fi

  echo ""
  echo "========================================="
  echo "  OpenCode Web Server"
  echo "========================================="
  echo "  Container:  ${CONTAINER_ID:0:12}"
  echo ""
  echo "  Access URLs:"
  echo "    http://localhost:${WEB_PORT}"
  # Show all non-loopback IPv4 addresses
  for ip in $(hostname -I 2>/dev/null); do
    # Filter to IPv4 only (skip IPv6)
    if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "    http://${ip}:${WEB_PORT}"
    fi
  done
  echo ""
  if [ -n "$SERVER_PASSWORD" ]; then
    echo "  Username:   ${SERVER_USERNAME:-opencode}"
    if [ "$EXPOSE_ENV" = true ]; then
      echo "  Password:   ${SERVER_PASSWORD}"
    else
      echo "  Password:   ***REDACTED*** (use --expose-env to show)"
    fi
  else
    echo "  Auth:       NONE (unprotected)"
  fi
  echo "========================================="
  echo ""
  echo "  Server logs:"
  echo "-----------------------------------------"
  docker logs "$CONTAINER_NAME" 2>&1
  echo "-----------------------------------------"
  echo ""
  echo "  View logs:  docker logs -f $CONTAINER_NAME"
  echo "  Stop:       docker stop $CONTAINER_NAME"

  log_ok "Web mode startup complete"
else
  log_info "Handing off to interactive container..."
  # Use --rm for interactive mode so the container is cleaned up on exit
  docker run --rm "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${OPENCODE_CMD[@]}"
  EXIT_CODE=$?
  if [ $EXIT_CODE -ne 0 ]; then
    log_error "Container exited with code $EXIT_CODE"
    exit $EXIT_CODE
  fi
  log_ok "Container exited cleanly"
fi

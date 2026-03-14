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
# Defaults
# ---------------------------------------------------------------------------
REBUILD=false
WEB_MODE=false
WEB_PORT=3000
SERVER_PASSWORD=""
SERVER_USERNAME=""
CUSTOM_ENVS=()

USAGE="Usage: start-opencode [--rebuild] [--env KEY=VALUE]... [--web [--web-port <port>] [--server-password <password>] [--server-username <username>]] <path-to-project>"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
log_section "Parsing arguments"
log_debug "Raw arguments: $*"

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

# Set default workspace
WORKDIR /workspace
ENTRYPOINT ["opencode"]
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
# Docker run arguments
# ---------------------------------------------------------------------------
log_section "Assembling container configuration"

# Build the docker run command
if [ "$WEB_MODE" = true ]; then
  DOCKER_RUN_MODE="-d"
  log_info "Run mode: detached (web server)"
else
  DOCKER_RUN_MODE="-it"
  log_info "Run mode: interactive TTY"
fi

DOCKER_ARGS=(
  --rm $DOCKER_RUN_MODE
  -u "$(id -u):$(id -g)"
  -e HOME=/home/opencode_user
  -e "GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=no -i /home/opencode_user/.ssh/id_ed25519 -i /home/opencode_user/.ssh/id_rsa"
  -e "GH_TOKEN=${GH_TOKEN}"
  -v "$PROJECT_PATH:/workspace"
  -v "$CONFIG_DIR:/home/opencode_user"
)
log_debug "Container user: $(id -u):$(id -g)"
log_debug "Mount: $PROJECT_PATH -> /workspace"
log_debug "Mount: $CONFIG_DIR -> /home/opencode_user"
log_debug "Env: HOME=/home/opencode_user"
log_debug "Env: GH_TOKEN=$([ -n "${GH_TOKEN}" ] && echo '(set, value hidden)' || echo '(not set)')"

# Only mount .ssh if the directory exists
if [ -d "$HOME/.ssh" ]; then
  DOCKER_ARGS+=(-v "$HOME/.ssh:/home/opencode_user/.ssh:ro")
  log_info "Mount: ~/.ssh -> /home/opencode_user/.ssh (read-only)"
else
  log_warn "No ~/.ssh directory found – SSH keys will not be available in the container"
fi

# Only mount .gitconfig if the file exists on the host.
# Clean up stale .gitconfig directory in CONFIG_DIR that Docker may have
# created on a previous run (Docker creates missing bind-mount targets as
# directories, which then conflicts with file-to-file mounts).
if [ -d "$CONFIG_DIR/.gitconfig" ]; then
  log_warn "Removing stale .gitconfig directory from config dir (leftover from previous run)"
  rm -rf "$CONFIG_DIR/.gitconfig"
fi

if [ -f "$HOME/.gitconfig" ]; then
  DOCKER_ARGS+=(-v "$HOME/.gitconfig:/home/opencode_user/.gitconfig:ro")
  log_info "Mount: ~/.gitconfig -> /home/opencode_user/.gitconfig (read-only)"
else
  log_debug "No ~/.gitconfig found – skipping mount"
fi

# Pass through custom environment variables (--env KEY=VALUE)
if [ ${#CUSTOM_ENVS[@]} -gt 0 ]; then
  log_info "Passing ${#CUSTOM_ENVS[@]} custom environment variable(s):"
  for env_pair in "${CUSTOM_ENVS[@]}"; do
    DOCKER_ARGS+=(-e "$env_pair")
    # Show the key but hide the value for security
    env_key="${env_pair%%=*}"
    log_debug "  Env: $env_key=(value hidden)"
  done
else
  log_debug "No custom environment variables"
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

log_debug "Full docker args: docker run ${DOCKER_ARGS[*]} $IMAGE_NAME ${OPENCODE_CMD[*]}"

# Run the container
if [ "$WEB_MODE" = true ]; then
  CONTAINER_NAME="opencode-web-${WEB_PORT}"
  # Remove any existing container with the same name
  if docker ps -a -q -f "name=$CONTAINER_NAME" | grep -q .; then
    log_warn "Removing existing container '$CONTAINER_NAME'..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    log_ok "Old container removed"
  fi

  log_info "Starting detached container..."
  CONTAINER_ID=$(docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${OPENCODE_CMD[@]}" 2>&1)

  # Check if the container actually started
  if ! docker ps -q -f "name=$CONTAINER_NAME" | grep -q .; then
    log_error "Container failed to start."
    log_error "Docker output: $CONTAINER_ID"
    exit 1
  fi
  log_ok "Container started: ${CONTAINER_ID:0:12}"

  # Wait for the server to start and stream initial logs
  log_info "Waiting for web server to become ready (timeout: 15s)..."
  SERVER_READY=false
  for i in $(seq 1 30); do
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
    echo "  Password:   ${SERVER_PASSWORD}"
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
  docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${OPENCODE_CMD[@]}"
  EXIT_CODE=$?
  if [ $EXIT_CODE -ne 0 ]; then
    log_error "Container exited with code $EXIT_CODE"
    exit $EXIT_CODE
  fi
  log_ok "Container exited cleanly"
fi

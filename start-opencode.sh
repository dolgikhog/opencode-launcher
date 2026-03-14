#!/bin/bash

REBUILD=false
WEB_MODE=false
WEB_PORT=3000
SERVER_PASSWORD=""
SERVER_USERNAME=""
CUSTOM_ENVS=()

USAGE="Usage: start-opencode [--rebuild] [--env KEY=VALUE]... [--web [--web-port <port>] [--server-password <password>] [--server-username <username>]] <path-to-project>"

# Parse flags and positional arguments (order-independent)
PROJECT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      REBUILD=true
      shift
      ;;
    --env)
      CUSTOM_ENVS+=("$2")
      shift 2
      ;;
    --web)
      WEB_MODE=true
      shift
      ;;
    --web-port)
      WEB_PORT="$2"
      shift 2
      ;;
    --server-password)
      SERVER_PASSWORD="$2"
      shift 2
      ;;
    --server-username)
      SERVER_USERNAME="$2"
      shift 2
      ;;
    --*)
      echo "Unknown option: $1"
      echo "$USAGE"
      exit 1
      ;;
    *)
      PROJECT_ARG="$1"
      shift
      ;;
  esac
done

# Ensure a project path was provided
if [ -z "$PROJECT_ARG" ]; then
  echo "$USAGE"
  exit 1
fi

# Get the absolute path of the project
PROJECT_PATH=$(realpath "$PROJECT_ARG")

# Verify the directory exists
if [ ! -d "$PROJECT_PATH" ]; then
  echo "Error: Directory '$PROJECT_PATH' does not exist."
  exit 1
fi

IMAGE_NAME="opencode-sandbox"
# Each project gets its own isolated home directory (auth, sessions, cache, etc.)
# Derive a stable subdirectory from the project path: <basename>-<short-hash>
PROJECT_HASH=$(printf '%s' "$PROJECT_PATH" | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12)
PROJECT_NAME=$(basename "$PROJECT_PATH")
CONFIG_DIR="$HOME/.opencode_docker_config/${PROJECT_NAME}-${PROJECT_HASH}"
mkdir -p "$CONFIG_DIR"

# Resolve the directory where this script (and base config files) live
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_CONFIG="$SCRIPT_DIR/opencode.json"
BASE_CONFIG_DIR="$SCRIPT_DIR/config"

# If --rebuild was passed, force remove the existing image
if [ "$REBUILD" = true ] && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Removing existing Docker image '$IMAGE_NAME' for rebuild..."
  docker rmi -f "$IMAGE_NAME"
fi

# Build the Docker image if it hasn't been built yet
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Docker image '$IMAGE_NAME' not found. Building it now (this only happens once)..."
  
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
RUN curl -fsSL https://opencode.ai/install | bash && \
    BIN_PATH=$(find /root -name "opencode" -type f -executable | head -n 1) && \
    mv "$BIN_PATH" /usr/local/bin/opencode && \
    chmod +x /usr/local/bin/opencode

# Set default workspace
WORKDIR /workspace
ENTRYPOINT ["opencode"]
EOF

  if [ $? -ne 0 ]; then
    echo "Failed to build the Docker image."
    exit 1
  fi
fi

# Build the docker run command
if [ "$WEB_MODE" = true ]; then
  DOCKER_RUN_MODE="-d"
else
  DOCKER_RUN_MODE="-it"
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

# Only mount .ssh if the directory exists
if [ -d "$HOME/.ssh" ]; then
  DOCKER_ARGS+=(-v "$HOME/.ssh:/home/opencode_user/.ssh:ro")
fi

# Only mount .gitconfig if the file exists on the host.
# Clean up stale .gitconfig directory in CONFIG_DIR that Docker may have
# created on a previous run (Docker creates missing bind-mount targets as
# directories, which then conflicts with file-to-file mounts).
if [ -d "$CONFIG_DIR/.gitconfig" ]; then
  rm -rf "$CONFIG_DIR/.gitconfig"
fi

if [ -f "$HOME/.gitconfig" ]; then
  DOCKER_ARGS+=(-v "$HOME/.gitconfig:/home/opencode_user/.gitconfig:ro")
fi

# Pass through custom environment variables (--env KEY=VALUE)
for env_pair in "${CUSTOM_ENVS[@]}"; do
  DOCKER_ARGS+=(-e "$env_pair")
done

# Mount base config if present (merged with project config by OpenCode)
if [ -f "$BASE_CONFIG" ]; then
  DOCKER_ARGS+=(
    -v "$BASE_CONFIG:/etc/opencode/opencode.json:ro"
    -e "OPENCODE_CONFIG=/etc/opencode/opencode.json"
  )
fi

if [ -d "$BASE_CONFIG_DIR" ]; then
  DOCKER_ARGS+=(
    -v "$BASE_CONFIG_DIR:/etc/opencode/config:ro"
    -e "OPENCODE_CONFIG_DIR=/etc/opencode/config"
  )
fi

# Extra args for web mode
OPENCODE_CMD=()
if [ "$WEB_MODE" = true ]; then
  # Web mode runs a server — use detached mode instead of interactive TTY
  DOCKER_ARGS+=(--name "opencode-web-${WEB_PORT}" -p "${WEB_PORT}:${WEB_PORT}")

  if [ -n "$SERVER_PASSWORD" ]; then
    DOCKER_ARGS+=(-e "OPENCODE_SERVER_PASSWORD=${SERVER_PASSWORD}")
  fi

  if [ -n "$SERVER_USERNAME" ]; then
    DOCKER_ARGS+=(-e "OPENCODE_SERVER_USERNAME=${SERVER_USERNAME}")
  fi

  OPENCODE_CMD=(web --port "$WEB_PORT" --hostname 0.0.0.0)
fi

# Print startup info
if [ "$WEB_MODE" = true ]; then
  echo "Starting OpenCode web interface for: $PROJECT_PATH"
else
  echo "Starting OpenCode securely isolated in: $PROJECT_PATH"
fi

# Run the container
if [ "$WEB_MODE" = true ]; then
  CONTAINER_NAME="opencode-web-${WEB_PORT}"
  # Remove any existing container with the same name
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
  CONTAINER_ID=$(docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${OPENCODE_CMD[@]}" 2>&1)

  # Check if the container actually started
  if ! docker ps -q -f "name=$CONTAINER_NAME" | grep -q .; then
    echo ""
    echo "ERROR: Container failed to start."
    echo "$CONTAINER_ID"
    exit 1
  fi

  # Wait for the server to start and stream initial logs
  echo "Waiting for server to start..."
  for i in $(seq 1 30); do
    LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
    if echo "$LOGS" | grep -qi "listening\|started\|ready\|serving"; then
      break
    fi
    sleep 0.5
  done

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
else
  docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${OPENCODE_CMD[@]}"
fi

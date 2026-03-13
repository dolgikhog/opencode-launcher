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
# Directory on your host to securely persist OpenCode configuration and AI auth keys
CONFIG_DIR="$HOME/.opencode_docker_config"
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
DOCKER_ARGS=(
  --rm -it
  -u "$(id -u):$(id -g)"
  -e HOME=/home/opencode_user
  -e "GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=no -i /home/opencode_user/.ssh/id_ed25519 -i /home/opencode_user/.ssh/id_rsa"
  -e "GH_TOKEN=${GH_TOKEN}"
  -v "$PROJECT_PATH:/workspace"
  -v "$CONFIG_DIR:/home/opencode_user"
  -v "$HOME/.ssh:/home/opencode_user/.ssh:ro"
  -v "$HOME/.gitconfig:/home/opencode_user/.gitconfig:ro"
)

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
  DOCKER_ARGS+=(-p "${WEB_PORT}:${WEB_PORT}")

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
  echo "  URL: http://localhost:${WEB_PORT}"
  if [ -n "$SERVER_PASSWORD" ]; then
    echo "  Auth enabled (username: ${SERVER_USERNAME:-opencode})"
  else
    echo "  WARNING: No --server-password set. The web interface is unprotected."
  fi
else
  echo "Starting OpenCode securely isolated in: $PROJECT_PATH"
fi

# Run the container
docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${OPENCODE_CMD[@]}"

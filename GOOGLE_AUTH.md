# Google OAuth (Gemini Code Assist) in Docker

The [`opencode-gemini-auth`](https://github.com/jenslys/opencode-gemini-auth) plugin lets you authenticate with Google for Gemini Code Assist. This guide covers the Docker-specific setup. For full plugin documentation (available models, thinking config, troubleshooting, quotas), see the [plugin README](https://github.com/jenslys/opencode-gemini-auth#readme).

## Per-project setup

Add the plugin to your project's `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    "opencode-gemini-auth@latest"
  ]
}
```

If you have a paid Gemini Code Assist subscription (Standard/Enterprise), set a `projectId`. Free tier accounts auto-provision a managed project, but you can still set one explicitly. See the plugin README for [project ID configuration](https://github.com/jenslys/opencode-gemini-auth#google-cloud-project) and [available models](https://github.com/jenslys/opencode-gemini-auth#model-list).

## Enable headless mode

Inside Docker, the plugin's local OAuth callback server can't receive browser redirects (Docker Desktop for Mac runs containers in a Linux VM, so `localhost` inside the container isn't the host's `localhost`). Set the `OPENCODE_HEADLESS` environment variable to skip the local server and use a manual paste flow instead.

Pass it via the `--env` flag:

```bash
start-opencode --env "OPENCODE_HEADLESS=1" <path-to-project>
```

You can also pass other plugin env vars this way, e.g. the project ID:

```bash
start-opencode \
  --env "OPENCODE_HEADLESS=1" \
  --env "OPENCODE_GEMINI_PROJECT_ID=your-gcp-project-id" \
  <path-to-project>
```

## Authentication flow

1. Start OpenCode with `OPENCODE_HEADLESS=1` set (see above)
2. Run `/connect` and select **Google**
3. Choose **OAuth with Google (Gemini CLI)**
4. The plugin prints a Google OAuth URL — copy it and open it in your browser
5. Complete the Google sign-in
6. The browser redirects to `http://localhost:8085/oauth2callback?code=...&state=...` — this will fail with a connection error, which is expected
7. Copy the **full URL** from the browser address bar
8. Paste it back into OpenCode

The plugin exchanges the code for tokens and stores them in `~/.local/share/opencode/auth.json` (mapped to `~/.opencode_docker_config/.local/share/opencode/auth.json` on the host when using `start-opencode.sh`). Credentials persist across container restarts.

## Subsequent runs

Once authenticated, you don't need `OPENCODE_HEADLESS` anymore. The plugin reuses the stored refresh token. You only need it again if you re-authenticate (e.g., token revoked).

Keeping `--env "OPENCODE_HEADLESS=1"` permanently is harmless — it only affects the initial OAuth flow.

## Further reading

For models, thinking configuration, troubleshooting, quota details, and debugging, see the full plugin documentation:

- [Available models and thinking config](https://github.com/jenslys/opencode-gemini-auth#model-list)
- [Troubleshooting (manual GCP setup, 429 errors)](https://github.com/jenslys/opencode-gemini-auth#troubleshooting)
- [Debugging with `OPENCODE_GEMINI_DEBUG`](https://github.com/jenslys/opencode-gemini-auth#debugging)
- [Updating the plugin](https://github.com/jenslys/opencode-gemini-auth#updating)

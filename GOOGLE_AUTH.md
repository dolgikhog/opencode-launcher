# Google OAuth (Gemini Code Assist) in Docker

The `opencode-gemini-auth` plugin lets you authenticate with Google for Gemini Code Assist.
Because the Docker container can't receive OAuth redirects on `localhost`, you need to use the headless (manual paste) flow.

## Prerequisites

1. A Google Cloud project with the **Gemini for Google Cloud API** enabled.
   - Go to [Google Cloud Console](https://console.cloud.google.com/)
   - Create or select a project
   - Enable the **Gemini for Google Cloud API** (also called "Cloud Code Assist API")
   - Note your **project ID**

## Per-project setup

Add the following to your project's `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    "opencode-gemini-auth@latest"
  ],
  "provider": {
    "google": {
      "options": {
        "projectId": "your-gcp-project-id"
      }
    }
  }
}
```

Replace `your-gcp-project-id` with your actual Google Cloud project ID.

Alternatively, you can set the project ID via environment variable instead of config:

```bash
export OPENCODE_GEMINI_PROJECT_ID="your-gcp-project-id"
```

Or use `GOOGLE_CLOUD_PROJECT` / `GOOGLE_CLOUD_PROJECT_ID` (the plugin checks all three).

## Enable headless mode

Inside Docker, the plugin's local OAuth callback server can't receive browser redirects
(Docker Desktop for Mac runs containers in a Linux VM, so `localhost` inside the container
isn't the host's `localhost`). Set the `OPENCODE_HEADLESS` environment variable to skip the
local server and use a manual paste flow instead.

Pass it via the `--env` flag:

```bash
start-opencode --env "OPENCODE_HEADLESS=1" <path-to-project>
```

If you also want to set the project ID via environment variable (instead of `opencode.json`):

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

The plugin exchanges the code for tokens and stores them in `~/.local/share/opencode/auth.json`
(mapped to `~/.opencode_docker_config/.local/share/opencode/auth.json` on the host when using
`start-opencode.sh`). Credentials persist across container restarts.

## Subsequent runs

Once authenticated, you don't need `OPENCODE_HEADLESS` anymore. The plugin reuses the stored
refresh token. You only need it again if you re-authenticate (e.g., token revoked).

Keeping `--env "OPENCODE_HEADLESS=1"` permanently is harmless — it only affects the initial
OAuth flow.

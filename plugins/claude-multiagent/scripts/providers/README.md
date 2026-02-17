# Deploy Watch Provider Contract

Each provider is a script in this directory (`providers/`) that implements three commands.

## Commands

### `./provider.sh name`

Output the display name of the provider (e.g., "Render").

### `./provider.sh config`

Output JSON describing required configuration fields:

```json
{
  "fields": [
    {"key": "serviceId", "label": "Service ID", "required": true},
    {"key": "apiKeyEnv", "label": "API Key env var", "default": "RENDER_API_KEY"}
  ]
}
```

- `key`: the JSON key used in `.deploy-watch.json` under the provider section
- `label`: human-readable label shown during interactive config
- `required`: if true, the user must provide a value
- `default`: default value if the user leaves the field blank

### `./provider.sh list`

Output JSON lines (one JSON object per line), one per deploy, most recent first:

```json
{"commit":"abc1234","message":"Fix login bug","author":"user","build_status":"success","deploy_status":"live","build_started":"1739000000","deploy_finished":"1739000120","service_url":"https://app.onrender.com"}
```

#### Field reference

| Field            | Type   | Description                          |
|------------------|--------|--------------------------------------|
| `commit`         | string | Short commit hash                    |
| `message`        | string | Commit message (first line)          |
| `author`         | string | Author name or login                 |
| `build_status`   | string | Build status (see below)             |
| `deploy_status`  | string | Deploy status (see below)            |
| `build_started`  | string | Unix timestamp when build started    |
| `deploy_finished`| string | Unix timestamp when deploy completed |
| `service_url`    | string | Public URL of the service            |

#### Status values

- `pending` -- queued, not yet started
- `building` -- build in progress
- `deploying` -- deploy in progress
- `success` -- build succeeded
- `live` -- deploy is live and serving traffic
- `failed` -- build or deploy failed
- `cancelled` -- build or deploy was cancelled

## Environment variables

Provider scripts receive their config via environment variables. For each key in the provider's config section of `.deploy-watch.json`, the key is passed as `DEPLOY_WATCH_<KEY>` (uppercased). For example, if the config has `"serviceId": "srv-xxx"`, the provider receives `DEPLOY_WATCH_SERVICEID=srv-xxx`.

API keys are read from environment variables named in the config (e.g., `RENDER_API_KEY`). They are never stored in `.deploy-watch.json`.

## Writing a custom provider

1. Create a script in this directory (e.g., `my-provider.sh`)
2. Make it executable: `chmod +x my-provider.sh`
3. Implement all three commands: `name`, `config`, `list`
4. Configure via `watch-deploys.py` (press `p`) or manually edit `.deploy-watch.json`

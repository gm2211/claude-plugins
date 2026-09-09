# Local runtime

From the plugin directory:

```sh
docker compose -f runtime/compose.yaml up -d --build
```

Editor: http://127.0.0.1:3100 . MCP Streamable HTTP: http://127.0.0.1:3100/mcp . Health: `/health`.
The plugin's `.mcp.json` registers that endpoint in compatible plugin hosts. A host may need a reload before newly installed MCP tools become available. For other agents register that URL with their HTTP MCP client.

One application container serves three distinct components:

- `/`: the **full upstream Excalidraw application**, cloned from `https://github.com/excalidraw/excalidraw.git` at `EXCALIDRAW_REF` and built with `yarn build:app:docker`. Its build output is copied into `/app/excalidraw-web` and served by `server.mjs`. The application executes in the browser, as in upstream's Nginx Docker deployment.
- `/mcp`: the official `excalidraw/excalidraw-mcp` server, pinned separately at `MCP_REF`.
- `/bridge/`: our explicitly labeled checkpoint utility, built from the Excalidraw React package. It handles MCP checkpoint loading, normalization, saves, and native exports; it is not the upstream application.

Both source revisions are pinned in `runtime/Dockerfile`; each uses its own frozen lockfile. The clone versus npm-package choice is an implementation detail. The requirement is local diagram generation with no diagram uploads to external services.

## Local-only boundary

- The application container attaches only to an **internal Docker network**, with no internet route. A small Nginx ingress container publishes `127.0.0.1:3100` and forwards only to the application. Excalidraw and MCP remain in the same application container.
- Both browser applications receive a Content Security Policy restricting connections to the local origin. Scripts, styles, fonts and images are served locally or embedded. Public sharing, cloud collaboration, AI backends and remote library fetches cannot send scene data through this deployment.
- The MCP server's `export_to_excalidraw` upload implementation is removed. Calling it returns an explicit local-only error. This protects clients that call tools directly rather than using the browser.
- The MCP App widget is bundled locally, including its CSS and fonts; it no longer imports scripts from esm.sh. Its resource policy permits only the local server. Its fallback local font origin is fixed to `http://127.0.0.1:3100`; changing that address requires updating `localize-mcp.mjs` and rebuilding.
- Upstream service-worker registration is removed so it cannot intercept `/bridge/` routes. If upgrading a browser profile that visited an earlier experimental full-app build, clear that origin's old service worker before testing. Saved checkpoint files remain in the Docker volume.

Builds still fetch source code and dependencies from GitHub and package registries. Runtime editing, rendering and file exports stay local. These controls govern the Excalidraw deployment; they do not make the AI agent or its model provider local.
## Agent-to-application handoff

1. Create a checkpoint via MCP, then open `/bridge/?scene=ID`.
2. Click **Open in Excalidraw**. The bridge normalizes and saves the scene, then uses upstream's supported `#url=` import with the same-origin `/api/scenes/ID/export` endpoint.
3. Edit in the full upstream application. Its autosave is browser-local, not a write to the MCP checkpoint volume.
4. To return those edits to agents, export a `.excalidraw` file from the upstream app, open it through the bridge's Excalidraw menu, then click the bridge's **Save**.

Keep existing diagrams when the upstream application asks whether to replace a nonempty canvas. This is explicit import/export, not automatic synchronization.

The server binds only to host loopback through Compose. A named volume preserves scenes across container restarts. Do not use `down -v` unless intentionally deleting saved diagrams. The local scene API has no authentication; do not expose its port publicly.

- `GET /api/scenes`: checkpoint names.
- `GET /api/scenes/ID`: scene/checkpoint JSON.
- `PUT /api/scenes/ID`: `{elements: [...], appState: {...}, files: {...}}`, up to 5 MB.
- `/bridge/?scene=ID`: load the shared checkpoint in the bridge. Legacy `/?scene=ID` URLs redirect here.
- `GET /api/scenes/ID/export`: scene with the native Excalidraw file envelope.
- Save persists browser changes; Reload fetches agent changes. Concurrent writers should coordinate; last save wins.

Use `scripts/scene.py put NAME source.excalidraw`, `get NAME output.excalidraw`, or `mcp TOOL arguments.json` when an MCP tool is not callable in the current session. Pass `--url` before the subcommand to override the default origin. PNG and SVG come from the editor's export buttons, not an approximate renderer.

Upstream references: https://github.com/excalidraw/excalidraw and https://github.com/excalidraw/excalidraw-mcp . Both source repositories are pinned in `runtime/Dockerfile`; update intentionally and rebuild/smoke-test. Upstream's public-upload implementation is deliberately removed by `localize-mcp.mjs`.

## Verification

After starting the container, run `node runtime/smoke.mjs` from the plugin directory.
It tests MCP initialization, tool discovery, read_me, create_view, shared checkpoint
retrieval, editor saves, native scene export, the full upstream app, bridge routing, and invalid inputs. It leaves one small smoke checkpoint.
For a visual check, open the Grove example and export PNG/SVG/Excalidraw. The example
was rendered and inspected through the bundled editor, and its saved elements were
verified unchanged after a container restart. `examples/grove.py` regenerates the
layout input; export it through the editor to obtain fully normalized scene data.


With Playwright and Chromium installed, run `node runtime/browser-smoke.cjs` from
the plugin directory. It verifies bridge-to-upstream import, browser persistence,
return navigation, zero external browser requests, and a CSP-blocked external POST.
`runtime/smoke.mjs` also verifies the public-upload tool is disabled and the MCP
resource bundles its dependencies. The internal runtime network can be checked
with `docker network inspect runtime_local-only` (Compose project names may vary).

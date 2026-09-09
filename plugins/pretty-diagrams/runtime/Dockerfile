# Build the full upstream application, not only the React component package.
FROM node:24-bookworm-slim AS excalidraw-app
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
ARG EXCALIDRAW_REF=854d00c31b7105290396fe34294fc2a0331ea469
WORKDIR /excalidraw
RUN git init && git remote add origin https://github.com/excalidraw/excalidraw.git && git fetch --depth 1 origin ${EXCALIDRAW_REF} && git checkout FETCH_HEAD
RUN yarn install --frozen-lockfile --network-timeout 600000
COPY localize-app.mjs /excalidraw/localize-app.mjs
RUN node localize-app.mjs && yarn build:app:docker

FROM node:22-bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN corepack enable && corepack prepare pnpm@10.11.0 --activate
ARG MCP_REF=157aa23ceb1976008aadc89eb05e3444060f09d6
WORKDIR /app
RUN git init && git remote add origin https://github.com/excalidraw/excalidraw-mcp.git && git fetch --depth 1 origin ${MCP_REF} && git checkout FETCH_HEAD
RUN pnpm install --frozen-lockfile
COPY localize-mcp.mjs /app/localize-mcp.mjs
RUN node localize-mcp.mjs && pnpm run build
COPY editor /app/editor
RUN pnpm exec vite build --config editor/vite.config.mjs
RUN mkdir -p web/fonts && cp -r node_modules/@excalidraw/excalidraw/dist/prod/fonts/* web/fonts/
COPY server.mjs /app/server.mjs
FROM node:22-bookworm-slim
WORKDIR /app
COPY --from=build /app /app
COPY --from=excalidraw-app /excalidraw/excalidraw-app/build /app/excalidraw-web
ENV PORT=3100
RUN mkdir -p /tmp/excalidraw-mcp-checkpoints && chown -R node:node /tmp/excalidraw-mcp-checkpoints
USER node
EXPOSE 3100
CMD ["node", "server.mjs"]

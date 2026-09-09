import fs from 'node:fs';
const serverPath = 'src/server.ts';
let server = fs.readFileSync(serverPath, 'utf8');
const start = server.indexOf('    async ({ json }): Promise<CallToolResult> => {');
const end = server.indexOf('\n  // Tool 4: save_checkpoint', start);
if (start < 0 || end < 0) throw new Error('Upstream export tool changed; review local-only patch');
const tail = server.lastIndexOf('\n  // ============================================================', end);
server = server.slice(0, start) + `    async (): Promise<CallToolResult> => ({
      isError: true,
      content: [{ type: "text", text: "Public uploads are disabled in this local-only deployment. Export a local file from the checkpoint bridge." }],
    }),
  );
` + server.slice(tail);
server = server.replace('Upload diagram to excalidraw.com and return shareable URL.', 'Public uploads are disabled; use local file export.');
server = server.replaceAll('https://esm.sh', 'http://127.0.0.1:3100');
server = server.replace('import { deflateSync } from "node:zlib";\n', '');
fs.writeFileSync(serverPath, server);
let html = fs.readFileSync('src/mcp-app.html', 'utf8');
html = html.replace(/<script type="importmap">[\s\S]*?<\/script>/, '<script>window.EXCALIDRAW_ASSET_PATH="http://127.0.0.1:3100/bridge/";</script>');
fs.writeFileSync('src/mcp-app.html', html);
let css = fs.readFileSync('src/global.css', 'utf8');
css = css.replace(/@import url\("https:\/\/esm.sh\/[^\"]+index.css"\);/, '@import "@excalidraw/excalidraw/index.css";');
css = css.replaceAll('https://esm.sh/@excalidraw/excalidraw@0.18.0/dist/prod/fonts/', '../node_modules/@excalidraw/excalidraw/dist/prod/fonts/');
fs.writeFileSync('src/global.css', css);
fs.writeFileSync('vite.config.ts', `import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';
import {viteSingleFile} from 'vite-plugin-singlefile';
export default defineConfig({plugins:[react(),viteSingleFile()],build:{assetsInlineLimit:100000000,rollupOptions:{input:'src/mcp-app.html'},outDir:'dist',emptyOutDir:false}});
`);

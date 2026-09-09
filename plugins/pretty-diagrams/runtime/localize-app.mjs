import fs from 'node:fs';
// A root-scoped upstream service worker would capture /bridge/ navigation.
// Use ordinary local static serving for both applications on this origin.
const file = 'excalidraw-app/index.tsx';
const source = fs.readFileSync(file, 'utf8');
if (!source.includes('registerSW();')) throw new Error('Upstream service worker entry changed');
fs.writeFileSync(file, source.replace('import { registerSW } from "virtual:pwa-register";', '').replace('registerSW();', ''));
const configFile = 'excalidraw-app/vite.config.mts';
const config = fs.readFileSync(configFile, 'utf8');
if (!config.includes('registerType: "autoUpdate",')) throw new Error('Upstream PWA config changed');
fs.writeFileSync(configFile, config.replace('registerType: "autoUpdate",', 'injectRegister: false,\n        registerType: "autoUpdate",'));

import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({root:'editor',base:'/bridge/',plugins:[react()],build:{outDir:'../web',emptyOutDir:true}});

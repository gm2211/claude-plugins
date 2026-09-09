import express from 'express';
import fs from 'node:fs/promises';
import path from 'node:path';
import {createServer} from './dist/server.js';
import {StreamableHTTPServerTransport} from '@modelcontextprotocol/sdk/server/streamableHttp.js';
const dir='/tmp/excalidraw-mcp-checkpoints';
await fs.mkdir(dir,{recursive:true});
const valid=id=>/^[a-zA-Z0-9_-]{1,64}$/.test(id);
const store={
  async save(id,data){if(!valid(id))throw Error('Invalid checkpoint id');await fs.writeFile(path.join(dir,id+'.json'),JSON.stringify(data));},
  async load(id){if(!valid(id))throw Error('Invalid checkpoint id');try{return JSON.parse(await fs.readFile(path.join(dir,id+'.json'),'utf8'));}catch(e){if(e.code==='ENOENT')return null;throw e;}}
};
const app=express();
// Enforce local rendering and uploads in both browser applications. Build-time
// downloads are separate; the runtime Docker network also has no internet route.
app.use((req,res,next)=>{
 res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; worker-src 'self' blob:; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'self'");
 res.setHeader('Referrer-Policy','no-referrer');
 // The local MCP App sandbox has an opaque origin and may request local fonts.
 if(req.path.startsWith('/bridge/fonts/')) res.setHeader('Access-Control-Allow-Origin','*');
 next();
});
app.use(express.json({limit:'5mb'}));
app.get('/health',(_,res)=>res.json({ok:true}));
app.all('/mcp',async(req,res)=>{
 const server=createServer(store), transport=new StreamableHTTPServerTransport({sessionIdGenerator:undefined});
 res.on('close',()=>{transport.close().catch(()=>{});server.close().catch(()=>{});});
 try{await server.connect(transport);await transport.handleRequest(req,res,req.body);}catch(e){console.error(e);if(!res.headersSent)res.status(500).json({error:'MCP request failed'});}
});
app.get('/api/scenes',async(_,res)=>res.json((await fs.readdir(dir)).filter(x=>x.endsWith('.json')).map(x=>x.slice(0,-5))));
app.get('/api/scenes/:id',async(req,res)=>{
 if(!valid(req.params.id))return res.status(400).json({error:'Invalid id'});
 const scene=await store.load(req.params.id);if(!scene)return res.sendStatus(404);res.json(scene);
});
app.put('/api/scenes/:id',async(req,res)=>{
 if(!valid(req.params.id)||!Array.isArray(req.body.elements))return res.status(400).json({error:'Expected safe id and elements array'});
 await store.save(req.params.id,{elements:req.body.elements,appState:req.body.appState??{},files:req.body.files??{}});res.json({id:req.params.id});
});
// Full upstream Excalidraw is the default application. The MCP checkpoint
// bridge is a separate, explicit utility, not a replacement for that app.
app.get('/api/scenes/:id/export',async(req,res)=>{
 if(!valid(req.params.id))return res.status(400).json({error:'Invalid id'});
 const scene=await store.load(req.params.id);if(!scene)return res.sendStatus(404);
 res.type('application/json').json({type:'excalidraw',version:2,source:'local-mcp',...scene});
});
// Keep previously shared checkpoint URLs working after moving the bridge.
app.get('/',(req,res,next)=>{
 if(typeof req.query.scene==='string')return res.redirect('/bridge/?scene='+encodeURIComponent(req.query.scene));
 next();
});
app.use('/bridge',express.static('web'));
app.use(express.static('excalidraw-web'));
app.use((err,req,res,next)=>{console.error(err);res.status(err.status??500).json({error:'Request failed'});});
const server=app.listen(Number(process.env.PORT??3100),'0.0.0.0');
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>server.close(()=>process.exit(0)));

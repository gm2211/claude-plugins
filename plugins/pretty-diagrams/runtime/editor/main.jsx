import React,{useEffect,useState} from 'react';
import{createRoot}from'react-dom/client';
import{Excalidraw,convertToExcalidrawElements,exportToBlob,exportToSvg,serializeAsJSON}from'@excalidraw/excalidraw';
import '@excalidraw/excalidraw/index.css';
function App(){
 const[api,setApi]=useState(null),[ids,setIds]=useState([]),[status,setStatus]=useState(''),[id,setId]=useState(new URLSearchParams(location.search).get('scene')||'untitled');
 async function load(key=id){const r=await fetch('/api/scenes/'+encodeURIComponent(key));if(!r.ok)throw Error('Cannot load scene');const s=await r.json();const els=s.elements.filter(e=>!['cameraUpdate','restoreCheckpoint','delete'].includes(e.type));api.updateScene({elements:convertToExcalidrawElements(els),appState:{...s.appState,viewBackgroundColor:s.appState?.viewBackgroundColor||'#fffdf7'}});if(s.files)api.addFiles(Object.values(s.files));setTimeout(()=>api.scrollToContent(),100);setStatus('Loaded '+key);}
 async function save(){const r=await fetch('/api/scenes/'+encodeURIComponent(id),{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({elements:api.getSceneElements(),appState:{viewBackgroundColor:api.getAppState().viewBackgroundColor},files:api.getFiles()})});if(!r.ok)throw Error('Save failed');setStatus('Saved '+id);refresh();}
 function refresh(){fetch('/api/scenes').then(r=>r.json()).then(setIds).catch(e=>setStatus(e.message));}
 async function download(type){let blob;if(type==='excalidraw')blob=new Blob([serializeAsJSON(api.getSceneElements(),api.getAppState(),api.getFiles(),'local')],{type:'application/json'});else{const opts={elements:api.getSceneElements(),appState:{...api.getAppState(),exportBackground:true,exportWithDarkMode:false},files:api.getFiles(),exportPadding:40};blob=type==='png'?await exportToBlob({...opts,mimeType:'image/png'}):new Blob([(await exportToSvg(opts)).outerHTML],{type:'image/svg+xml'});}const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=id+'.'+type;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);}
 const run=fn=>()=>fn().catch(e=>setStatus(e.message));
 useEffect(()=>{refresh();},[]);
 useEffect(()=>{if(api&&new URLSearchParams(location.search).has('scene'))load().catch(e=>setStatus(e.message));},[api]);
 // Local automation surface: the same native Excalidraw exports used by the buttons.
 useEffect(()=>{window.diagram={load,save,download,api,exportToBlob,exportToSvg};},[api,id]);
 return <><header style={{height:52,display:'flex',alignItems:'center',gap:12,padding:'0 18px',font:'14px system-ui',background:'#fffdf7',borderBottom:'1px solid #ddd'}}><b>MCP checkpoint bridge</b><input aria-label="Scene name" value={id} onChange={e=>setId(e.target.value)}/><select aria-label="Saved scenes" value="" onChange={e=>{setId(e.target.value);load(e.target.value).catch(e=>setStatus(e.message));}}><option value="">Saved scenes</option>{ids.map(x=><option key={x}>{x}</option>)}</select><button onClick={run(()=>load())}>Reload</button><button onClick={run(save)}>Save</button><button onClick={run(async()=>{await save();location.href='/#url='+encodeURIComponent(location.origin+'/api/scenes/'+encodeURIComponent(id)+'/export');})}>Open in Excalidraw</button>{['excalidraw','svg','png'].map(t=><button key={t} onClick={run(()=>download(t))}>{t.toUpperCase()}</button>)}<span role="status">{status}</span></header><div style={{height:'calc(100vh - 53px)'}}><Excalidraw excalidrawAPI={setApi} initialData={{appState:{viewBackgroundColor:'#fffdf7'}}}/></div></>;
}
createRoot(document.getElementById('root')).render(<App/>);

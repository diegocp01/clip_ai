import http from 'node:http';
import { randomBytes,timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { authStatus,generate,MODEL,REASONING_EFFORT } from './codex.mjs';
import { normalizeRequest } from './schema.mjs';
import { editText,normalizeEditRequest } from './edit.mjs';

const root=fileURLToPath(new URL('../',import.meta.url));
const MAX_BODY=8*1024*1024;
const mime={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml','.png':'image/png'};
export function createServer({run=generate,runEdit=editText,checkAuth=authStatus}={}){
  const token=randomBytes(32).toString('hex');
  let active=0;
  const server=http.createServer(async(req,res)=>{
    const port=server.address().port;
    const hosts=new Set([`127.0.0.1:${port}`,`localhost:${port}`]);
    const origin=req.headers.origin;
    res.setHeader('X-Content-Type-Options','nosniff');
    res.setHeader('Cache-Control','no-store');
    res.setHeader('Referrer-Policy','no-referrer');
    res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; media-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'");
    const json=(status,data)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(data));};
    if(!hosts.has(req.headers.host)|| (origin&&!hosts.has(origin.replace(/^http:\/\//,''))))return json(403,{error:'Local access only.'});
    let pathname;try{pathname=decodeURIComponent(new URL(req.url,`http://127.0.0.1:${port}`).pathname);}catch{return json(400,{error:'Invalid path.'});}
    if(req.method==='GET'&&pathname==='/api/session')return json(200,{token});
    if(req.method==='GET'&&pathname==='/api/status')return json(200,{model:MODEL,reasoningEffort:REASONING_EFFORT,defaultTier:'fast',authenticated:await checkAuth(),auth:'ChatGPT',tiers:['standard','fast'],note:'Uses your Codex allowance. Fast mode requires account access and consumes more usage.'});
    if(req.method==='POST'&&['/api/chat','/api/edit'].includes(pathname)){
      const editing=pathname==='/api/edit';
      const supplied=Buffer.from(String(req.headers['x-clippy-session']||''));
      if(supplied.length!==token.length||!timingSafeEqual(supplied,Buffer.from(token)))return json(403,{error:'Reload the app to refresh your local session.'});
      if(!req.headers['content-type']?.startsWith('application/json'))return json(415,{error:'Expected application/json.'});
      if(active>=2)return json(429,{error:'Two requests are already running. Wait or cancel one.'});
      let request;
      try{
        let size=0;const chunks=[];
        for await(const chunk of req){size+=chunk.length;if(size>MAX_BODY){json(413,{error:'Image/request too large (8 MB limit).'});return;}chunks.push(chunk);}
        request=(editing?normalizeEditRequest:normalizeRequest)(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      }catch(e){if(!res.writableEnded)json(400,{error:e.message});return;}
      if(!await checkAuth())return json(401,{error:'Sign in to Codex with ChatGPT first: run codex login in Terminal.'});
      if(active>=2)return json(429,{error:'Two requests are already running.'});
      active++;
      const controller=new AbortController();
      const timer=setTimeout(()=>controller.abort(new Error('The request timed out after 120 seconds. Try a simpler question.')),120000);
      const disconnect=()=>{if(!res.writableEnded)controller.abort();};
      res.on('close',disconnect);
      res.writeHead(200,{'Content-Type':'application/x-ndjson; charset=utf-8','X-Accel-Buffering':'no'});
      const send=event=>{if(!res.destroyed&&!res.writableEnded)res.write(JSON.stringify(event)+'\n');};
      try{const output=await (editing?runEdit:run)(request,{signal:controller.signal,onStatus:message=>send({type:'status',message})});send({type:'result',...output});}
      catch(e){send({type:'error',message:controller.signal.aborted?(controller.signal.reason?.message||'Request cancelled.') : String(e.message||e).slice(0,1600)});}
      finally{clearTimeout(timer);res.off('close',disconnect);active--;res.end();}
      return;
    }
    if(req.method!=='GET')return json(405,{error:'Method not allowed.'});
    if(pathname.startsWith('/api/'))return json(404,{error:'Not found.'});
    const base=pathname.startsWith('/vendor/three/')?path.join(root,'node_modules/three'):path.join(root,'public');
    const relative=pathname.startsWith('/vendor/three/')?pathname.slice('/vendor/three/'.length):pathname==='/'?'index.html':pathname.slice(1);
    const file=path.resolve(base,relative);
    if(!file.startsWith(base+path.sep)||relative.split('/').some(p=>p.startsWith('.')))return json(403,{error:'Invalid path.'});
    try{const body=await readFile(file);res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream'});res.end(body);}
    catch{return json(404,{error:'Not found.'});}
  });
  server.requestTimeout=150000;
  return server;
}
if(process.argv[1]===fileURLToPath(import.meta.url)){
  const port=Number(process.env.CLIPPY_PORT||4317);
  const server=createServer();
  server.on('error',error=>{console.error(error.code==='EADDRINUSE'?`Port ${port} is in use. Set CLIPPY_PORT to another port.`:error.message);process.exitCode=1;});
  server.listen(port,'127.0.0.1',()=>console.log(`Clippy is ready at http://127.0.0.1:${port}`));
}

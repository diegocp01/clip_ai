import http from 'node:http';
import { choosePresentation } from './presentation.mjs';
import { createSignalDirector,SIGNAL_STATES } from './signal-pattern.mjs';
import { chooseChatRoute,validateAutoRoute } from './chat-settings.mjs';
import { chooseLoadingStatus,runWithLoadingStatus } from './decisions.mjs';
import { randomBytes,timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { authStatus,generate,MODEL,REASONING_EFFORT } from './codex.mjs';
import { claudeAuthStatus,generateWithClaude,CLAUDE_EFFORT,CLAUDE_MODEL } from './claude.mjs';
import { normalizeRequest } from './schema.mjs';
import { editText,normalizeEditRequest } from './edit.mjs';
import { RealtimeService,VOICE_MODEL } from './realtime.mjs';

const root=fileURLToPath(new URL('../',import.meta.url));
const MAX_BODY=8*1024*1024;
const mime={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml','.png':'image/png'};
export function createServer({run=generate,runClaude=generateWithClaude,runEdit=editText,checkAuth=authStatus,checkClaude=claudeAuthStatus,voice=new RealtimeService(),chooseStatus=chooseLoadingStatus,routeChat=chooseChatRoute,routePresentation=choosePresentation,directSignal=createSignalDirector()}={}){
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
    let pathname,query;try{const url=new URL(req.url,`http://127.0.0.1:${port}`);pathname=decodeURIComponent(url.pathname);query=url.searchParams;}catch{return json(400,{error:'Invalid path.'});}
    if(req.method==='GET'&&pathname==='/api/session')return json(200,{token});
    if(req.method==='POST'&&pathname==='/api/signal'){
      const supplied=Buffer.from(String(req.headers['x-clippy-session']||''));
      if(supplied.length!==token.length||!timingSafeEqual(supplied,Buffer.from(token)))return json(403,{error:'Refresh your local session.'});
      if(!req.headers['content-type']?.startsWith('application/json'))return json(415,{error:'Expected application/json.'});
      try {
        let size=0;const chunks=[];
        for await(const chunk of req){size+=chunk.length;if(size>128)return json(413,{error:'Signal request too large.'});chunks.push(chunk);}
        const body=JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if(!body || Object.keys(body).length!==1 || !SIGNAL_STATES.includes(body.state))return json(400,{error:'Only a valid signal state is accepted.'});
        const result=await directSignal(body.state);
        if(!res.destroyed)return json(200,result);
      } catch { if(!res.destroyed)return json(400,{error:'Invalid signal request.'}); }
      return;
    }
    if(req.method==='GET'&&pathname==='/api/realtime/status')return json(200,{configured:await voice.ready().catch(()=>false),model:VOICE_MODEL});
    if(req.method==='POST'&&['/api/realtime/call','/api/realtime/stop'].includes(pathname)){
      const supplied=Buffer.from(String(req.headers['x-clippy-session']||''));
      if(supplied.length!==token.length||!timingSafeEqual(supplied,Buffer.from(token)))return json(403,{error:'Refresh your local session.'});
      if(!req.headers['content-type']?.startsWith('application/json'))return json(415,{error:'Expected application/json.'});
      const controller=new AbortController();
      const timeout=setTimeout(()=>controller.abort(),25000);
      const disconnect=()=>{if(!res.writableEnded)controller.abort();};res.on('close',disconnect);
      try{
        let size=0;const chunks=[];
        for await(const chunk of req){size+=chunk.length;if(size>120000)throw new Error('Voice request too large.');chunks.push(chunk);}
        const body=JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if(!body||Array.isArray(body)||typeof body!=='object')throw new Error('Invalid voice request.');
        if(pathname.endsWith('/stop')){
          if(Object.keys(body).length!==1||typeof body.id!=='string'||body.id.length>100)throw new Error('Invalid voice session.');
          await voice.close(body.id);return json(200,{stopped:true});
        }
        if(Object.keys(body).length!==1||!('sdp' in body))throw new Error('Only an SDP offer is accepted.');
        const result=await voice.create(body.sdp,controller.signal);
        if(controller.signal.aborted){await voice.close(result.id);return;}
        return json(200,result);
      }catch(error){if(!res.destroyed)json(400,{error:String(error.message).slice(0,300)});}
      finally{clearTimeout(timeout);res.off('close',disconnect);}
      return;
    }
    if(req.method==='GET'&&pathname==='/api/status'&&query.get('provider')==='auto'){const signedIn=await Promise.all([checkAuth(),checkClaude()]);return json(200,{provider:'auto',model:'auto',authenticated:signedIn.some(Boolean)});}
    if(req.method==='GET'&&pathname==='/api/status'&&query.get('provider')==='claude')return json(200,{provider:'claude',model:CLAUDE_MODEL,reasoningEffort:CLAUDE_EFFORT,authenticated:await checkClaude(),auth:'Claude',note:'Uses your Claude plan through the Claude CLI.'});
    if(req.method==='GET'&&pathname==='/api/status')return json(200,{provider:'gpt',model:MODEL,reasoningEffort:REASONING_EFFORT,defaultTier:'fast',authenticated:await checkAuth(),auth:'ChatGPT',tiers:['standard','fast'],note:'Uses your Codex allowance. Fast mode requires account access and consumes more usage.'});
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
      const automaticPresentation=!editing&&request.mode==='auto';
      let auto=!editing&&request.mode==='chat'&&request.model==='auto';
      let claude=request.provider==='claude';
      if(!auto&&!automaticPresentation&&(claude?!await checkClaude():!await checkAuth()))return json(401,{error:claude?'Sign in to Claude first: run claude auth login in Terminal.':'Sign in to Codex with ChatGPT first: run codex login in Terminal.'});
      if(active>=2)return json(429,{error:'Two requests are already running.'});
      active++;
      const controller=new AbortController();
      const timer=setTimeout(()=>controller.abort(new Error('The request timed out after 120 seconds. Try a simpler question.')),120000);
      const disconnect=()=>{if(!res.writableEnded)controller.abort();};
      res.on('close',disconnect);
      res.writeHead(200,{'Content-Type':'application/x-ndjson; charset=utf-8','X-Accel-Buffering':'no'});
      const send=event=>{if(!res.destroyed&&!res.writableEnded)res.write(JSON.stringify(event)+'\n');};
      try {
        if(automaticPresentation) {
          send({type:'status',message:'Choosing response…'});
          const choice=await routePresentation(request,{signal:controller.signal});
          controller.signal.throwIfAborted();
          const mode=choice==='draw'?'draw':'chat';
          request={...request,...(mode==='draw'?request.drawing:{}),mode,drawing:null};
          claude=request.provider==='claude';
          auto=mode==='chat'&&request.model==='auto';
          send({type:'presentation',mode,source:['chat','draw'].includes(choice)?'decisions':'fallback'});
          if(!auto&&(claude?!await checkClaude():!await checkAuth()))throw new Error(`Sign in to ${claude?'Claude':'Codex'} to use the selected ${mode==='draw'?'Draw':'chat'} model.`);
          controller.signal.throwIfAborted();
        }
        if(auto) {
          send({type:'status',message:'Choosing model…'});
          const route=validateAutoRoute(await routeChat(request,{signal:controller.signal}));
          controller.signal.throwIfAborted();
          claude=route.provider==='claude';
          if(claude?!await checkClaude():!await checkAuth())throw new Error(`Auto chose ${route.name}, but ${claude?'Claude':'Codex'} is not signed in. Sign in or choose another model manually.`);
          controller.signal.throwIfAborted();
          request={...request,provider:route.provider,model:route.model,reasoningEffort:route.reasoningEffort};
          send({type:'route',...route});
        }
        const options={signal:controller.signal,onStatus:message=>send({type:'status',message}),onPreview:result=>send({type:'preview',result})};
        const output=editing ? await runEdit(request,options)
          : await runWithLoadingStatus(claude?runClaude:run,request,options,{chooseStatus:automaticPresentation&&request.mode==='draw'?async()=>'Drawing…':chooseStatus});
        send({type:'result',provider:request.provider,mode:request.mode,...output});
      }
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
  server.on('close',()=>{voice.closeAll().catch(()=>{});});
  return server;
}
if(process.argv[1]===fileURLToPath(import.meta.url)){
  const port=Number(process.env.CLIPPY_PORT||4317);
  const server=createServer();
  server.on('error',error=>{console.error(error.code==='EADDRINUSE'?`Port ${port} is in use. Set CLIPPY_PORT to another port.`:error.message);process.exitCode=1;});
  server.listen(port,'127.0.0.1',()=>console.log(`Clip is ready at http://127.0.0.1:${port}`));
}

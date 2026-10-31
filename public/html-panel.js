// Generated markup is data, never application code. No scripts, navigation,
// same-origin privileges or native message bridge are granted to this frame.
const tags=new Set('SECTION ARTICLE DIV SPAN P H1 H2 H3 H4 UL OL LI DL DT DD TABLE THEAD TBODY TR TH TD CAPTION STRONG EM B I SMALL CODE PRE BLOCKQUOTE HR BR DETAILS SUMMARY LABEL INPUT STYLE'.split(' '));
const attributes=new Set(['class','id','style','title','open','name','value','checked','for','colspan','rowspan','aria-label']);
export function explanationDocument(result,doc=globalThis.document){
  if(!result||typeof result.title!=='string'||!Array.isArray(result.sections)||result.sections.length>8)throw Error('Invalid explanation.');
  const html=result.sections.map(s=>{if(typeof s.html!=='string'||s.html.length>8000)throw Error('Explanation section too large.');return s.html;}).join('\n');
  const parsed=new DOMParser().parseFromString(html,'text/html');
  // A detached HTML document does not execute scripts; copy only allowed nodes
  // into another detached document, never into the host DOM.
  function clean(node){
    if(node.nodeType===3)return doc.createTextNode(node.textContent);
    if(node.nodeType!==1||!tags.has(node.tagName))return null;
    if(node.tagName==='INPUT'&&!['checkbox','radio'].includes(node.getAttribute('type')))return null;
    const copy=doc.createElement(node.tagName.toLowerCase());
    for(const attr of node.attributes)if(attributes.has(attr.name))copy.setAttribute(attr.name,attr.value);
    if(node.tagName==='INPUT')copy.setAttribute('type',node.getAttribute('type'));
    for(const child of node.childNodes){const safe=clean(child);if(safe)copy.append(safe);}
    return copy;
  }
  const wrapper=doc.createElement('div');
  for(const node of [...parsed.head.childNodes,...parsed.body.childNodes]){const safe=clean(node);if(safe)wrapper.append(safe);}
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><style>:root{color-scheme:light;font:16px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;color:#202830;background:#faf9f4}*{box-sizing:border-box}body{margin:0;padding:24px;overflow-wrap:anywhere}h1,h2,h3{line-height:1.2;letter-spacing:-.03em}h1{font-size:27px}h2{font-size:21px}section+section{margin-top:24px}details{border:1px solid #273b4926;border-radius:12px;padding:12px 16px;margin:16px 0}summary{cursor:pointer;font-weight:600}table{border-collapse:collapse;max-width:100%;width:100%}th,td{padding:10px;border-bottom:1px solid #273b4920;text-align:left}pre{white-space:pre-wrap}input{accent-color:#34836b}*:focus-visible{outline:2px solid #34836b;outline-offset:3px}@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}</style></head><body>${wrapper.innerHTML}</body></html>`;
}
export class HTMLPanel {
  constructor(frame){this.frame=frame;this.timer=null;this.pending=null;this.frame.setAttribute('sandbox','');this.frame.setAttribute('referrerpolicy','no-referrer');}
  render(result,preview=false){
    this.pending=result;
    if(!preview){clearTimeout(this.timer);this.timer=null;this.flush();}
    else if(!this.timer)this.timer=setTimeout(()=>{this.timer=null;this.flush();},300);
  }
  flush(){if(!this.pending)return;this.frame.srcdoc=explanationDocument(this.pending);this.pending=null;this.frame.hidden=false;}
  clear(){clearTimeout(this.timer);this.timer=null;this.pending=null;this.frame.hidden=true;this.frame.removeAttribute('srcdoc');}
}

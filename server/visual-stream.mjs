import { assertResult } from './schema.mjs';

// Parse only complete scalar tokens and complete array members. Open objects
// expose their completed children, so a scene can render before its array ends.
// Nothing is evaluated, repaired into executable code, or sent without validation.
export function partialJSON(text) {
  let i=0;
  const space=()=>{while(/\s/.test(text[i]||'!'))i++;};
  function value(depth=0) {
    if(depth>16)throw new Error('Visual nesting is too deep.');
    space();const c=text[i];
    if(c===undefined)return {complete:false};
    if(c==='{'||c==='['){
      const object=c==='{',out=object?Object.create(null):[];i++;space();
      const close=object?'}':']';
      if(text[i]===close){i++;return {value:out,complete:true};}
      while(i<text.length){
        let key;
        if(object){const token=string();if(!token.complete)return {value:out,complete:false};key=token.value;space();if(i===text.length)break;if(text[i++]!==':')throw new Error('Invalid visual JSON.');}
        const child=value(depth+1);
        if(object&&child.value!==undefined)out[key]=child.value;
        else if(!object&&child.complete)out.push(child.value);
        if(!child.complete)return {value:out,complete:false};
        space();if(i===text.length)break;
        if(text[i]===close){i++;return {value:out,complete:true};}
        if(text[i++]!==',')throw new Error('Invalid visual JSON.');space();
        if(text[i]===close)throw new Error('Invalid visual JSON.');
      }
      return {value:out,complete:false};
    }
    if(c==='"')return string();
    const start=i;while(i<text.length&&!/[\s,}\]]/.test(text[i]))i++;
    if(i===text.length)return {complete:false};
    return {value:JSON.parse(text.slice(start,i)),complete:true};
  }
  function string(){
    space();if(text[i]!=='"')throw new Error('Invalid visual JSON.');
    const start=i++;let escaped=false;
    while(i<text.length){const c=text[i++];if(escaped){escaped=false;continue;}if(c==='\\'){escaped=true;continue;}if(c==='"')return {value:JSON.parse(text.slice(start,i)),complete:true};}
    return {complete:false};
  }
  const parsed=value();space();if(parsed.complete&&i<text.length)throw new Error('Invalid trailing visual data.');return parsed.value;
}

export function visualPreview(raw) {
  const parsed=partialJSON(raw);if(!parsed||typeof parsed!=='object')return null;
  const result={title:typeof parsed.title==='string'?parsed.title:'Drawing…',reply:'',cards:[],annotations:[],diagram:{nodes:[],links:[]},scene:{objects:[]}};
  // Full result validation also bounds each complete candidate, IDs, coordinates
  // and references. A failed candidate never reaches any renderer.
  for(const [key,items] of [['objects',parsed.scene?.objects],['nodes',parsed.diagram?.nodes],['links',parsed.diagram?.links],['annotations',parsed.annotations]]){
    if(items!==undefined&&!Array.isArray(items))throw new Error('Invalid visual collection.');
    if(key==='objects')result.scene.objects=items||[];
    else if(key==='annotations')result.annotations=items||[];
    else result.diagram[key]=items||[];
  }
  // JSON object field order is not guaranteed. Keep links pending until both
  // endpoint nodes arrive, then validate the completed final result normally.
  const ids=new Set(result.diagram.nodes.map(node=>node?.id));
  result.diagram.links=result.diagram.links.filter(link=>link&&ids.has(link.from)&&ids.has(link.to));
  assertResult(result);
  return result.scene.objects.length||result.diagram.nodes.length||result.annotations.length?result:null;
}

export function previewEmitter(onPreview=()=>{}) {
  let previous='';
  return raw=>{
    if(raw.length>2_000_000)throw new Error('Visual response too large.');
    const result=visualPreview(raw);if(!result)return;
    const serialized=JSON.stringify(result);
    if(serialized!==previous){previous=serialized;onPreview(result);}
  };
}

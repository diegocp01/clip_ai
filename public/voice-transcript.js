// Captions are derived exclusively from the audio transcript, never Draw's reply.
export class VoiceTranscript {
  constructor(){this.begin();}
  begin(responseID=null){this.responseID=responseID;this.parts=new Map();this.interrupted=false;}
  interrupt(){this.interrupted=true;this.parts.clear();return '';}
  accepts(event){return !this.interrupted&&(!event.response_id||!this.responseID||event.response_id===this.responseID);}
  update(event){
    if(!this.accepts(event))return null;
    const key=`${event.output_index??0}:${event.content_index??0}`;
    if(event.type==='response.output_audio_transcript.done')this.parts.set(key,String(event.transcript??''));
    else this.parts.set(key,(this.parts.get(key)||'')+String(event.delta??''));
    return this.text();
  }
  finish(response){
    if(response?.status!=='completed'||!this.accepts({response_id:response.id}))return null;
    const parts=[];
    for(const item of response.output||[])for(const part of item.content||[])if(['audio','output_audio'].includes(part.type)&&typeof part.transcript==='string')parts.push(part.transcript);
    if(!parts.length)return null;
    this.parts=new Map(parts.map((text,index)=>[`${index}:0`,text]));return this.text();
  }
  text(){
    const value=[...this.parts.entries()].sort(([a],[b])=>{const x=a.split(':').map(Number),y=b.split(':').map(Number);return x[0]-y[0]||x[1]-y[1];}).map(([,text])=>text).join('\n\n');
    if(value.length>32000)throw Error('Voice transcript exceeded the supported reply size.');
    return value;
  }
}

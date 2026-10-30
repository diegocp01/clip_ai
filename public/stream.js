// Shared bounded NDJSON reader. Decode across arbitrary UTF-8/chunk boundaries.
export async function* readEvents(response) {
  if(!response.body)throw new Error('The server returned no response stream.');
  const reader=response.body.getReader(),decoder=new TextDecoder();let pending='',total=0;
  try {
    while(true){
      const {value,done}=await reader.read();total+=value?.byteLength||0;
      if(total>16_000_000)throw new Error('Visual stream too large.');
      pending+=decoder.decode(value,{stream:!done});
      const lines=pending.split('\n');pending=lines.pop();
      if(pending.length>2_000_000)throw new Error('Visual event too large.');
      for(const line of lines){if(line.length>2_000_000)throw new Error('Visual event too large.');if(line.trim())yield JSON.parse(line);}
      if(done){if(pending.trim())yield JSON.parse(pending);break;}
    }
  }finally{await reader.cancel().catch(()=>{});reader.releaseLock();}
}

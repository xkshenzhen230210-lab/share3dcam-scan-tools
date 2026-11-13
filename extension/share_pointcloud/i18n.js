// Shared phrases are data-only in translations.js; Ruby reads the same table.
globalThis.ScanI18n = (() => {
  const entries=globalThis.SHARE_TRANSLATIONS;
  const escape=text=>text.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  const patterns=Object.entries(entries).filter(([key])=>/\{\d+\}/.test(key)).map(([source,target])=>{
    const indices=[];
    const expression=source.split(/(\{\d+\})/).map(part=>{
      if(/^\{\d+\}$/.test(part)){indices.push(Number(part.slice(1,-1)));return '([\\s\\S]*?)'}
      return escape(part);
    }).join('');
    return {regex:new RegExp('^'+expression+'$'),target,indices};
  });
  const interpolate=(text,values)=>text.replace(/\{(\d+)\}/g,(token,index)=>values[index]===undefined ? token : String(values[index]));
  function translate(text,language,values,depth=0){
    text=String(text??'');
    if(language!=='en')return values ? interpolate(text,values) : text;
    if(Object.hasOwn(entries,text))return interpolate(entries[text],values||[]);
    if(depth<4){
      for(const pattern of patterns){
        const match=pattern.regex.exec(text);
        if(!match)continue;
        const captures=[];
        pattern.indices.forEach((index,i)=>captures[index]=translate(match[i+1],language,undefined,depth+1));
        return interpolate(pattern.target,captures);
      }
    }
    return text; // Never alter unknown filenames, paths or backend diagnostics.
  }
  function snapshot(document){
    const nodes=[],attributes=[];
    const dynamic='#status,#mesh_status,#error,#name,#metrics,#level_readout,#offset,output,[data-language],script,style';
    const walker=document.createTreeWalker(document.body,4);
    let node;
    while((node=walker.nextNode())){
      if(!node.nodeValue.trim() || node.parentElement.closest(dynamic))continue;
      nodes.push([node,node.nodeValue]);
    }
    document.querySelectorAll('[aria-label],[title],[placeholder]').forEach(element=>{
      ['aria-label','title','placeholder'].forEach(key=>{
        if(element.hasAttribute(key))attributes.push([element,key,element.getAttribute(key)]);
      });
    });
    const originalTitle=document.title;
    return language=>{
      document.documentElement.lang=language;
      document.title=translate(originalTitle,language);
      nodes.forEach(([node,source])=>node.nodeValue=source.replace(source.trim(),translate(source.trim(),language)));
      attributes.forEach(([element,key,source])=>element.setAttribute(key,translate(source,language)));
    };
  }
  return {translate,snapshot};
})();

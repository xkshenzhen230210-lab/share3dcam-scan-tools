// npm install --prefix build/bilingual/browser playwright
const {chromium}=require('../build/bilingual/browser/node_modules/playwright');
const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs'),{pathToFileURL}=require('node:url');
async function main(){
 const root=path.resolve(__dirname,'..'),out=path.join(root,'build/bilingual/screenshots');
 fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({channel:'chrome',headless:true});
 try{
  const page=await browser.newPage({viewport:{width:432,height:900}}),errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await page.addInitScript(()=>{window.actions=[];window.sketchup={action:(name,payload)=>{
   window.actions.push({name,payload});
   if(name==='language' && window.testState){window.testState.language=payload.language;receive(window.testState)}
  }}});
  await page.goto(pathToFileURL(path.join(root,'extension/share_pointcloud/panel.html')).href);
  await page.evaluate(()=>{
   window.testState={language:'zh-CN',busy:false,message:'GPU · Test GPU · 高斯参照 1234',mesh_message:'',
    options:{visible:true,box:true,slice:false,plane:true,size:0,plane_z:2.5,slice_z:1.2,slice_width:.1,x:0,y:0,z:0,angle:0,color:'rgb',budget:50000,gaussian_opacity:65,free_crop:[]},
    cloud:{name:'室内测试.ply',gaussian:true,source:1234,indexed:1234,visible:900,offset:[0,0,0],full_resolution:true,frame:{submitted_points:1234,uploads:1}},
    elevation:{model_z:2.5,source_z:-1}};
   receive(window.testState);
  });
  await page.locator('#tab-draw').click();
  await page.locator('#shape_segments').evaluate(el=>el.closest('details').open=true);
  await page.locator('#shape_segments').fill('96');
  await page.locator('#polygon_sides').fill('8');
  await page.evaluate(()=>document.getElementById('x').value='1.234');
  const identity=await page.locator('#shape_segments').evaluate(el=>{window.originalInput=el;return true});
  assert.equal(identity,true);
  await page.locator('[data-language=en]').click();
  assert.equal(await page.locator('html').getAttribute('lang'),'en');
  assert.equal(await page.locator('#tab-draw').getAttribute('aria-selected'),'true');
  assert.equal(await page.locator('#shape_segments').inputValue(),'96');
  assert.equal(await page.locator('#polygon_sides').inputValue(),'8');
  assert.equal(await page.locator('#x').inputValue(),'1.234');
  assert.equal(await page.locator('#shape_segments').evaluate(el=>el===window.originalInput),true);
  assert.equal(await page.locator('#status').textContent(),'Full reference ready');
  assert.equal(await page.locator('#level_readout').textContent(),'Model Z 2.5000 m | Source Z -1.0000 m');
  assert.ok((await page.locator('#name').textContent()).endsWith('室内测试.ply'));
  await page.getByRole('button',{name:'Circle',exact:true}).click();
  assert.equal(await page.evaluate(()=>actions.at(-1).name),'draw_circle');
  assert.equal(await page.evaluate(()=>actions.at(-1).payload.shape_segments),96);
  assert.equal(await page.evaluate(()=>actions.at(-1).payload.polygon_sides),8);
  await page.evaluate(()=>showError('请输入有效数字'));
  assert.equal(await page.locator('#error').textContent(),'Enter a valid number.');
  await page.locator('[data-language="zh-CN"]').click();
  assert.equal(await page.locator('#error').textContent(),'请输入有效数字');
  await page.evaluate(()=>showError(''));
  for(const width of [320,360,432,640]){
   await page.setViewportSize({width,height:900});
   for(const language of ['zh-CN','en']){
    await page.locator(`[data-language="${language}"]`).click();
    for(const tab of ['import','view','draw','project']){
     await page.locator('#tab-'+tab).click();
     await page.locator('#page-'+tab+' details').evaluateAll(elements=>elements.forEach(el=>el.open=true));
     const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>window.innerWidth);
     assert.equal(overflow,false,`${width}px ${language} ${tab} overflows`);
     if(language==='en'){
      const untranslated=await page.locator('body').evaluate(body=>{
       const result=[],walker=document.createTreeWalker(body,4);let node;
       while((node=walker.nextNode())){
        const parent=node.parentElement;
        if(parent.closest('script,style,[data-language],.language-caption,.language-switch,#name') || !parent.checkVisibility())continue;
        if(/[\u4e00-\u9fff]/.test(node.nodeValue))result.push(node.nodeValue.trim());
       }return result;
      });
      assert.deepEqual(untranslated,[],`${tab}: untranslated text`);
     }
    }
    await page.locator('#tab-draw').click();
    await page.screenshot({path:path.join(out,`${width}_${language}.png`),fullPage:true});
   }
  }
  await page.locator('[data-language=en]').click();await page.reload();
  assert.equal(await page.locator('html').getAttribute('lang'),'en','stored UI language restored');
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(root,'build/bilingual/browser-result.json'),JSON.stringify({status:'PASS',widths:[320,360,432,640],languages:['zh-CN','en'],tabs:4,preservedInputIdentity:true,dimensionsPreserved:true,actionsVerified:true,errors},null,2));
  console.log('Browser: 32 language/width/tab combinations; inputs, callbacks, persistence, errors and layout: PASS');
 }finally{await browser.close()}
}
main().catch(error=>{console.error(error.stack);process.exitCode=1});

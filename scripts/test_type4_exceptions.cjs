// Exception identity/classification only. Actual production JS is extracted, but Swift
// performType, WK error bridging and UIKit failure screenshots are NOT executed here.
const fs=require('fs'),path=require('path');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE||undefined});
 try{
  const page=await browser.newPage({viewport:{width:1024,height:768}}),checks=[],records=[],pageErrors=[];
  page.on('pageerror',e=>pageErrors.push({message:e.message,stack:e.stack}));
  const check=(ok,label)=>checks.push({ok:!!ok,label});
  const swift=fs.readFileSync('MikaWeb/WebController.swift','utf8');
  const state=fs.readFileSync('MikaWeb/PageState.swift','utf8');
  const extract=state.split('static let extract = #"""')[1].split('"""#')[0].trim();
  function swiftScript(method,marker){const a=swift.indexOf(marker,swift.indexOf(method)),b=swift.indexOf('\n        """, on: tab)',a);return swift.slice(a,b).replaceAll('\\\\','\\');}
  const template=swiftScript('private func runTypeScript','(()=>{\\(prefix)');
  const probe=swiftScript('private func probeEditorSignals','(()=>{const a=\\(json);');
  const strategies=['paste-plain','paste','events','chunks','exec'];
  // Test-side mirror only. Neither this classifier nor its error objects execute Swift.
  function policyVerdict({baselineCount,postCount,textOK,expectedCount,longForm}){
   if(!textOK)return {kind:'failDomMissing'};
   if(postCount==null)return {kind:baselineCount==null&&!longForm?'pass':'failSignalLost'};
   const low=Math.max(0,Math.trunc(expectedCount*0.85)-5),high=Math.trunc(expectedCount*1.15)+10;
   const consistent=expectedCount===0||(postCount>=low&&postCount<=high)||
    (baselineCount!=null&&postCount>baselineCount&&postCount-baselineCount>=low&&postCount-baselineCount<=high);
   return consistent?{kind:'pass'}:{kind:'failFrozen',count:postCount};
  }
  function verifiedRejection({trace,error,updateCalls,baselineIntact,counted}){
   const attempts=[],terminals=[];
   for(const row of trace){
    if(typeof row!=='string')continue;
    if(row.startsWith('{')){try{const a=JSON.parse(row);if(strategies.includes(a.strategy))attempts.push(a);}catch(_){}}
    for(const strategy of strategies)if(row.startsWith(strategy+'='))terminals.push({strategy,status:row.slice(strategy.length+1)});
   }
   const g=typeof trace[0]==='string'&&trace[0].startsWith('path=editor,')&&error?.isMikaError===true&&
    updateCalls===0&&baselineIntact===true&&typeof counted==='number'&&counted===0;
   const plain=attempts.filter(a=>a.strategy==='paste-plain');
   const ordered=[
    x=>x.hop===1&&x.status==='arrived'&&x.event==='paste'&&x.targetIsHost===true,
    x=>x.hop===2&&x.status==='framework-handler'&&x.editor==='primary'&&x.fullTextEqual===true&&x.htmlPresent===false,
    x=>x.hop===2&&x.status==='ignored-handler'&&x.kind==='paste'&&x.fullTextEqual===true,
    x=>x.hop===1&&x.status==='dispatch-complete'&&x.defaultPrevented===true
   ];
   let h=false;
   if(plain.length===1&&typeof plain[0].id==='string'&&plain[0].id.length>0&&Array.isArray(plain[0].hops)){
    let cursor=-1;h=ordered.every(test=>{cursor=plain[0].hops.findIndex((x,i)=>i>cursor&&test(x));return cursor>=0;});
   }
   const f=terminals.some(t=>t.status==='dom-ok,count-frozen:0(基线0)');
   const ids=attempts.map(a=>a.id);
   const d=!f&&attempts.length===5&&ids.every(id=>typeof id==='string'&&id.length>0)&&new Set(ids).size===5&&
    strategies.every(strategy=>{
     const a=attempts.filter(x=>x.strategy===strategy),t=terminals.filter(x=>x.strategy===strategy);
     if(a.length!==1||t.length!==1||t[0].status!=='dom-missing'||!Array.isArray(a[0].hops))return false;
     const counters=a[0].hops.filter(x=>x.status==='counter-observed');
     return counters.length>0&&counters.every(x=>typeof x.count==='number'&&Number.isFinite(x.count)&&x.count===0);
    });
   const errorMessage=typeof error?.message==='string'?error.message:'';
   const errFrozen=errorMessage.includes('编辑器内部字数仍停在 0 字');
   const errDomMissing=errorMessage.includes('5 种写入方式都已尝试、回读仍为空或对不上');
   return {g,h,f,d,errorKind:errFrozen?'frozen':errDomMissing?'domMissing':'other',errorMessage,trace,
    pass:g&&h&&((f&&errFrozen)||(d&&errDomMissing))};
  }
  const text='忽略处理器不得提交这段正文。'.repeat(4);
  async function reset(){
   await page.goto('file://'+path.resolve('MikaWeb/Resources/test-draft.html'));await page.waitForFunction(()=>window.__ready);
   await page.evaluate(text=>{window.__type4SetExceptionContext('ignored-handler','reset-and-prepare');window.__type4.reset('','ignore',text);},text);
  }
  async function inject(strategy){
   const snapshot=JSON.parse(await page.evaluate(extract));
   const index=await page.evaluate(()=>Number(document.querySelector('[data-mika-slot=primary]').getAttribute('data-mika-idx')));
   check(snapshot.elements.some(x=>x.index===index&&x.editable),strategy+': actual snapshot binding');
   const prefix=`const a=${JSON.stringify({text,index})},e=document.querySelector('[data-mika-slot=primary]');`;
   const source=template.replace('\\(prefix)',prefix).replaceAll('\\(path)',strategy).replaceAll('\\(clipboardConstruction)','auto').replaceAll('\\(clipboardTextJSON)',JSON.stringify(text));
   await page.evaluate(()=>window.__type4SetExceptionContext('ignored-handler','performType-JS-sequence'));
   const status=await page.evaluate(source);await page.waitForTimeout(500);
   const signals=JSON.parse(await page.evaluate(probe.replace('\\(json)',JSON.stringify({index,epoch:1}))));
   const domFullEqual=await page.evaluate(text=>document.querySelector('[data-mika-slot=primary]').innerText.replace(/[\s\u200b\ufeff]+/g,'')===text.replace(/[\s\u200b\ufeff]+/g,''),text);
   await page.evaluate(count=>window.__mikaTypeNote?.(5,'counter-observed',{count}),signals.count);
   return {strategy,status,signals,domFullEqual,attempt:await page.evaluate(()=>window.__mikaTypeAttempt),exceptionReport:await page.evaluate(()=>window.__type4ExceptionReport())};
  }
  await reset();
  for(const strategy of ['paste-plain','paste','events','chunks','exec'])records.push(await inject(strategy));
  // Match the post-failure extraction, and yield for asynchronous selectionchange errors.
  await page.evaluate(extract);await page.waitForTimeout(250);
  const natural=await page.evaluate(()=>({report:window.__type4ExceptionReport(),baseline:window.__type4.assert(''),calls:window.__updateCalls,faults:window.__faultEvidence}));
  check(natural.baseline&&natural.calls===0,'full dirty fallback control keeps baseline and update=0');
  check(natural.report.counted===0&&natural.report.entries.length===0,'ignored handler: no unrelated script exceptions');
  const frozenWitnesses=records.filter(x=>x.strategy&&x.status==='ok'&&x.domFullEqual&&x.signals.count===0).map(x=>x.strategy);
  check(frozenWitnesses.length>0,'at least one strategy has visible full body but frozen zero state');
  check(natural.faults.some(x=>x.kind==='paste'&&x.strategy==='paste-plain'&&x.fullTextEqual),'full control actually receives ignored body');
  check(natural.report.counted===natural.report.entries.length&&natural.report.excluded.length===0,'natural errors remain counted, none excluded');
  check(natural.report.entries.every(x=>x.counted&&x.classification==='unclassified-counted'&&Object.hasOwn(x,'filename')&&Object.hasOwn(x,'stack')),'natural identity preserved without source allowlist');
  records.push({case:'full-ignored-chain',frozenWitnesses,...natural});
  const trace=['path=editor,idx=true,基线字数=0'];
  let firstFrozen=null,lastVerdict;
  for(const r of records.filter(x=>x.strategy)){
   const verdict=policyVerdict({baselineCount:0,postCount:r.signals.count,textOK:r.domFullEqual,expectedCount:56,longForm:false});
   if(verdict.kind==='failFrozen'&&!firstFrozen)firstFrozen=verdict;
   lastVerdict=verdict;
   trace.push(JSON.stringify(r.attempt));
   trace.push(r.strategy+'='+(r.status==='exec-failed'?'exec-failed':verdict.kind==='failDomMissing'?'dom-missing':verdict.kind==='failFrozen'?'dom-ok,count-frozen:'+verdict.count+'(基线0)':verdict.kind==='failSignalLost'?'count-signal-lost':'pass'));
  }
  const mirroredError={isMikaError:true,message:firstFrozen?'文字已出现在编辑器里，但编辑器内部字数仍停在 0 字':'文字没能输入到编辑器：5 种写入方式都已尝试、回读仍为空或对不上'};
  const realEvidence=verifiedRejection({trace,error:mirroredError,updateCalls:natural.calls,baselineIntact:natural.baseline,counted:natural.report.counted});
  check(realEvidence.pass&&realEvidence.f&&!realEvidence.d,'ignored handler: expected verified rejection (other exceptions FAIL)');
  records.push({case:'verified-rejection-JS-mirror',nativeErrorExecuted:false,lastVerdict,evidence:realEvidence});
  // Same fixture, same empty baseline and body; only toggle the existing ignore mode off.
  await reset();await page.evaluate(()=>{window.__mode='';});
  const positive=await inject('paste-plain');
  const positiveState=await page.evaluate(text=>window.__type4.assert(text),text);
  check(positive.status==='ok'&&positiveState&&positive.signals.count===56,'ignored handler: positive control commits full text when ignore off');
  records.push({case:'positive-ignore-off',swiftPerformTypeExecuted:false,...positive});
  const pinned=policyVerdict({baselineCount:0,postCount:0,textOK:true,expectedCount:100,longForm:false});
  check(pinned.kind==='failFrozen'&&pinned.count===0,'type policy: frozen verdict pinned (baseline 0, post 0, expected 100)');
  const clone=x=>JSON.parse(JSON.stringify(x));
  const synthAttempt=strategy=>({id:'synthetic-D-'+strategy,strategy,hops:[
   ...(strategy==='paste-plain'?[
    {hop:1,status:'arrived',event:'paste',targetIsHost:true},
    {hop:2,status:'framework-handler',editor:'primary',fullTextEqual:true,htmlPresent:false},
    {hop:2,status:'ignored-handler',kind:'paste',fullTextEqual:true},
    {hop:1,status:'dispatch-complete',defaultPrevented:true}]:[]),
   {hop:5,status:'counter-observed',count:0}]});
  const synthetic={trace:['path=editor,idx=true,基线字数=0',...strategies.flatMap(strategy=>[JSON.stringify(synthAttempt(strategy)),strategy+'=dom-missing'])],
   error:{isMikaError:true,message:'文字没能输入到编辑器：5 种写入方式都已尝试、回读仍为空或对不上'},updateCalls:0,baselineIntact:true,counted:0};
  const syntheticCheck=(input,want,label)=>{const evidence=verifiedRejection(input);check(evidence.pass===want,label);records.push({case:label,synthetic:true,evidence});};
  syntheticCheck(synthetic,true,'synthetic D: complete five attempts and H with generic error PASS');
  for(let hop=0;hop<4;hop++){
   const c=clone(synthetic),a=JSON.parse(c.trace[1]);a.hops.splice(hop,1);c.trace[1]=JSON.stringify(a);
   syntheticCheck(c,false,'synthetic D: missing H hop '+hop+' FAIL');
  }
  {const c=clone(synthetic);c.trace[c.trace.length-1]='exec=dom-ok,count-frozen:0(基线0)';syntheticCheck(c,false,'synthetic F: frozen witness with generic error FAIL');}
  {const c=clone(synthetic);c.trace[c.trace.length-1]='exec=dom-ok,count-frozen:0(基线0)';c.error.message='编辑器内部字数仍停在 0 字';syntheticCheck(c,true,'synthetic F: frozen witness with frozen error PASS');}
  for(const status of ['exec-failed','count-signal-lost']){const c=clone(synthetic);c.trace[c.trace.length-1]='exec='+status;syntheticCheck(c,false,'synthetic D: '+status+' FAIL');}
  {const c=clone(synthetic);c.trace.pop();syntheticCheck(c,false,'synthetic D: missing terminal FAIL');}
  {const c=clone(synthetic);c.trace.push('exec=dom-missing');syntheticCheck(c,false,'synthetic D: duplicate terminal FAIL');}
  for(const count of [null,'0',1]){const c=clone(synthetic),a=JSON.parse(c.trace[1]);a.hops.at(-1).count=count;c.trace[1]=JSON.stringify(a);syntheticCheck(c,false,'synthetic D: counter '+JSON.stringify(count)+' FAIL');}
  {const c=clone(synthetic),a=JSON.parse(c.trace[1]);a.hops.pop();c.trace[1]=JSON.stringify(a);syntheticCheck(c,false,'synthetic D: missing counter FAIL');}
  {const c=clone(synthetic),a=JSON.parse(c.trace[3]);a.id=JSON.parse(c.trace[1]).id;c.trace[3]=JSON.stringify(a);syntheticCheck(c,false,'synthetic D: duplicate attempt id FAIL');}
  {const c=clone(synthetic),a=JSON.parse(c.trace[1]);[a.hops[0],a.hops[1]]=[a.hops[1],a.hops[0]];c.trace[1]=JSON.stringify(a);syntheticCheck(c,false,'synthetic D: reordered H FAIL');}
  {const c=clone(synthetic),a=JSON.parse(c.trace[1]);a.hops=a.hops.filter(x=>x.status!=='ignored-handler');c.trace[1]=JSON.stringify(a);const other=JSON.parse(c.trace[3]);other.hops.unshift({hop:2,status:'ignored-handler',kind:'paste',fullTextEqual:true});c.trace[3]=JSON.stringify(other);syntheticCheck(c,false,'synthetic D: H split across attempt ids FAIL');}
  for(const [key,value] of [['updateCalls',1],['baselineIntact',false],['counted',1]]){const c=clone(synthetic);c[key]=value;syntheticCheck(c,false,'synthetic G: '+key+' unsafe FAIL');}
  {const c=clone(synthetic);c.error.isMikaError=false;syntheticCheck(c,false,'synthetic G: non-MikaError FAIL');}
  {const c=clone(synthetic);c.trace[0]='path=legacy';syntheticCheck(c,false,'synthetic G: wrong route FAIL');}

  // Deterministic collector controls, not evidence identifying the simulator's unknown error.
  await reset();
  await page.evaluate(()=>{setTimeout(()=>{throw new Error('TYPE4-COLLECTOR-CONTROL original message');},0);
  //# sourceURL=mika-type4-collector-control.js
  });
  await page.waitForFunction(()=>window.__type4Errors.length===1);
  let report=await page.evaluate(()=>window.__type4ExceptionReport());
  const e=report.entries[0];
  check(e.message.includes('TYPE4-COLLECTOR-CONTROL original message')&&e.filename==='mika-type4-collector-control.js'&&e.lineno>0&&e.stack.includes('TYPE4-COLLECTOR-CONTROL original message'),'window.error raw message/source/line/stack preserved');
  check(report.counted===1&&report.excluded.length===0,'unknown error still makes the zero-exception requirement FAIL');
  records.push({case:'window-error-control',report});
  await page.evaluate(()=>{Promise.reject(new Error('TYPE4-PROMISE-CONTROL original message'));
  //# sourceURL=mika-type4-promise-control.js
  });
  await page.waitForFunction(()=>window.__type4UnhandledRejections.length===1);
  report=await page.evaluate(()=>window.__type4ExceptionReport());
  check(report.counted===2&&report.entries.some(x=>x.kind==='unhandledrejection'&&x.message==='TYPE4-PROMISE-CONTROL original message'&&x.stack.includes('mika-type4-promise-control.js')),'unhandled rejection counted by ignored hygiene report');
  const native={kind:'evaluateJavaScript',message:'TYPE4-NATIVE-BRIDGE-SHAPE-CONTROL',filename:'mika-native-shape-control.js',lineno:3,colno:2,scriptID:'shape-control-only',script:'throw new Error("shape control")',context:{case:'ignored-handler',phase:'performType'}};
  report=await page.evaluate(native=>window.__type4ExceptionReport([native]),native);
  check(report.counted===3&&report.entries.at(-1).script===native.script&&report.entries.at(-1).counted,'native report shape retained and counted (not a WK bridge execution)');
  records.push({case:'promise-and-native-shape-controls',report});
  const failed=checks.filter(x=>!x.ok).length;
  console.log(JSON.stringify({runtime:'Playwright Chromium (NOT WKWebView)',swiftPerformTypeExecuted:false,nativeBridgeExecuted:false,failed,checks,records,pageErrors},null,2));process.exitCode=failed?1:0;
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});

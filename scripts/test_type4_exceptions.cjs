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
   return {strategy,status,signals,exceptionReport:await page.evaluate(()=>window.__type4ExceptionReport())};
  }
  await reset();
  for(const strategy of ['paste-plain','paste','events','chunks','exec'])records.push(await inject(strategy));
  // Match the post-failure extraction, and yield for asynchronous selectionchange errors.
  await page.evaluate(extract);await page.waitForTimeout(250);
  const natural=await page.evaluate(()=>({report:window.__type4ExceptionReport(),baseline:window.__type4.assert(''),calls:window.__updateCalls,faults:window.__faultEvidence}));
  check(natural.baseline&&natural.calls===0,'full dirty fallback control keeps baseline and update=0');
  check(natural.report.counted===0&&natural.report.entries.length===0,'ignored handler: no unrelated script exceptions');
  check(records.at(-1).strategy==='exec'&&records.at(-1).status==='ok'&&records.at(-1).signals.count===0&&records.at(-1).signals.textLength===text.length,'last exec leaves visible body but frozen zero state');
  check(natural.faults.some(x=>x.kind==='paste'&&x.strategy==='paste-plain'&&x.fullTextEqual),'full control actually receives ignored body');
  check(natural.report.counted===natural.report.entries.length&&natural.report.excluded.length===0,'natural errors remain counted, none excluded');
  check(natural.report.entries.every(x=>x.counted&&x.classification==='unclassified-counted'&&Object.hasOwn(x,'filename')&&Object.hasOwn(x,'stack')),'natural identity preserved without source allowlist');
  records.push({case:'full-ignored-chain',...natural});
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

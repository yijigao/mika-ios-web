// Binding-only auxiliary evidence. Executes the actual Swift-embedded JS probe and
// production extractor; does NOT execute WK navigation delegates or native timeout gate.
const fs = require('fs'), path = require('path');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
(async()=>{
 const browser=await chromium.launch({headless:true, executablePath:process.env.CHROMIUM_EXECUTABLE || undefined});
 try {
  const page=await browser.newPage({viewport:{width:1024,height:768}});
  await page.goto('file://'+path.resolve('MikaWeb/Resources/test-draft.html'));
  await page.waitForFunction(()=>window.__ready);
  const swift=fs.readFileSync('MikaWeb/WebController.swift','utf8');
  const state=fs.readFileSync('MikaWeb/PageState.swift','utf8');
  const extract=state.split('static let extract = #"""')[1].split('"""#')[0].trim();
  const template=swift.split('                let probe = """')[1].split('                """')[0].trim();
  const script=slot=>template.replaceAll('\\(slotJSON)',JSON.stringify(slot))
   .replaceAll('\\(includeSnapshot ? "true" : "false")','true').replaceAll('\\(PageScript.extract)',extract);
  const checks=[],records=[];
  const check=(ok,label)=>checks.push({ok:!!ok,label});
  const probe=async slot=>JSON.parse(await page.evaluate(script(slot)));
  const initial=await probe('primary');
  check(initial.ready&&JSON.parse(initial.page).elements.some(x=>x.editable&&String(x.index)===initial.index),'ready host matches actual production snapshot');
  records.push({case:'initial',...initial,page:undefined});
  await page.evaluate(()=>document.getElementById('root').style.width='0px');
  const zeroBefore=await page.evaluate(()=>({ready:window.__ready,index:document.querySelector('[data-mika-slot=primary]').getAttribute('data-mika-idx'),width:document.querySelector('[data-mika-slot=primary]').getBoundingClientRect().width}));
  await page.evaluate(extract); // Reproduce old prepare(): extract first, then read host index.
  const zeroAfter=await page.evaluate(()=>document.querySelector('[data-mika-slot=primary]').getAttribute('data-mika-idx'));
  const zero=await probe('primary');
  check(zeroBefore.ready&&zeroBefore.width===0&&zeroAfter===null,'old binding failure reproduced: ready flag true but zero-width host index removed');
  check(!zero.ready&&zero.page===null&&zero.host.width===0,'new probe refuses zero-width host, no snapshot bypass');
  records.push({case:'zero-width',zeroBefore,zeroAfter,...zero,page:undefined});
  await page.evaluate(()=>document.getElementById('root').style.width='');
  const recovered=await probe('primary');
  check(recovered.ready&&JSON.parse(recovered.page).elements.some(x=>x.editable&&String(x.index)===recovered.index),'layout restored: bind via production extractor without hand-written index');
  const registration=await page.evaluate(()=>{const h=document.querySelector('[data-mika-slot=primary]');h.removeAttribute('data-mika-slot');setTimeout(()=>h.setAttribute('data-mika-slot','primary'),180);return true;});
  let attempts=0,last,first;const started=performance.now();
  do { last=await probe('primary');first ||= last;attempts++;if(last.ready)break;await new Promise(r=>setTimeout(r,25)); } while(performance.now()-started<1000);
  check(registration&&first.matches===0&&attempts>1&&last.ready,'delayed registration: readiness polling observes missing -> registered');
  records.push({case:'delayed-registration',attempts,waitedMs:Math.round(performance.now()-started),first:{...first,page:undefined},last:{...last,page:undefined}});
  const absent=await probe('missing');
  check(!absent.ready&&absent.matches===0&&absent.page===null,'missing slot remains unready, never skipped or passed');
  records.push({case:'missing',...absent,page:undefined});
  await page.evaluate(()=>window.__type4.dual('第一编辑器','','第二编辑器'));
  const secondary=await probe('secondary');
  check(secondary.ready&&JSON.parse(secondary.page).elements.some(x=>x.editable&&String(x.index)===secondary.index),'secondary binds same production snapshot');
  const primary=await probe('primary');
  check(primary.ready&&primary.index!==secondary.index,'two slots remain independently indexed');
  const failed=checks.filter(x=>!x.ok).length;
  console.log(JSON.stringify({runtime:'Playwright Chromium binding probe only (NOT WKWebView)',nativeNavigationGateExecuted:false,failed,checks,records},null,2));
  process.exitCode=failed?1:0;
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});

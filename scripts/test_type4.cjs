// Auxiliary Chromium evidence only. Injection/probe scripts are extracted from production Swift.
// Swift performType orchestration is covered by App self-test 42, never simulated here.
const fs = require('fs');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const path = require('path');
(async () => {
 const browser = await chromium.launch({headless:true, executablePath:process.env.CHROMIUM_EXECUTABLE || undefined});
 try {
  const page = await browser.newPage();
  const pageErrors = [];
  page.on('pageerror', error => pageErrors.push(error.message));
  async function loadFixture() {
   await page.goto('file://' + path.resolve('MikaWeb/Resources/test-draft.html'));
   await page.waitForFunction(() => window.__ready, {timeout:10000});
  }
  const swift = fs.readFileSync('MikaWeb/WebController.swift','utf8');
  function extract(method, marker) {
   const start = swift.indexOf(marker, swift.indexOf(method));
   const end = swift.indexOf('\n        """, on: tab)', start);
   if(start < 0 || end < 0) throw new Error('Production script extraction failed: ' + method);
   return swift.slice(start,end).replaceAll('\\\\','\\');
  }
  const template = extract('private func runTypeScript','(()=>{\\(prefix)');
  const probeTemplate = extract('private func probeEditorSignals','(()=>{const a=\\(json);');
  const checks = [], records = [];
  function check(ok, label) { checks.push({ok:!!ok,label}); }
  async function reset(old,text,mode='') {
   await loadFixture();
   await page.evaluate(({old,text,mode}) => window.__type4.reset(old,mode,text), {old,text,mode});
  }
  async function inject(text,strategy,construction='auto',payload=text,slot='primary') {
   const index = slot === 'primary' ? 7 : 8;
   const prefix = `const a=${JSON.stringify({index,text})},e=document.querySelector('[data-mika-slot="${slot}"]');`;
   const source = template.replace('\\(prefix)',prefix).replaceAll('\\(path)',strategy)
    .replaceAll('\\(clipboardConstruction)',construction).replaceAll('\\(clipboardTextJSON)',JSON.stringify(payload));
   await page.evaluate(source);
   await page.waitForTimeout(30);
   return page.evaluate(({text,slot}) => ({exact:window.__type4.assert(text,slot),errors:window.__type4Errors,diagnostic:window.__mikaTypeAttempt,faults:window.__faultEvidence}), {text,slot});
  }
  async function probe(index) { return JSON.parse(await page.evaluate(probeTemplate.replace('\\(json)',JSON.stringify({index,epoch:1})))); }
  const longText = '长文完整比较：段落和标点必须保留。\n\n'.repeat(200);
  for(const [name,old,text] of [['empty','','中文短文。'],['equal','旧文甲乙','新文丙丁'],['multi','旧文','第一段。\n\n第二段 😀\n末段  保留空格。'],['long','旧文',longText]]) {
   for(const strategy of ['paste-plain','paste','events','chunks','exec','range']) {
    for(const construction of strategy.startsWith('paste') ? ['native','compat'] : ['auto']) {
     const label = `${name}/${strategy}/${construction}`;
     await reset(old,text);
     const r = await inject(text,strategy,construction);
     records.push({case:label,...r});
     if(!strategy.startsWith('paste')) continue; // independent diagnostic controls, no success assumed
     check(r.errors.length===0,label+': no script exceptions');
     if(strategy==='paste' && text.includes('\n\n')) {
      check(r.diagnostic.hops.some(x=>x.status==='framework-handler'&&x.fullTextEqual&&x.htmlPresent===true),label+': dual-format control receiver');
      continue; // full equality remains recorded as false; never counted as successful input
     }
     check(r.exact,label+': full committed equality');
     const h = r.diagnostic.hops;
     check(h.some(x=>x.hop===1&&x.status==='arrived') && [2,3,4].every(n=>h.some(x=>x.hop===n&&x.fullTextEqual)) && h.some(x=>x.hop===5&&x.matchesCommitted),label+': five hops');
     check(h.some(x=>x.status==='clipboard-construction'&&x.actual===construction&&x.prototypePreserved&&x.objectReplaced===false),label+': forced construction/prototype');
     const reads = h.filter(x=>x.status==='framework-handler');
     check(reads.some(x=>x.fullTextEqual),label+': handler body');
     if(strategy==='paste-plain')check(reads.some(x=>x.fullTextEqual&&x.htmlPresent===false),label+': receiver no HTML');
     const saved = await page.evaluate(text=>{
      document.activeElement.blur(); window.__type4.rerender();
      const stable=window.__type4.assert(text);
      const payload=window.__type4.savePayload();
      const cleared=window.__type4.clearForRestore() && window.__type4.text()==='';
      window.__type4.restorePayload();
      return {stable,payload,cleared,restored:window.__type4.assert(text)};
     },text);
     check(saved.stable,label+': blur/rerender'); check(saved.cleared,label+': clear'); check(saved.restored,label+': independent JSON restore');
     records.push({case:label+'/save',...saved});
    }
   }
  }
  await reset('','DOM-only');
  const dom = await page.evaluate(()=>{document.querySelector('[data-mika-slot=primary]').textContent='DOM-only';return window.__type4.assert('DOM-only');});
  check(!dom,'DOM-only rejects');
  for(const construction of ['native','compat']) {
   const text='忽略处理器不得提交这段正文。'.repeat(4);
   await reset('',text,'ignore');
   const r=await inject(text,'paste-plain',construction);
   check(r.errors.length===0,'ignore: no unrelated script exceptions');
   check(!r.exact && r.faults.some(x=>x.kind==='paste'&&x.fullTextEqual),'ignore/'+construction+': handler receipt, exact FAIL');
   check(await page.evaluate(()=>window.__type4.assert('')&&window.__updateCalls===0),'ignore/'+construction+': baseline and zero update');
   records.push({case:'ignore/'+construction,...r});
  }
  await reset('','上层拒绝候选状态','reject');
  const rejected=await inject('上层拒绝候选状态','paste-plain','native');
  check(rejected.errors.length===0,'reject: no script exceptions');
  check(!rejected.exact && rejected.faults.some(x=>x.kind==='application-rejected'&&x.fullTextEqual) && rejected.diagnostic.hops.some(x=>x.status==='generated'&&x.fullTextEqual),'reject: complete candidate rejected');
  check(await page.evaluate(()=>window.__type4.assert('')&&window.__updateCalls===0),'reject: baseline and zero update');
  records.push({case:'reject',...rejected});
  for(const construction of ['native','compat']) {
   await reset('','传输正文不可丢失尾部');
   const r=await inject('传输正文不可丢失尾部','paste-plain',construction,'传输正文不可丢失');
   check(r.errors.length===0,'data-loss: no script exceptions');
   check(!r.exact&&r.diagnostic.hops.some(x=>x.status==='framework-handler'&&x.fullTextEqual===false&&x.htmlPresent===false),'data-loss/'+construction+': receiver mismatch');
   check(await page.evaluate(()=>window.__type4.assert('传输正文不可丢失')&&window.__updateCalls===0),'data-loss/'+construction+': truncated committed, zero update');
   records.push({case:'data-loss/'+construction,...r});
  }
  const untouched='第一编辑器保持原文'.repeat(40), second='第二编辑器独立正文。';
  await loadFixture();
  await page.evaluate(({untouched,second})=>window.__type4.dual(untouched,'',second),{untouched,second});
  const before=await probe(8);
  const dual=await inject(second,'paste-plain','native',second,'secondary');
  const after=await probe(8);
  check(before.locatedByIndex&&before.count===0&&after.locatedByIndex&&after.count===second.length,'dual: production JS probe bound to second counter');
  check(await page.evaluate(({untouched,second})=>window.__type4.assert(untouched)&&window.__type4.assert(second,'secondary'),{untouched,second}),'dual: first state/counter intact, second exact');
  records.push({case:'dual',before,after,...dual});
  check(dual.errors.length===0,'dual: no script exceptions');
  const failed=checks.filter(x=>!x.ok).length;
  console.log(JSON.stringify({runtime:'Playwright Chromium (NOT WKWebView)',swiftCompiled:false,productionPerformTypeExecuted:false,longTextUTF16Length:longText.length,failed,checks,pageErrors,records},null,2));
  process.exitCode=failed?1:0;
 } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});

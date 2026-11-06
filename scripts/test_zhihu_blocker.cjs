#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const root = path.resolve(__dirname, '..');
const swift = fs.readFileSync(path.join(root, 'MikaWeb/WebController.swift'), 'utf8');
const match = swift.match(/static let frameProbeScript = #"""([\s\S]*?)"""#/);
if (!match) throw new Error('frameProbeScript not found');
const production = match[1];
const checks = [];
const check = (ok, label) => checks.push({ ok: !!ok, label });
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE || undefined });
  const context = await browser.newContext();
  await context.addInitScript({ content: `
    if (window === window.top) window.__mikaReports = [];
    Object.defineProperty(window, 'webkit', { configurable:true, value:{ messageHandlers:{ mikaFrameProbe:{ postMessage:p=>{ try{ top.__mikaReports.push(p); }catch(_){} } } } } });
    ${production}
  ` });
  const page = await context.newPage();
  const load = html => page.goto('data:text/html;charset=utf-8,' + encodeURIComponent(html));

  const probe = async payload => {
    await page.evaluate(p => { top.__mikaReports = []; window.postMessage({__mikaFrame:1,kind:'probe',token:'probe-'+Date.now(),...p}, '*'); }, payload);
    await wait(150);
    return page.evaluate(() => top.__mikaReports.filter(x => x.kind === 'probe-report'));
  };

  await load(`<div role="dialog"><button data-mika-idx="7" onclick="top.topClicks++">写回答</button></div>
    <iframe srcdoc="<div role='dialog'><button onclick='parent.childClicks++'>写回答</button></div>"></iframe>
    <script>topClicks=0;childClicks=0</script>`);
  await page.evaluate(() => window.webkit.messageHandlers.mikaFrameProbe.postMessage({kind:'shim-control'}));
  const shimControl = await page.evaluate(() => top.__mikaReports.length);
  if (shimControl !== 1) throw new Error('message shim failed');
  let reports = await probe({ targetIndex:7, targetLabel:'写回答', targetTag:'button' });
  const topReport = reports.find(x => x.path === 'top');
  if (!topReport) throw new Error('top probe missing: '+JSON.stringify({reports, state:await page.evaluate(()=>({probe:window.__mikaFrameProbe, webkit:typeof window.webkit?.messageHandlers?.mikaFrameProbe?.postMessage, reports:top.__mikaReports}))}));
  const topDialog = topReport.dialogs.find(x => x.buttons.some(b => b.label === '写回答'));
  await page.evaluate(sig => window.postMessage({__mikaFrame:1,kind:'click',token:'bound-top',label:'写回答',targetIndex:7,targetTag:'button',targetFramePath:'top',dialogSig:sig,approved:true,keywords:[],maxActions:2,deadlineAt:Date.now()+20000}, '*'), topDialog.sig);
  await wait(2800);
  let counts = await page.evaluate(() => ({ topClicks, childClicks }));
  check(counts.topClicks > 0 && counts.childClicks === 0, 'selected top frame command never clicks same-label child frame');

  const beforeWrong = counts.topClicks;
  await page.evaluate(sig => window.postMessage({__mikaFrame:1,kind:'click',token:'wrong-index',label:'写回答',targetIndex:99,targetTag:'button',targetFramePath:'top',dialogSig:sig,approved:true,keywords:[],maxActions:2,deadlineAt:Date.now()+20000}, '*'), topDialog.sig);
  await wait(200);
  counts = await page.evaluate(() => ({ topClicks, childClicks }));
  const mismatch = await page.evaluate(() => top.__mikaReports.find(x => x.token === 'wrong-index'));
  check(counts.topClicks === beforeWrong && mismatch?.stage === 'target-binding-mismatch' && mismatch?.actionCount === 0,
        'target index/identity mismatch produces zero actions');

  await load(`<iframe srcdoc="<div role='dialog'><button onclick='window.closeClicks++'>关闭窗</button></div><script>closeClicks=0</script>"></iframe>`);
  reports = await probe({});
  const child = reports.find(x => x.path !== 'top');
  const childDialog = child.dialogs.find(x => x.buttons.some(b => b.label === '关闭窗'));
  await page.evaluate(({path,sig}) => {
    const token='cancelled-child';
    window.postMessage({__mikaFrame:1,kind:'click',token,label:'关闭窗',targetTag:'button',targetFramePath:path,dialogSig:sig,approved:true,keywords:[],maxActions:2,deadlineAt:Date.now()+20000}, '*');
    setTimeout(()=>window.postMessage({__mikaFrame:1,kind:'cancel',token}, '*'), 90);
  }, { path:child.path, sig:childDialog.sig });
  await wait(800);
  const late = await page.evaluate(() => document.querySelector('iframe').contentWindow.closeClicks);
  check(late === 0, 'cancelled sequence has no late click');

  await load(`<div role="dialog" style="position:fixed"><button data-mika-idx="8">写回答</button></div>`);
  reports = await probe({ targetIndex:8, targetLabel:'写回答', targetTag:'button' });
  const small = reports.find(x => x.path === 'top').dialogs.find(x => x.buttons.some(b => b.label === '写回答'));
  await page.evaluate(sig => { top.__mikaReports=[];window.postMessage({__mikaFrame:1,kind:'click',token:'no-mask',label:'写回答',targetIndex:8,targetTag:'button',targetFramePath:'top',dialogSig:sig,approved:true,keywords:[],maxActions:2,deadlineAt:Date.now()+20000}, '*'); }, small.sig);
  await wait(3000);
  const noMask = await page.evaluate(() => top.__mikaReports.find(x => x.token === 'no-mask'));
  check(noMask?.actionCount === 2 && !noMask?.stages.includes('mask-click'), 'missing mask is not recorded as mask-click');

  await load(`<div role="dialog"><div contenteditable="true">SECRET-EDITOR-CONTENT</div><button>关闭</button></div>`);
  reports = await probe({});
  check(!JSON.stringify(reports.flatMap(x => x.dialogs || [])).includes('SECRET-EDITOR-CONTENT'), 'contenteditable and ancestor text are redacted from evidence');

  await browser.close();
  const failed = checks.filter(x => !x.ok).length;
  console.log(JSON.stringify({ runtime:'Playwright Chromium (NOT WKWebView)', failed, checks }, null, 2));
  process.exitCode = failed ? 1 : 0;
})().catch(error => {
  console.error(error.stack || String(error));
  process.exitCode = 1;
});

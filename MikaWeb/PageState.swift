import Foundation
struct PageElement: Codable, Equatable {
    let index: Int
    let tag, type, text, placeholder, href, name, inputType, ariaLabel: String
    /// 可达名称来源（WECHAT-EDITOR-NAV A1）：text 的取值出处——text／
    /// aria-label／title／alt／label／placeholder／value／icon（内嵌 svg
    /// 的 title/aria/use 引用推导，EDITOR-ENTRY-BIND 补）／bg（背景图
    /// 文件名）／none（无名牌图标控件）。无文本控件不再因「无文字」在
    /// 抽取层消失，模型据来源判断这是什么入口。
    let nameSource: String
    /// 元素矩形是否与当前视口相交（WECHAT-EDITOR-NAV A2）：false 只表示
    /// 「在页面里但没进视口」，引擎点击前会先滚动揭示再复判，不得据此
    /// 断言入口不存在。位置相关字段：guardScript 的身份校验豁免它
    /// （滚动前后 legitimately 不同）。
    let inView: Bool
    let sensitive: Bool
    // 按钮「存在但被禁用（灰的）」与「不存在」是两种失败，须在快照层就分开（FIX2 案卷 d/c 项）
    let disabled: Bool
    // contenteditable 编辑器（知乎回复框一类）：页面重排后 index 与文本都不可靠，
    // 引擎按稳定描述重找时靠它圈定候选池（AGENT-VIEWPORT-FIX 案卷）
    let editable: Bool
}

extension PageElement {
    /// 链接类别（LADDER-FIX F5，计算属性、不落盘不进快照编码）：
    /// "edit"＝编辑入口链接（href 含 appmsg_edit）；"preview"＝带
    /// tempkey 的临时预览链接（点开是预览页、不是编辑器——草稿卡标
    /// 题多属此类，感知层不得把它当编辑入口候选交付，引擎点中时步
    /// 流另行标注）；其余 ""。判据只认 href 字面，与 harvest 侧的
    /// 预览排除（DirectTargetHarvest.isPreviewLink）同口径。
    var linkKind: String {
        if href.contains("appmsg_edit") { return "edit" }
        if DirectTargetHarvest.isPreviewLink(href) { return "preview" }
        return ""
    }
}
// 与 PageScript.extract 的 MAX_VISITED / MAX_CANDIDATES 同值。
enum ExtractionBudget {
    static let maxVisited = 2000
    static let maxCandidates = 256
}

struct Coverage: Codable, Equatable {
    let visited: Int
    let truncated: Bool
}

struct PageState: Codable {
    let url, title, text: String
    let elements: [PageElement]
    /// 浮动层诊断（EDITOR-ENTRY-BIND 第 4 项扩展，Joey 16:51 定性
    /// 「agent 读不到二级菜单」）：抽取时同 frame 内的菜单/弹窗类浮
    /// 动层清单（容器类名＋可见条目文本）——静态 DOM 之外的浮动层
    /// 是感知的系统性盲区，这份清单只作诊断证据（步流与感知文本
    /// 各留一行），不改变元素清单与点击语义。旧快照 JSON 无此键
    /// 时解码为空（decodeIfPresent）。
    var overlayNotes: [String] = []
    var coverage: Coverage?
    var coverageComplete: Bool { coverage?.truncated != true }
    enum CodingKeys: String, CodingKey {
        case url, title, text, elements
        case overlayNotes = "overlays"
        case coverage
    }
    init(url: String, title: String, text: String, elements: [PageElement], overlayNotes: [String] = [], coverage: Coverage? = nil) {
        self.url = url; self.title = title; self.text = text; self.elements = elements; self.overlayNotes = overlayNotes; self.coverage = coverage
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        elements = try c.decode([PageElement].self, forKey: .elements)
        overlayNotes = try c.decodeIfPresent([String].self, forKey: .overlayNotes) ?? []
        coverage = try c.decodeIfPresent(Coverage.self, forKey: .coverage)
    }
}
enum PageScript {
    static let extract = #"""
    (() => {
      // 与 PageState.swift ExtractionBudget 同值；名称读取采用已命名元素数上限 512。
      const MAX_VISITED=2000,MAX_CANDIDATES=256,MAX_NAMED=512;
      let visited=0,truncated=false,named=0;
      if(!document.body){return JSON.stringify({url:location.href,title:document.title||'',text:'',elements:[],coverage:{visited,truncated}});}
      const geometry=new WeakMap();
      const geo=e=>{let g=geometry.get(e);if(!g){g={rect:e.getBoundingClientRect(),style:getComputedStyle(e),rects:e.getClientRects()};geometry.set(e,g);}return g;};
      const visible=e=>{const g=geo(e);return g.rect.width>0&&g.rect.height>0&&g.style.visibility!=='hidden'&&g.style.display!=='none'};
      // 可达名称解析（WECHAT-EDITOR-NAV A1）：公众号编辑器一类的入口常是
      // 无文本图标控件（只有 aria-label／title／alt／背景图），旧抽取只认
      // innerText 一路，无名即丢弃——模型看不见入口、只能报「无可操作
      // 入口」。名源优先级：可见文本→aria-label→title→alt→关联 label→
      // placeholder→value（提交类 input 的值即其文案）→背景图文件名词干
      // （url(.../cover-entry.png)→「cover entry」）；全无则 source=none。
      // name 切 300 字与快照 text 口径一致。
      const nameOf=e=>{
        if(named<MAX_NAMED){named++;if(named===MAX_NAMED)truncated=true;const t=(e.innerText||'').trim();if(t)return{name:t.slice(0,300),source:'text'};}
        else truncated=true;
        const aria=(e.getAttribute('aria-label')||'').trim();if(aria)return{name:aria.slice(0,300),source:'aria-label'};
        const title=(e.title||'').trim();if(title)return{name:title.slice(0,300),source:'title'};
        const alt=(e.getAttribute('alt')||'').trim();if(alt)return{name:alt.slice(0,300),source:'alt'};
        const labs=[...(e.labels||[])].map(l=>{if(named>=MAX_NAMED){truncated=true;return '';}named++;if(named===MAX_NAMED)truncated=true;return(l.innerText||'').trim();}).filter(Boolean).join(' ');if(labs)return{name:labs.slice(0,300),source:'label'};
        const ph=(e.placeholder||'').trim();if(ph)return{name:ph.slice(0,300),source:'placeholder'};
        if((e.tagName==='INPUT'||e.tagName==='BUTTON')&&e.value){const v=String(e.value).trim();if(v)return{name:v.slice(0,300),source:'value'};}
        // 图标名推导（EDITOR-ENTRY-BIND）：只有内嵌 svg 的图标控件
        // （草稿卡编辑铅笔一类）——从 svg 的 <title>／aria-label／
        // <use> 引用名（如 #icon-edit →「edit」）／svg class 词干推
        // 导名字，推不出不编造、继续往下走 bg/none。
        const svg=e.querySelector?e.querySelector('svg'):null;
        if(svg){
          const stEl=svg.querySelector('title');const st=stEl?(stEl.textContent||'').trim():'';
          if(st)return{name:st.slice(0,300),source:'icon'};
          const sa=(svg.getAttribute('aria-label')||'').trim();if(sa)return{name:sa.slice(0,300),source:'icon'};
          const use=svg.querySelector('use');const uh=use?(use.getAttribute('href')||use.getAttribute('xlink:href')||''):'';
          const frag=(uh.split('#').pop()||'').replace(/^icon[-_]?/i,'').replace(/[-_]+/g,' ').trim();
          if(frag)return{name:frag.slice(0,300),source:'icon'};
          const sc=((svg.getAttribute('class')||'').trim().split(/\s+/)[0]||'').replace(/^icon[-_]?/i,'').replace(/[-_]+/g,' ').trim();
          if(sc)return{name:sc.slice(0,300),source:'icon'};
        }
        const bg=(geo(e).style.backgroundImage||'');
        const m=bg.match(/url\(["']?([^"')]+)["']?\)/);
        // data:/blob: 背景图没有文件名可读（data URI 的内容段会被误当名），
        // 只记名源 bg、名留空——元素仍在清单里，不编假名。
        if(m&&!/^(data|blob):/.test(m[1])){const file=m[1].split('/').pop().replace(/\.[a-z0-9]+$/i,'').replace(/[-_]+/g,' ').trim();return{name:file.slice(0,300),source:'bg'};}
        if(bg&&bg!=='none')return{name:'',source:'bg'};
        return{name:'',source:'none'};
      };
      // 与视口相交与否（A2）：只问窗口视口——内层滚动容器裁剪不在此判，
      // 可达性复判走引擎的揭示流程（滚动容器逐个滚动后再判）。判定用
      // getClientRects 任一矩形相交（内联元素多行矩形只取包围盒会误判），
      // 无矩形时回落包围盒——此法改编自 browser-use 的
      // isInExpandedViewport（buildDomTree.js，MIT License，
      // Copyright (c) 2024 Gregor Zunic；轮子盘点见本单案卷）。
      const inViewOf=e=>{const hit=r=>r.width>0&&r.height>0&&r.bottom>0&&r.right>0&&r.top<innerHeight&&r.left<innerWidth;const g=geo(e);for(const r of g.rects){if(hit(r))return true;}return g.rects.length?false:hit(g.rect);};
      const semSel='a,button,input,textarea,select,[role="button"],[contenteditable="true"]';
      const roleSel='[role="tab"],[role="link"],[role="menuitem"],[role="option"],[role="switch"],[role="checkbox"],[role="treeitem"],[onclick]';
      const baseSet=new Set();
      for(const e of document.querySelectorAll(semSel+','+roleSel)){
        if(visited>=MAX_VISITED||baseSet.size>=MAX_CANDIDATES){truncated=true;break;}
        visited++;
        if(visible(e)||(e.tagName==='INPUT'&&e.type==='file'))baseSet.add(e);
      }
      if(visited>=MAX_VISITED||baseSet.size>=MAX_CANDIDATES)truncated=true;
      // 非语义可点元素补盲（RESOURCEFULNESS）：活动页一类的「发微头条／写文章／拍视频」
      // 入口常是 div/span＋JS 绑定的非语义元素，不在语义选择器内——模型看不见、
      // 只能请用户手动点。补入判据（须同时满足，防噪声）：不在语义元素内部、
      // 也不包裹语义元素（真目标在内层时父级不重复列）；纯文本粗筛 ≤120 字；
      // 可见且尺寸 ≥12×12；交互证据＝cursor:pointer 或内联事件属性（见
      // 循环内注释）；且有可达名称（名源见 nameOf：文本／aria-label／
      // title／alt／背景图任一）或至少带背景图（图标形态，名可为空）或
      // 带内联事件属性——A1 修订：旧判据只认文本与 aria／title，
      // 纯图标入口（alt 图、背景图按钮）整类被滤掉，是编辑器入口盲区
      // 的主因；全无名源又无背景图无事件属性的透明热区无从指认，仍不入
      // （防噪声）。
      // 同类嵌套只留最内层（点击事件冒泡到父级处理器，点内层等效）。
      // 补入仍至多 200 条（去重前）；语义与补入共享候选总额。
      const scanSel='div,span,li,td,th,p,i,em,b,strong,img,section,article,nav,header,footer,figure,figcaption,dd,dt';
      const inViewExtras=[],outViewExtras=[],names=new Map();
      const extraLimit=Math.min(200,MAX_CANDIDATES-baseSet.size);
      for(const e of document.querySelectorAll(scanSel)){
        if(visited>=MAX_VISITED||inViewExtras.length>=extraLimit){truncated=true;break;}
        visited++;
        if(baseSet.has(e))continue;
        if(e.closest(semSel)||e.querySelector(semSel))continue;
        const cheap=(e.textContent||'').trim();
        if(cheap.length>120)continue;
        if(!visible(e))continue;
        const r=geo(e).rect;
        if(r.width<12||r.height<12)continue;
        // 交互证据（改编自 browser-use isInteractiveElement 的事件属性
        // 回退分支，buildDomTree.js，MIT License，Copyright (c) 2024
        // Gregor Zunic）：cursor:pointer 或带内联事件属性（onclick／
        // onmousedown／onmouseup，属性或 property 任一）任一成立即算
        // 可点——旧式后台页常给图标区只挂 onclick 不设 pointer 光标，
        // 只认光标会整类漏掉。它们的 getEventListeners 检测在
        // WKWebView 页面世界不可用（其源码注释亦承认），不移植。
        const hasEvt=e.hasAttribute('onclick')||typeof e.onclick==='function'||e.hasAttribute('onmousedown')||typeof e.onmousedown==='function'||e.hasAttribute('onmouseup')||typeof e.onmouseup==='function';
        if(geo(e).style.cursor!=='pointer'&&!hasEvt)continue;
        const nm=nameOf(e);
        // 图标准入（EDITOR-ENTRY-BIND）：内嵌 svg/img 图标本身就是
        // 形态证据——名字推导不出来（source=none）也入清单，模型与
        // 引擎至少看得见这个可点图标的存在（带 data-mika-idx 可点、
        // 点按按元素中心坐标派发）；全无名源、无背景图、无事件属
        // 性、又无图标的透明热区仍不入（防噪声口径不变）。
        const hasIcon=!!e.querySelector('svg,img');
        if(!nm.name&&nm.source!=='bg'&&!hasEvt&&!hasIcon)continue;
        if(nm.name.length>120)continue;
        if(inViewOf(e)){
          inViewExtras.push(e);names.set(e,nm);
          if(inViewExtras.length+outViewExtras.length>extraLimit){names.delete(outViewExtras.pop());truncated=true;}
        }else if(inViewExtras.length+outViewExtras.length<extraLimit){outViewExtras.push(e);names.set(e,nm);}
        else truncated=true;
      }
      if(visited>=MAX_VISITED||baseSet.size+inViewExtras.length+outViewExtras.length>=MAX_CANDIDATES||inViewExtras.length+outViewExtras.length>=200)truncated=true;
      const rawExtras=[...inViewExtras,...outViewExtras];
      const extraSet=new Set(rawExtras.filter(e=>!rawExtras.some(o=>o!==e&&e.contains(o))));
      const merged=[...baseSet,...extraSet].sort((x,y)=>{const p=x.compareDocumentPosition(y);return (p&4)?-1:(p&2)?1:0;});
      // 文件控件例外（F1）：input[type=file] 常被站点隐藏（display:none）再用
      // label/按钮冒充上传入口，可见性过滤会把上传点本身滤掉——文件控件
      // 数量天然稀少（通常 0–1 个），一律保留进清单，upload_file 据此定位。
      const elements=merged.map((e,index)=>{
        const nm=names.get(e)||nameOf(e);
        const labelText=[...(e.labels||[])].map(l=>{if(named>=MAX_NAMED){truncated=true;return '';}named++;if(named===MAX_NAMED)truncated=true;return l.innerText||'';}).join(' ');
        const hint=[e.type,e.name,e.id,e.placeholder,e.getAttribute('aria-label'),e.getAttribute('alt'),e.autocomplete,labelText].join(' ');
        return {index,tag:e.tagName.toLowerCase(),type:e.getAttribute('role')||e.type||(extraSet.has(e)?'clickable':e.tagName.toLowerCase()),text:nm.name,placeholder:e.placeholder||'',href:e.href||'',name:e.name||'',inputType:e.type||'',ariaLabel:e.getAttribute('aria-label')||'',nameSource:nm.source,inView:inViewOf(e),sensitive:/password|验证码|校验码|动态码|一次性|captcha|verification|verify|one.time|otp|security.code|(^|[ _-])(code|pin)($|[ _-])/i.test(hint),disabled:(e.disabled===true)||e.getAttribute('aria-disabled')==='true',editable:!!e.isContentEditable};
      });
      let text='',n;const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
      while((n=walker.nextNode())&&text.length<6000){if(n.parentElement&&!n.parentElement.closest('script,style,noscript')&&visible(n.parentElement))text+=n.textContent.trim()+' ';}
      // 浮动层盘点（EDITOR-ENTRY-BIND 诊断）：菜单/弹层类容器（role=
      // menu 或 class 含 menu/popover/dropdown/popup）在本 frame 内
      // 可见时，记容器类名与叶子条目文本——回答「点开二级菜单后，
      // 菜单项进没进感知、在哪一层」这个问题。菜单若在抽取时刻已
      // 自动关闭、或位于本脚本够不到的层（跨源 frame/原生层），
      // 这里就是空——空本身也是诊断结论，步流据此落 playbook 的
      // 固定布局坐标打法。只记结构与文本，不改元素清单。
      const overlayScan=()=>{const out=[];let nodes=[];try{nodes=Array.from(document.querySelectorAll('[role="menu"],[class*="menu"],[class*="Menu"],[class*="popover"],[class*="dropdown"],[class*="popup"],[class*="Popup"]'));}catch(e){}
        for(const nd of nodes){if(out.length>=4)break;const g=geo(nd);if(g.style.display==='none'||g.style.visibility==='hidden')continue;const r=g.rect;if(r.width===0||r.height===0)continue;
          const items=[];nd.querySelectorAll('li,a,button,[role="menuitem"],div,span').forEach(it=>{if(items.length>=8)return;if(it.children.length>0)return;const t=(it.textContent||'').trim().replace(/\s+/g,' ');if(t&&t.length<=24&&!items.includes(t))items.push(t);});
          const own=(nd.textContent||'').trim().replace(/\s+/g,' ').slice(0,80);
          out.push('主文档 frame·'+((nd.getAttribute('class')||nd.tagName||'').slice(0,50))+' → '+(items.length?items.join('／'):own));}
        return out;};
      const overlays=overlayScan();
      // 所有名称、几何、样式与正文读取完成后，统一更新索引；相同值不写。
      const indexed=document.querySelectorAll('[data-mika-idx]'),mergedSet=new Set(merged);
      for(const e of indexed){if(!mergedSet.has(e))e.removeAttribute('data-mika-idx');}
      merged.forEach((e,index)=>{const value=String(index);if(e.getAttribute('data-mika-idx')!==value)e.setAttribute('data-mika-idx',value);});
      return JSON.stringify({url:location.href,title:document.title,text:text.slice(0,6000),elements,overlays,coverage:{visited,truncated}});
    })()
    """#
}
/// 元素的稳定描述（AGENT-VIEWPORT-FIX）：模型选中的目标在页面重排／重渲染后 index 与
/// 节点身份都可能变化，能跨快照认人的只有这类不依赖位置的字段。引擎在目标失效时用它重找。
struct ElementDescriptor {
    let index: Int
    let tag, type, text, ariaLabel, placeholder, name, href, inputType: String
    let editable: Bool

    init(_ e: PageElement) {
        index = e.index; tag = e.tag; type = e.type; text = e.text
        ariaLabel = e.ariaLabel; placeholder = e.placeholder; name = e.name
        href = e.href; inputType = e.inputType; editable = e.editable
    }

    /// 同一目标的跨轮次同一性键（引擎记「同一动作同一原因连续失败」用）
    var key: String { "\(tag)|\(Self.norm(text))|\(Self.norm(ariaLabel))|\(href)" }

    static func norm(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// 按稳定描述在一份新快照里重找目标。原则：宁可找不到（交引擎走策略切换），不可认错人。
/// 1) 原 index 处元素与模型所见逐字段相等 → 就是它（无漂移快路径）；
/// 2) 候选池硬过滤：tag 相同；描述是 contenteditable 编辑器时，候选也必须是编辑器；
///    池里只有一个候选且快照完整 → 就是它；截断快照须有强身份匹配；
/// 3) 多候选时打分（文案／无障碍名／href／name／placeholder 全等加权，index 相同与
///    类型相同小加权），须唯一最高分且 ≥4 分，并列或低分一律判找不到。
enum TargetResolutionPolicy {
    static func acceptsLoneCandidate(coverageComplete: Bool, strongMatch: Bool) -> Bool {
        coverageComplete || strongMatch
    }
}

func resolveTarget(descriptor d: ElementDescriptor, original: PageElement, in elements: [PageElement], coverageComplete: Bool) -> PageElement? {
    if d.index >= 0, d.index < elements.count, elements[d.index] == original {
        return elements[d.index]
    }
    let pool = elements.filter { e in
        guard e.tag == d.tag else { return false }
        if d.editable { return e.editable }
        return true
    }
    guard !pool.isEmpty else { return nil }
    if pool.count == 1 {
        let e = pool[0]
        func same(_ lhs: String, _ rhs: String) -> Bool {
            !lhs.isEmpty && ElementDescriptor.norm(lhs) == ElementDescriptor.norm(rhs)
        }
        let strongMatch = same(d.text, e.text) || same(d.ariaLabel, e.ariaLabel)
            || same(d.placeholder, e.placeholder) || same(d.name, e.name)
            || (!d.href.isEmpty && d.href == e.href)
        return TargetResolutionPolicy.acceptsLoneCandidate(coverageComplete: coverageComplete, strongMatch: strongMatch) ? e : nil
    }
    func score(_ e: PageElement) -> Int {
        var s = 0
        if e.index == d.index { s += 2 }
        let dt = ElementDescriptor.norm(d.text), et = ElementDescriptor.norm(e.text)
        if !dt.isEmpty, et == dt { s += 4 }
        else if dt.count >= 2, !et.isEmpty, et.contains(dt) || dt.contains(et) { s += 2 }
        if !d.ariaLabel.isEmpty, ElementDescriptor.norm(e.ariaLabel) == ElementDescriptor.norm(d.ariaLabel) { s += 4 }
        if !d.href.isEmpty, e.href == d.href { s += 3 }
        if !d.name.isEmpty, e.name == d.name { s += 3 }
        if !d.placeholder.isEmpty, e.placeholder == d.placeholder { s += 3 }
        if !d.inputType.isEmpty, e.inputType == d.inputType { s += 1 }
        if d.editable, e.editable { s += 2 }
        if !d.type.isEmpty, e.type == d.type { s += 1 }
        return s
    }
    let scored = pool.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }
    guard let best = scored.first, best.1 >= 4 else { return nil }
    if scored.count > 1, scored[1].1 == best.1 { return nil }
    return best.0
}

struct MikaError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

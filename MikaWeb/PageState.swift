import Foundation
struct PageElement: Codable, Equatable {
    let index: Int
    let tag, type, text, placeholder, href, name, inputType, ariaLabel: String
    let sensitive: Bool
    // 按钮「存在但被禁用（灰的）」与「不存在」是两种失败，须在快照层就分开（FIX2 案卷 d/c 项）
    let disabled: Bool
    // contenteditable 编辑器（知乎回复框一类）：页面重排后 index 与文本都不可靠，
    // 引擎按稳定描述重找时靠它圈定候选池（AGENT-VIEWPORT-FIX 案卷）
    let editable: Bool
}
struct PageState: Codable {
    let url, title, text: String
    let elements: [PageElement]
}
enum PageScript {
    static let extract = #"""
    (() => {
      if(!document.body){return JSON.stringify({url:location.href,title:document.title||'',text:'',elements:[]});}
      document.querySelectorAll('[data-mika-idx]').forEach(e=>e.removeAttribute('data-mika-idx'));
      const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'};
      const semSel='a,button,input,textarea,select,[role="button"],[contenteditable="true"]';
      const roleSel='[role="tab"],[role="link"],[role="menuitem"],[role="option"],[role="switch"],[role="checkbox"],[role="treeitem"],[onclick]';
      const baseSet=new Set(document.querySelectorAll(semSel+','+roleSel));
      // 非语义可点元素补盲（RESOURCEFULNESS）：活动页一类的「发微头条／写文章／拍视频」
      // 入口常是 div/span＋JS 绑定的非语义元素，不在语义选择器内——模型看不见、
      // 只能请用户手动点。补入判据（须同时满足，防噪声）：不在语义元素内部、
      // 也不包裹语义元素（真目标在内层时父级不重复列）；有可读文案（纯文本粗筛
      // ≤120 字，再以 innerText／aria-label／title 复核）；可见且尺寸 ≥12×12；
      // 计算样式 cursor:pointer。同类嵌套只留最内层（点击事件冒泡到父级处理器，
      // 点内层等效）。补入上限 200 条（去重前），语义元素不受任何新门槛影响。
      const scanSel='div,span,li,td,th,p,i,em,b,strong,img,section,article,nav,header,footer,figure,figcaption,dd,dt';
      const rawExtras=[];
      for(const e of document.querySelectorAll(scanSel)){
        if(rawExtras.length>=200)break;
        if(baseSet.has(e))continue;
        if(e.closest(semSel)||e.querySelector(semSel))continue;
        const cheap=(e.textContent||'').trim();
        if(cheap.length>120)continue;
        if(!cheap&&!(e.getAttribute('aria-label')||'').trim()&&!(e.title||'').trim())continue;
        if(!visible(e))continue;
        const r=e.getBoundingClientRect();
        if(r.width<12||r.height<12)continue;
        const label=((e.innerText||'').trim()||(e.getAttribute('aria-label')||'').trim()||(e.title||'').trim());
        if(!label||label.length>120)continue;
        if(getComputedStyle(e).cursor!=='pointer')continue;
        rawExtras.push(e);
      }
      const extraSet=new Set(rawExtras.filter(e=>!rawExtras.some(o=>o!==e&&e.contains(o))));
      const merged=[...baseSet,...extraSet].sort((x,y)=>{const p=x.compareDocumentPosition(y);return (p&4)?-1:(p&2)?1:0;});
      const elements=merged.filter(visible).map((e,index)=>{
        e.setAttribute('data-mika-idx',index);
        const labelText=[...(e.labels||[])].map(l=>l.innerText||'').join(' ');
        const hint=[e.type,e.name,e.id,e.placeholder,e.getAttribute('aria-label'),e.autocomplete,labelText].join(' ');
        return {index,tag:e.tagName.toLowerCase(),type:e.getAttribute('role')||e.type||(extraSet.has(e)?'clickable':e.tagName.toLowerCase()),text:(e.innerText||labelText||e.getAttribute('aria-label')||e.getAttribute('title')||'').slice(0,300),placeholder:e.placeholder||'',href:e.href||'',name:e.name||'',inputType:e.type||'',ariaLabel:e.getAttribute('aria-label')||'',sensitive:/password|验证码|校验码|动态码|一次性|captcha|verification|verify|one.time|otp|security.code|(^|[ _-])(code|pin)($|[ _-])/i.test(hint),disabled:(e.disabled===true)||e.getAttribute('aria-disabled')==='true',editable:!!e.isContentEditable};
      });
      let text='',n;const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
      while((n=walker.nextNode())&&text.length<6000){if(n.parentElement&&!n.parentElement.closest('script,style,noscript')&&visible(n.parentElement))text+=n.textContent.trim()+' ';}
      return JSON.stringify({url:location.href,title:document.title,text:text.slice(0,6000),elements});
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
///    池里只有一个候选 → 就是它；
/// 3) 多候选时打分（文案／无障碍名／href／name／placeholder 全等加权，index 相同与
///    类型相同小加权），须唯一最高分且 ≥4 分，并列或低分一律判找不到。
func resolveTarget(descriptor d: ElementDescriptor, original: PageElement, in elements: [PageElement]) -> PageElement? {
    if d.index >= 0, d.index < elements.count, elements[d.index] == original {
        return elements[d.index]
    }
    let pool = elements.filter { e in
        guard e.tag == d.tag else { return false }
        if d.editable { return e.editable }
        return true
    }
    guard !pool.isEmpty else { return nil }
    if pool.count == 1 { return pool[0] }
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

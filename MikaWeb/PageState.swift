import Foundation
struct PageElement: Codable, Equatable {
    let index: Int
    let tag, type, text, placeholder, href, name, inputType, ariaLabel: String
    let sensitive: Bool
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
      const elements=[...document.querySelectorAll('a,button,input,textarea,select,[role="button"],[contenteditable="true"]')].filter(visible).map((e,index)=>{
        e.setAttribute('data-mika-idx',index);
        const labelText=[...(e.labels||[])].map(l=>l.innerText||'').join(' ');
        const hint=[e.type,e.name,e.id,e.placeholder,e.getAttribute('aria-label'),e.autocomplete,labelText].join(' ');
        return {index,tag:e.tagName.toLowerCase(),type:e.getAttribute('role')||e.type||e.tagName.toLowerCase(),text:(e.innerText||labelText||e.getAttribute('aria-label')||'').slice(0,300),placeholder:e.placeholder||'',href:e.href||'',name:e.name||'',inputType:e.type||'',ariaLabel:e.getAttribute('aria-label')||'',sensitive:/password|验证码|校验码|动态码|一次性|captcha|verification|verify|one.time|otp|security.code|(^|[ _-])(code|pin)($|[ _-])/i.test(hint)};
      });
      let text='',n;const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
      while((n=walker.nextNode())&&text.length<6000){if(n.parentElement&&!n.parentElement.closest('script,style,noscript')&&visible(n.parentElement))text+=n.textContent.trim()+' ';}
      return JSON.stringify({url:location.href,title:document.title,text:text.slice(0,6000),elements});
    })()
    """#
}
struct MikaError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

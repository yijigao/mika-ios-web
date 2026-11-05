// Embedded after vendored React 17 / Draft.js 0.11.7. Only CRLF/CR -> LF normalization.
const React = Du.default, ReactDOM = VC.default, Draft = Ki;
const normalize = s => s.replace(/\r\n?/g, '\n');
const countText = s => s.replace(/\s/g, '').length; // Fixture counter: UTF-16 non-whitespace units.
const hop = (n, status, detail = {}) => window.__mikaTypeNote?.(n, status, detail);
const instances = new Map();
// Keep the original append-only window.error count; enrich identity without suppressing anything.
window.__type4Errors = [];
window.__type4UnhandledRejections = [];
window.__type4ExceptionContext = {case:'fixture-bootstrap', phase:'fixture-bootstrap'};
window.__type4SetExceptionContext = (caseName, phase) => { window.__type4ExceptionContext = {case:caseName, phase}; };
const exceptionIdentity = (kind, error, identity) => ({
  kind, ...identity, name:typeof error?.name === 'string' ? error.name : null,
  stack:typeof error?.stack === 'string' ? error.stack : null,
  context:{...window.__type4ExceptionContext}, strategy:window.__mikaTypeAttempt?.strategy || null,
  mode:window.__mode || null, documentURL:location.href, capturedAt:new Date().toISOString(), monotonicMs:performance.now()
});
window.addEventListener('error', event => {
  window.__type4Errors.push(exceptionIdentity('window.error', event.error, {
    message:typeof event.message === 'string' ? event.message : null,
    filename:typeof event.filename === 'string' ? event.filename : null,
    lineno:event.lineno ?? null, colno:event.colno ?? null,
    resourceURL:event.target?.src || event.target?.href || null
  }));
});
window.addEventListener('unhandledrejection', event => {
  const reason = event.reason;
  // Store separately: only the ignored-handler hygiene gate consumes this added channel.
  window.__type4UnhandledRejections.push(exceptionIdentity('unhandledrejection', reason, {
    message:typeof reason?.message === 'string' ? reason.message : typeof reason === 'string' ? reason : String(reason),
    filename:null, lineno:null, colno:null, resourceURL:null
  }));
});
window.__type4ExceptionReport = (nativeErrors = []) => {
  // No error has a proven unrelated origin yet. No message/filename/phase allowlist.
  const entries = [...window.__type4Errors, ...window.__type4UnhandledRejections, ...nativeErrors].map(error => ({
    ...error, classification:'unclassified-counted', counted:true, exclusionBasis:null
  }));
  return {policy:'fail-unless-proven-unrelated-and-causally-independent', counted:entries.length, excluded:[], entries};
};
const element = (name, id = 'primary') => document.getElementById(id === 'primary' ? name : name + '-secondary');
const fault = (kind, text) => {
  const evidence = {kind, fullTextEqual: text === window.__expected, strategy: window.__mikaTypeAttempt?.strategy};
  window.__faultEvidence.push(evidence);
  hop(2, 'ignored-handler', evidence);
};
class Type4Editor extends React.Component {
  constructor(props) {
    super(props);
    const content = props.raw ? Draft.convertFromRaw(props.raw) : Draft.ContentState.createFromText(props.text);
    this.state = {editorState: Draft.EditorState.createWithContent(content)};
    instances.set(props.id, this);
  }
  publish = () => {
    const id = this.props.id;
    const text = this.state.editorState.getCurrentContent().getPlainText('\n');
    if(id === 'primary') {
      window.__stateText = text; window.__stateCount = countText(text);
      window.__sel = this.state.editorState.getSelection().toJS();
    }
    hop(4, 'committed', {editor:id, fullTextEqual: normalize(text) === normalize(window.__expected || ''), length:text.length});
    element('count', id).textContent = String(countText(text));
    hop(5, 'counter-updated', {editor:id, count:countText(text), matchesCommitted:element('count', id).textContent === String(countText(text))});
    const ed = element('root', id).querySelector('[contenteditable=true]');
    if(ed) {
      ed.setAttribute('data-mika-slot', id);
      if(!ed.hasAttribute('data-mika-idx')) ed.setAttribute('data-mika-idx', id === 'primary' ? '7' : '8');
    }
    window.__ready = true;
  };
  componentDidMount() { this.publish(); }
  componentDidUpdate() { this.publish(); }
  onChange = next => {
    const text = next.getCurrentContent().getPlainText('\n');
    hop(3, 'generated', {editor:this.props.id, fullTextEqual:normalize(text) === normalize(window.__expected || ''), length:text.length});
    if(window.__mode === 'reject') {
      hop(4, 'application-rejected', {fullTextEqual:text === window.__expected});
      window.__faultEvidence.push({kind:'application-rejected', fullTextEqual:text === window.__expected});
      return;
    }
    element('savestate', this.props.id).textContent = '草稿保存中';
    this.setState({editorState:next}, () => { element('savestate', this.props.id).textContent = '草稿已保存'; });
  };
  render() {
    return React.createElement(Draft.Editor, {
      editorState:this.state.editorState, onChange:this.onChange,
      handlePastedText: (text, html) => {
        hop(2, 'framework-handler', {editor:this.props.id, fullTextEqual:text === window.__expected, htmlPresent:!!html});
        if(window.__mode === 'ignore') { fault('paste', text); return 'handled'; }
        return 'not-handled';
      },
      handleBeforeInput: text => {
        hop(2, 'framework-handler', {editor:this.props.id, length:text.length, fullTextEqual:text === window.__expected});
        if(window.__mode === 'ignore') { fault('beforeinput', text); return 'handled'; }
        return 'not-handled';
      }
    });
  }
}
const mount = (id, text, raw) => {
  ReactDOM.unmountComponentAtNode(element('root', id));
  element('savestate', id).textContent = '草稿已保存';
  ReactDOM.render(React.createElement(Type4Editor, {id, text, raw}), element('root', id));
};
window.__type4 = {
  reset(text = '', mode = '', expected = '') {
    window.__ready = false; window.__mikaTypeNote = undefined; window.__mikaTypeAttempt = undefined;
    const secondary = document.getElementById('editor-secondary');
    if(secondary) { ReactDOM.unmountComponentAtNode(element('root','secondary')); secondary.remove(); instances.delete('secondary'); }
    window.__mode = mode; window.__expected = expected; window.__updateCalls = 0; window.__faultEvidence = [];
    mount('primary', text);
  },
  dual(primary, secondary, expected) {
    this.reset(primary, '', expected);
    const section = document.createElement('section');
    section.id = 'editor-secondary'; section.setAttribute('data-editor-root','');
    section.innerHTML = '<div id="root-secondary"></div><p>字数：<span id="count-secondary">0</span></p><p id="savestate-secondary">草稿已保存</p>';
    document.body.appendChild(section);
    mount('secondary', secondary);
  },
  text(id = 'primary') { return instances.get(id).state.editorState.getCurrentContent().getPlainText('\n'); },
  assert(expected, id = 'primary') {
    const committed = this.text(id);
    return normalize(committed) === normalize(expected) &&
      (id !== 'primary' || window.__stateText === committed) &&
      element('count',id).textContent === String(countText(committed)) &&
      (expected.length === 0 || countText(committed) > 0);
  },
  rerender() { instances.get('primary').forceUpdate(); },
  savePayload() {
    // Independent string storage. Restore must parse this payload, never the current EditorState.
    const payload = JSON.stringify(Draft.convertToRaw(instances.get('primary').state.editorState.getCurrentContent()));
    sessionStorage.setItem('mika-type4-saved-raw', payload);
    return {bytes:payload.length, storage:'sessionStorage', format:'Draft.convertToRaw/JSON'};
  },
  clearForRestore() { this.reset('', '', window.__expected); return this.assert(''); },
  restorePayload() {
    const payload = sessionStorage.getItem('mika-type4-saved-raw');
    if(!payload) throw new Error('Missing independent saved payload');
    mount('primary', '', JSON.parse(payload));
  }
};
// Fault wrapper consumes beforeinput before React's listener. Receipt is independently recorded.
document.getElementById('root').addEventListener('beforeinput', e => {
  if(window.__mode === 'ignore') { fault('beforeinput-wrapper', e.data); e.preventDefault(); e.stopPropagation(); }
}, true);
document.getElementById('root').addEventListener('input', e => {
  if(window.__mode === 'ignore') e.stopPropagation();
}, true);
document.getElementById('update').addEventListener('click', () => { window.__updateCalls++; });
window.__type4.reset('知乎专栏旧正文段落文字用于占位计数验证编号'.repeat(6).slice(0,102));

import {derive,restore,encrypt,decrypt,randomSalt} from './crypto.js';
const $=id=>document.getElementById(id);
let csrf=document.querySelector('meta[name="tnotes-csrf"]').content;
const names={note:'备忘录',prompt:'AI 提示词',password:'账号密码',todo:'待办',config:'配置'};
const icons={note:'sticky-note',prompt:'sparkles',password:'key-round',todo:'list-checks',config:'file-code'};
const refreshIcons=()=>globalThis.lucide?.createIcons();
const fields=['title','body','tag','account','password','site','note','lang'];
let config={},cache={version:0,data:null},keys=null,token=null,plain=new Map(),selected=null;
let createMode=false,filter='all',quickFilter='all',dirty=false,pinned=false,library=false,editing=false,busy=true,remembered=false,clipboardTimer;
let restoring=null,noticeTimer,lastSyncError='',todoTag='';
let serial=Promise.resolve();
// 'info' fades by itself; 'keep' and 'error' stay until clicked so results and failures are not missed.
// Errors go to the error log instead of covering the page (see logError). An open dialog covers the rest of the page and
// makes it unclickable, so there a message, errors included, joins the end of the dialog.
function notice(text,level='info',kind='save'){
 const box=$('notice'),dialog=document.querySelector('dialog[open]');
 if(level==='error'&&text){logError(text,kind);if(!dialog)return;}
 clearTimeout(noticeTimer);
 const host=dialog||document.body;if(box.parentElement!==host)host.append(box);
 box.textContent=text;box.classList.toggle('error',level==='error'&&!!text);box.classList.toggle('show',!!text);
 if(text&&dialog)box.scrollIntoView({block:'nearest'});
 if(text&&level==='info')noticeTimer=setTimeout(()=>notice(''),2600);
}
// The error log: the footer shows how many errors are still open and opens the list, newest first. A later successful
// save strikes out the errors before it; a sync failure is struck out by a later successful sync. It is kept in this
// window's browser storage (the messages only, never record content), the newest 100.
const errorKey='tnotes-error-log';let errorLog=[];
try{const saved=JSON.parse(localStorage.getItem(errorKey)||'[]');if(Array.isArray(saved))errorLog=saved.filter(e=>e&&typeof e.text==='string'&&Number.isFinite(e.at)).slice(0,100);}catch{}
function keepErrors(){try{localStorage.setItem(errorKey,JSON.stringify(errorLog));}catch{}showErrors();}
function logError(text,kind){errorLog.unshift({at:Date.now(),text,kind});errorLog.length=Math.min(errorLog.length,100);keepErrors();}
function settleErrors(kind){
 let changed=false;const now=Date.now();
 for(const e of errorLog)if(!e.done&&(kind==='sync')===(e.kind==='sync')){e.done=now;changed=true;}
 if(changed)keepErrors();
}
function showErrors(){
 const open=errorLog.filter(e=>!e.done).length,button=$('error-log');
 button.hidden=!errorLog.length;button.classList.toggle('open',open>0);button.querySelector('span').textContent=open?open+' 个错误':'错误日志';
 if($('error-dialog').open)drawErrors();
}
function drawErrors(){
 const list=$('error-list');list.replaceChildren();
 if(!errorLog.length){const empty=document.createElement('p');empty.className='muted';empty.textContent='没有错误';list.append(empty);}
 for(const e of errorLog){
  const item=document.createElement('li'),time=document.createElement('time'),text=document.createElement('span');
  item.classList.toggle('done',!!e.done);time.textContent=shortTime(e.at);text.textContent=e.text;item.append(time,text);
  if(e.done){const note=document.createElement('small');note.textContent='已于 '+shortTime(e.done)+(e.kind==='sync'?' 同步成功':' 保存成功');item.append(note);}
  list.append(item);
 }
}
const channel=new BroadcastChannel('tnotes-cache');
function exclusive(task){const next=serial.then(task,task);serial=next.catch(()=>{});return next;}
async function api(url,options={}) {
 const body=options.body?JSON.stringify(options.body):undefined;
 for(let attempt=0;attempt<2;attempt++){
  const headers={'X-TNotes-CSRF':csrf,...options.headers};
  if(token)headers.Authorization='Bearer '+token;
  if(body)headers['Content-Type']='application/json';
  // "transient" marks failures worth retrying: the backend not answering yet, or failing for a moment.
  let res;try{res=await fetch(url,{...options,body,headers});}catch{throw Object.assign(Error('本机后台暂时无法连接，当前未保存的修改仍保留在窗口中。'),{transient:true});}
  let data;try{data=await res.json();}catch{throw Object.assign(Error('服务返回了无法识别的响应'),{transient:true});}
  // Rejected before dispatch: refreshing this token cannot duplicate a write.
  if(res.status===403&&data.code==='LOCAL_SESSION_STALE'&&attempt===0){
   const bootstrap=await fetch('/api/bootstrap',{cache:'no-store'});
   if(!bootstrap.ok)throw Error('本地连接无法恢复，请从 T 按钮重新打开');
   const fresh=await bootstrap.json();
   if(typeof fresh.csrf!=='string'||!/^[a-f0-9]{64}$/.test(fresh.csrf))throw Error('本地服务校验失败，请重新打开');
   csrf=fresh.csrf;continue;
  }
  if(!res.ok){const e=Error(data.error||'操作失败');e.status=res.status;e.transient=res.status>=500;throw e;}return data;
 }
}
async function persist(){
 const result=await api('/api/cache',{method:'PUT',body:cache});cache.version=result.version;
 channel.postMessage({version:cache.version});
}
function profile(){return cache.data.profile;}
function status(text){$('sync-label').textContent=text;}
function pending(){return cache.data?.items.filter(x=>x.pending).length||0;}
async function decryptAll(items){const next=new Map();for(const item of items){const value=await decrypt(keys.key,profile().id,item.id,item.envelope);next.set(item.id,value);}return next;}
async function loginRemote(){
 if(!cache.data.enrolled){
  let remoteProfile;
  try{remoteProfile=await api('/v1/profile?name='+encodeURIComponent(profile().name));}
  catch(e){if(e.status!==404)throw e;}
  if(remoteProfile&&remoteProfile.id!==profile().id)throw Error('服务器已有同名资料库，本机数据未上传。请保留本机备份后联系管理员。');
  if(!remoteProfile){if(!config.enrollment)throw Error('需要这台电脑的首次初始化授权才能创建服务器资料库');await api('/v1/register',{method:'POST',body:{...profile(),auth:keys.auth}});config.enrollment=false;}
  cache.data.enrolled=true;await persist();
 }
 token=(await api('/v1/login',{method:'POST',body:{name:profile().name,auth:keys.auth}})).token;
}
async function syncInner(manual=false,retried=false){
 if(!keys)return;
 // Without a server there is nothing to retry and nothing wrong: the encrypted local copy is the vault.
 if(!config.remote){status('已加密保存在本机 · 未配置同步服务器');return;}
 status('同步中…');
 try {
  if(!token)await loginRemote();
  const remote=(await api('/v1/records')).items;
  const remoteMap=new Map(remote.map(r=>[r.id,r]));let conflicts=0;
  for(const item of [...cache.data.items].filter(r=>r.pending)) {
   const other=remoteMap.get(item.id);
   if(other&&other.envelope.iv===item.envelope.iv&&other.envelope.data===item.envelope.data){item.rev=other.rev;item.pending=false;continue;}
   let candidate=item;
   if((other&&other.rev!==item.rev)||(!other&&item.rev!==0)){
    const value={...plain.get(item.id),title:plain.get(item.id).title+'（冲突副本）',deleted:false,updated:Date.now()};
    const id=crypto.randomUUID();candidate={id,rev:0,pending:true,envelope:await encrypt(keys.key,profile().id,id,value)};
    cache.data.items.push(candidate);plain.set(id,value);item.pending=false;conflicts++;
    if(other){Object.assign(item,other);plain.set(item.id,await decrypt(keys.key,profile().id,item.id,other.envelope));}
    await persist();
   }
   try {const result=await api('/v1/records',{method:'PUT',body:{id:candidate.id,base:candidate.rev,envelope:candidate.envelope}});candidate.rev=result.rev;candidate.pending=false;}
   catch(e){if(e.status!==409)throw e;}
   await persist();
  }
  const incoming=(await api('/v1/records')).items;
  // Verify authentication tags before accepting remote records into the local cache.
  const verified=await decryptAll(incoming);
  // A change still being saved in the background is newer than anything the server has.
  for(const item of incoming){const local=cache.data.items.find(x=>x.id===item.id);if(local?.pending||unsaved.has(item.id))continue;if(local)Object.assign(local,item,{pending:false});else cache.data.items.push({...item,pending:false});plain.set(item.id,verified.get(item.id));}
  cache.data.lastSync=Date.now();await persist();
  if(!editing){if(selected&&plain.has(selected))loadEditor(selected,false,!document.body.classList.contains('quick-list'));else openDefaultRecord();}
  renderList();lastSyncError='';settleErrors('sync');
  status(pending()?String(pending())+' 条等待同步':'已同步 · '+new Date().toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}));
  if(conflicts)notice('已保留 '+conflicts+' 个冲突副本，请在资料库中核对。','keep');
 } catch(e){
  if(e.status===401){token=null;if(!retried)return syncInner(manual,true);}
  status(pending()?'离线 · '+pending()+' 条待同步':'同步未完成');
  // The background check repeats every 30 seconds; show an unchanged failure again only when the user asked for a sync.
  if(manual||e.message!==lastSyncError)notice(e.message,'error','sync');
  lastSyncError=e.message;
 }
}
const sync=(manual=false)=>exclusive(()=>syncInner(manual));
function setIcon(button,name,label){
 if(button.dataset.icon===name)return;
 const symbol=document.createElement('i');symbol.dataset.lucide=name;button.dataset.icon=name;
 const parts=[symbol];if(label){const text=document.createElement('span');text.textContent=label;parts.push(text);}
 button.replaceChildren(...parts);
}
function markDirty(){dirty=true;$('edited').textContent='未保存的修改';}
function updateKind(){
 const kind=$('kind').value,secret=kind==='password',config=kind==='config';
 $('secret-fields').hidden=!secret;$('prompt-tools').hidden=kind!=='prompt';
 $('body-label').textContent=config?'配置内容':secret||kind==='todo'?'备注':'内容';$('password').type='password';
 // A config is typed as code: a fixed-width font, no wrapping and no spell check, with its format and 说明 around it.
 $('format-row').hidden=!config;$('note-row').hidden=!config;$('body').classList.toggle('code',config);$('body').spellcheck=!config;
 $('body').placeholder=config?'粘贴配置或代码，注释照常写在里面':'记录你的想法…';formatHint();
 // Editing a to-do, the tag box suggests the tags to-dos have used.
 if(kind==='todo')$('tag').setAttribute('list','todo-tag-list');else $('tag').removeAttribute('list');
}
// 自动识别 says which format it sees in what has been typed so far.
function formatHint(){
 const code=$('kind').value==='config'?$('body').value:'';
 $('lang').options[0].textContent='自动识别'+(code.trim()?' · '+formatNames[detectLang(code)]:'');
}
// Editing keeps when a record was added and whether (and when) a to-do was done; the form has no fields for them.
function recordFromForm(){
 const kind=$('kind').value,previous=selected?plain.get(selected)||{}:{},done=kind==='todo'&&!!previous.done;
 return {kind,title:$('title').value.trim()||'未命名记录',body:$('body').value,tag:$('tag').value.trim(),pinned,account:$('account').value,password:$('password').value,site:$('site').value,note:$('note').value,lang:$('lang').value,created:selected?previous.created:Date.now(),done,doneAt:done?previous.doneAt:undefined,deleted:false,updated:Date.now()};
}
// 今天 14:30, 昨天 14:30, 11月24日 14:30, or 2025年11月24日 for other years.
function shortTime(ms){
 const d=new Date(ms),now=new Date(),day=x=>new Date(x.getFullYear(),x.getMonth(),x.getDate()).getTime();
 const hm=String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0'),days=Math.round((day(now)-day(d))/86400000);
 if(days===0)return '今天 '+hm;if(days===1)return '昨天 '+hm;
 return d.getFullYear()===now.getFullYear()?(d.getMonth()+1)+'月'+d.getDate()+'日 '+hm:d.getFullYear()+'年'+(d.getMonth()+1)+'月'+d.getDate()+'日';
}
function todoTime(r){return r.done?'完成于 '+shortTime(r.doneAt||r.updated):shortTime(r.created||r.updated);}
function orderedRecords(){return [...plain].sort((a,b)=>Number(b[1].pinned)-Number(a[1].pinned)||b[1].updated-a[1].updated);}
function isRecordKind(value){return Object.prototype.hasOwnProperty.call(names,value);}
function finished(r){return r.kind==='todo'&&!!r.done;}
// To-dos and configs are features of their own: each shows only under its own category (and in the trash), never in
// 全部, 已置顶 or their search.
const separateKinds=new Set(['todo','config']);
function inCategory(r,category){return category==='trash'||(separateKinds.has(category)?r.kind===category:!separateKinds.has(r.kind));}
// Passwords are deliberately not searchable; everything else a record shows is.
function matches(r,query){return !query||[r.title,r.body,r.note,r.account,r.tag,r.site].join(' ').toLowerCase().includes(query);}
function promptVariables(template){return [...new Set([...(template||'').matchAll(/\{\{([^{}]+)\}\}/g)].map(m=>m[1]))];}
function categorySelection(value){filter=value;quickFilter=value==='trash'?'all':value;}
function syncCategoryButtons(){
 for(const [selector,current,field] of [['[data-filter]',filter,'filter'],['[data-quick-filter]',quickFilter,'quickFilter']]){
  document.querySelectorAll(selector).forEach(button=>{const active=button.dataset[field]===current;button.classList.toggle('active',active);button.setAttribute('aria-pressed',String(active));});
 }
}
function libraryRecords(){
 const query=$('search').value.trim().toLowerCase(),tag=$('tag-filter').value.trim().toLowerCase();
 return orderedRecords().filter(([,r])=>(filter==='trash'?r.deleted:!r.deleted)&&(filter==='all'||filter==='trash'||r.kind===filter||(filter==='pinned'&&r.pinned))&&inCategory(r,filter)&&(filter!=='todo'||!todoTag||r.tag===todoTag)&&(!tag||(r.tag||'').toLowerCase().includes(tag))&&matches(r,query));
}
function chooseCategory(value){
 const draft=editing&&selected===null;
 if(library&&editing&&!draft&&!mayLeave())return;
 categorySelection(value);
 if(draft&&isRecordKind(value)){
  if($('kind').value!==value){$('kind').value=value;markDirty();}
  updateKind();
 }else if(library&&!draft){openDefaultRecord();}
 renderList();rememberPlace();
 // Opening 待办 is usually to jot one down.
 if(value==='todo'&&!draft)$(library?'todo-title-library':'todo-title-quick').focus({preventScroll:true});
}
function setEditing(value){
 editing=value;$('edit-fields').hidden=!value;$('record-view').hidden=value;
 $('kind').hidden=!value;$('kind-label').hidden=value;$('edit').hidden=value;
 $('edit').disabled=!selected||!!plain.get(selected)?.deleted;
 $('pin').disabled=!selected&&!value;$('copy').disabled=!selected&&!value;
 $('delete').disabled=!selected;$('save').disabled=!!plain.get(selected)?.deleted;
 // In the trash this button brings the record back, so it must not look like a second delete.
 const gone=!!plain.get(selected)?.deleted,label=gone?'恢复记录':'移到回收站';
 $('delete').title=label;$('delete').setAttribute('aria-label',label);setIcon($('delete'),gone?'undo-2':'trash-2',gone?'恢复':'删除');
 // A to-do gets a done button in place of copy.
 const todo=plain.get(selected)?.kind==='todo';
 $('done').hidden=value||!todo;$('done').disabled=!todo||gone;$('copy').hidden=todo&&!value;
}
function showViewer(){
 const r=plain.get(selected);
 $('empty-record').hidden=!!r;$('read-content').hidden=!r;
 if(!r){$('kind-label').textContent='备忘录';$('edited').textContent='';$('prompt-tools').hidden=true;return;}
 $('kind-label').textContent=names[r.kind]||'记录';
 // A config shows its code coloured, with line numbers, and its 说明 under it in place of the body.
 const config=r.kind==='config';$('read-config').hidden=!config||!r.body;
 if(config&&r.body){const format=formatOf(r);$('read-format').textContent=formatNames[format];$('read-format').title=r.lang?'格式':'自动识别的格式，编辑时可以改';$('read-lines').textContent=renderCode($('read-code'),r.body,format)+' 行';}
 else $('read-code').replaceChildren();
 renderLinked($('read-title'),r.title);renderRich($('read-body'),config?r.note||'':r.body||'');$('read-body').classList.toggle('config-note',config);
 $('read-tag').textContent=r.tag||'';$('read-secret').hidden=r.kind!=='password';
 $('read-account').textContent=r.account||'';$('view-password').value=r.password||'';
 $('view-password').type='password';renderSite($('read-site'),r.site||'');
 $('read-site-row').hidden=!r.site;$('prompt-tools').hidden=r.kind!=='prompt';
 $('read-title').classList.toggle('done',finished(r));
 const when=r.kind==='todo'?'添加于 '+shortTime(r.created||r.updated)+(r.done?' · '+todoTime(r):''):(r.deleted?'':'更新于 ')+shortTime(r.updated);
 $('edited').textContent=(r.deleted?'已移到回收站 · ':'')+when;$('read-when').textContent=$('edited').textContent;
 if(r.kind==='todo'){
  const label=r.done?'标为未完成':'标记完成';$('done').title=label;$('done').setAttribute('aria-label',label);
  $('done').setAttribute('aria-pressed',String(!!r.done));setIcon($('done'),r.done?'circle-check':'circle',r.done?'已完成':'完成');
 }
}
function resetEditor(){
 document.body.classList.remove('quick-list');
 const category=library?filter:quickFilter;
 if(category==='trash')categorySelection('all');
 selected=null;$('kind').value=isRecordKind(category)?category:'note';for(const id of fields)$(id).value='';
 if($('kind').value==='todo')$('tag').value=todoTag;
 pinned=false;$('pin').setAttribute('aria-pressed','false');$('edited').textContent='新建记录';
 dirty=false;updateKind();setEditing(true);renderList();$('title').focus();
}
function loadEditor(id,edit=false,open=true){
 const r=plain.get(id);if(!r)return;selected=id;
 document.body.classList.toggle('quick-list',!open);
 for(const field of fields)$(field).value=r[field]||'';
 $('kind').value=r.kind;pinned=!!r.pinned;$('pin').setAttribute('aria-pressed',String(pinned));
 dirty=false;updateKind();setEditing(edit&&!r.deleted);showViewer();renderList();
 try{localStorage.setItem('tnotes-last-viewed',id);}catch{}
 rememberPlace();fitReadingWindow();
}
// Where the user left off: quick list or library, the categories, the selected record, whether it was open, and
// how far each list was scrolled. Only record ids and category names are kept, in this window's own browser
// storage; never any record content. It is put back after every login, including the automatic one.
const placeKey='tnotes-place',listScroll={quick:0,library:0};let placeTimer;
function rememberPlace(){
 if(!keys)return;
 const place={library,filter,quickFilter,todoTag,selected,open:!document.body.classList.contains('quick-list'),scroll:listScroll};
 try{localStorage.setItem(placeKey,JSON.stringify(place));}catch{}
}
function rememberPlaceSoon(){clearTimeout(placeTimer);placeTimer=setTimeout(rememberPlace,300);}
function restoreScroll(){
 const list=library?$('record-list'):$('recent-list'),top=library?listScroll.library:listScroll.quick;
 if(top)requestAnimationFrame(()=>{list.scrollTop=top;});
}
function restorePlace(){
 let place=null;try{place=JSON.parse(localStorage.getItem(placeKey)||'null');}catch{}
 if(!place||typeof place!=='object'){openDefaultRecord();return;}
 const known=value=>typeof value==='string'&&(isRecordKind(value)||['all','pinned','trash'].includes(value));
 if(known(place.filter))filter=place.filter;
 if(known(place.quickFilter)&&place.quickFilter!=='trash')quickFilter=place.quickFilter;
 if(typeof place.todoTag==='string')setTodoTag(place.todoTag);
 for(const view of ['quick','library'])if(Number.isFinite(place.scroll?.[view]))listScroll[view]=place.scroll[view];
 if(typeof place.selected==='string'&&plain.has(place.selected))selected=place.selected;
 if(place.library===true&&!library)setView(true);
 openDefaultRecord();
 // In the quick view a record that was open is opened again; otherwise the list shows with it selected.
 if(!library&&place.open&&selected&&plain.has(selected)&&!plain.get(selected).deleted)loadEditor(selected,false,true);
 else restoreScroll();
}
function openDefaultRecord(){
 let previous;try{previous=localStorage.getItem('tnotes-last-viewed');}catch{}
 const candidates=library?libraryRecords():orderedRecords().filter(([,r])=>!r.deleted&&inCategory(r,quickFilter));
 const available=new Set(candidates.map(([id])=>id));
 const wanted=available.has(selected)?selected:available.has(previous)?previous:candidates[0]?.[0];
 if(wanted){loadEditor(wanted,false,false);return;}
 selected=null;for(const id of fields)$(id).value='';pinned=false;dirty=false;
 $('pin').setAttribute('aria-pressed','false');setEditing(false);showViewer();if(library&&isRecordKind(filter))$('kind-label').textContent=names[filter];document.body.classList.add('quick-list');renderList();fitReadingWindow();
}
function mayLeave(){return !dirty||confirm('当前修改尚未保存。确定放弃这次修改吗？');}
function showQuickList(){
 if(!mayLeave())return;
 if(selected)loadEditor(selected,false,false);else openDefaultRecord();
 $('quick-search').focus({preventScroll:true});restoreScroll();
}
function focusSearch(){
 if(!library&&!document.body.classList.contains('quick-list')){showQuickList();return;}
 const box=library?$('search'):$('quick-search');box.focus();box.select();
}
// The quick window lives just above the T button. A record opened from it, and the library, show in a larger window that
// grows from there, from the toolbar side: its right and bottom edges stay where the quick window's were and it opens
// to the left and upwards (kept on the screen). Going back puts the quick window exactly where it was. If the large window was moved in
// between (for example by another click on T, which puts it above the button), the quick window keeps its centre and
// bottom edge, or the screen edge it touches, so it never drifts away from the button. Where it was is also kept for
// this window alone (session storage), so a reload while the window is large still knows the way back.
const isFrame=frame=>!!frame&&['x','y','w','h'].every(key=>Number.isFinite(frame[key]));
const frameNow=()=>({x:window.screenX,y:window.screenY,w:window.outerWidth,h:window.outerHeight});
const sameFrame=(a,b)=>!!b&&['x','y','w','h'].every(key=>Math.abs(a[key]-b[key])<=2);
let big=null,measureCanvas=null;
try{const saved=JSON.parse(sessionStorage.getItem('tnotes-big')||'null');if(isFrame(saved?.home)&&isFrame(saved?.placed))big=saved;}catch{}
// `width` is how wide a record's column is; it stays that wide (centred) when the window is made larger by hand.
function setBig(value){
 big=value;try{if(value)sessionStorage.setItem('tnotes-big',JSON.stringify(value));else sessionStorage.removeItem('tnotes-big');}catch{}
 const editor=document.querySelector('.editor');if(value?.width)editor.style.setProperty('--read-max',value.width+'px');else editor.style.removeProperty('--read-max');
}
setBig(big);
function openBig(w,h,width){
 const area=window.screen,left=area.availLeft||0,top=area.availTop||0,right=left+area.availWidth,bottom=top+area.availHeight;
 const home=big?.home||frameNow(),clamp=(value,low,high)=>Math.max(low,Math.min(value,high));
 const placed={x:clamp(home.x+home.w-w,left,right-w),y:clamp(home.y+home.h-h,top,bottom-h),w,h};
 setBig({home,placed,width});
 window.resizeTo(w,h);window.moveTo(placed.x,placed.y);
}
function closeBig(){
 if(!big)return;const {home,placed}=big;setBig(null);
 try{
  const area=window.screen,left=area.availLeft||0,top=area.availTop||0,right=left+area.availWidth,bottom=top+area.availHeight;
  const now=frameNow(),clamp=(value,low,high)=>Math.max(low,Math.min(value,high));let frame=home;
  if(!sameFrame(now,placed)){
   let centerX=now.x+now.w/2;
   if(now.x<=left+1)centerX=left+home.w/2;else if(now.x+now.w>=right-1)centerX=right-home.w/2;
   frame={x:clamp(Math.round(centerX-home.w/2),left,right-home.w),y:clamp(now.y+now.h-home.h,top,bottom-home.h),w:home.w,h:home.h};
  }
  window.resizeTo(frame.w,frame.h);window.moveTo(frame.x,frame.y);
 }catch{}
}
function fitReadingWindow(){
 if(library||editing||$('workspace').hidden)return;
 const open=!document.body.classList.contains('quick-list');
 if(open&&!$('read-content').hidden){if(!big)widenForRecord();}
 else closeBig();
}
// How wide a record wants to be with no line wrapped: its longest line of title, text, heading, code or account
// details, or its widest table.
function naturalWidth(content){
 content.classList.add('measuring');let widest=0;
 for(const element of content.querySelectorAll('#read-title,#read-body>.md-text,#read-body>.md-h,#read-body>.md-pre,#read-code,.read-field p'))
  if(element.getClientRects().length)widest=Math.max(widest,element.getBoundingClientRect().width+(element.id==='read-code'?2:0));
 content.classList.remove('measuring');
 return Math.max(widest,tableWidth(content));
}
// How wide the widest table wants to be: each column as wide as its longest line, up to 380 px (see tableBlock).
function tableWidth(content){return Math.max(0,...[...content.querySelectorAll('.md-table')].map(table=>Number(table.dataset.width)||0));}
// A record opened from the quick list: as wide as its longest line (so a line stays one line wherever the screen
// allows), at least 560 px, and as tall as the record, within the screen.
function widenForRecord(){
 try{
  const area=window.screen,margin=24,now=frameNow();
  const frameW=Math.max(0,now.w-innerWidth),frameH=Math.max(0,now.h-innerHeight);
  const content=$('read-content'),scroller=content.closest('.editor-body'),side=innerWidth-content.getBoundingClientRect().width;
  const room=area.availWidth-2*margin-frameW-side;
  const width=Math.round(Math.max(Math.min(560,room),Math.min(naturalWidth(content)+4,room)));
  // How tall the record is at that width, measured in place before anything is drawn: the panel's bars and margins
  // stay as they are, the scrolling part is as tall as its content.
  const bars=innerHeight-scroller.clientHeight;
  content.style.width=width+'px';scroller.style.flex='none';scroller.style.height='0';
  const tall=scroller.scrollHeight;
  content.style.width='';scroller.style.flex='';scroller.style.height='';
  // A record taller than the screen scrolls; the window is then a scroll bar wider, so no line has to wrap for it.
  const most=area.availHeight-2*margin,want=bars+tall+frameH+16,bar=want>most&&scroller.offsetWidth===scroller.clientWidth?17:0;
  openBig(Math.round(width+side+bar+frameW),Math.round(Math.max(Math.min(360,most),Math.min(most,want))),width);
 }catch{}
}
function libraryWindow(open){
 try{if(!open){closeBig();return;}const area=window.screen,margin=24;openBig(Math.min(1480,area.availWidth-2*margin),Math.min(940,area.availHeight-2*margin));}catch{}
}
function setView(value){if(!value&&!mayLeave())return;library=value;document.body.classList.toggle('library',library);$('app-title').textContent=library?'我的资料库':'随手记';libraryWindow(library);if(!library){if(selected)loadEditor(selected,false,false);else openDefaultRecord();$('quick-search').focus({preventScroll:true});}else renderList();rememberPlace();}
function openPromptDialog(template){
 const variables=promptVariables(template);$('variables').replaceChildren();
 const update=()=>{let text=template;for(const input of $('variables').querySelectorAll('input'))text=text.split('{{'+input.dataset.variable+'}}').join(input.value);$('prompt-output').value=text;};
 for(const name of variables){
  const label=document.createElement('label'),input=document.createElement('input');label.textContent=name;input.dataset.variable=name;input.addEventListener('input',update);
  // Enter finishes the fill; while an input method is composing, Enter only confirms the candidate.
  input.addEventListener('keydown',event=>{if(event.key==='Enter'&&!event.isComposing){event.preventDefault();$('copy-prompt').click();}});
  label.append(input);$('variables').append(label);
 }
 update();$('prompt-dialog').showModal();$('variables').querySelector('input')?.focus();
}
let showDone=false;try{showDone=localStorage.getItem('tnotes-todo-done-open')==='1';}catch{}
// Tags of the to-dos outside the trash, with how many of each are still open; the most used first.
function todoTags(){
 const tags=new Map();
 for(const r of plain.values())if(r.kind==='todo'&&!r.deleted&&r.tag)tags.set(r.tag,(tags.get(r.tag)||0)+(r.done?0:1));
 return [...tags].sort((a,b)=>b[1]-a[1]||a[0].localeCompare(b[0],'zh-CN'));
}
// The tags to choose from for a new to-do: those still on a to-do outside the trash (finished ones count), the most
// recently used first. A tag whose to-dos were all deleted is no longer offered.
function todoTagHistory(){
 const last=new Map();
 for(const r of plain.values())if(r.kind==='todo'&&!r.deleted&&r.tag)last.set(r.tag,Math.max(last.get(r.tag)||0,r.created||r.updated));
 return [...last].sort((a,b)=>b[1]-a[1]).map(([tag])=>tag);
}
// New to-dos get the tag being filtered by. Choosing a filter fills the tag boxes; when the filter goes away by itself,
// only boxes still showing it are emptied, so a tag being typed is kept.
function setTodoTag(tag,chosen=true){
 for(const id of ['todo-tag-quick','todo-tag-library'])if(chosen||$(id).value===todoTag)$(id).value=tag;
 todoTag=tag;
}
function chooseTodoTag(tag){setTodoTag(tag);renderList();rememberPlace();}
function renderList(){
 syncCategoryButtons();
 // A tag filter whose to-dos are all gone shows everything again.
 const tags=todoTags();if(todoTag&&!tags.some(([tag])=>tag===todoTag))setTodoTag('',false);
 const quickQuery=$('quick-search').value.trim().toLowerCase();
 const ordered=orderedRecords(),waiting=new Set((cache.data?.items||[]).filter(x=>x.pending).map(x=>x.id));
 const visible=libraryRecords();
 // In the 待办 category open to-dos come first, newest added on top, then the finished ones folded under 已完成,
 // most recently finished on top. Editing one does not move it.
 function draw(container,rows,previews=false,todos=false){
  container.replaceChildren();
  const added=r=>r.created||r.updated,finishedAt=r=>r.doneAt||r.updated;
  const open=todos?rows.filter(([,r])=>!r.done).sort(([,a],[,b])=>Number(!!b.pinned)-Number(!!a.pinned)||added(b)-added(a)):rows;
  const done=todos?rows.filter(([,r])=>r.done).sort(([,a],[,b])=>finishedAt(b)-finishedAt(a)):[];
  if(!open.length){const p=document.createElement('p');p.className='empty';p.textContent=todos?(done.length?'待办都完成了':'暂无待办'):'暂无记录';container.append(p);}
  for(const row of open)container.append(recordRow(row,previews));
  if(!done.length)return;
  container.append(doneHeading(done.map(([id])=>id)));
  if(showDone)for(const row of done)container.append(recordRow(row,previews));
 }
 function recordRow([id,r],previews){
   const todo=r.kind==='todo',config=r.kind==='config';
   const b=document.createElement('div');b.className='record'+(todo?' todo':'')+(finished(r)?' done':'')+(id===selected?' active':'');b.dataset.id=id;
   if(todo){
    const check=document.createElement('button'),mark=document.createElement('i'),label=r.done?'标为未完成':'标记完成';
    check.className='todo-check';check.title=label;check.setAttribute('aria-label',label+'：'+r.title);check.setAttribute('aria-pressed',String(!!r.done));check.disabled=!!r.deleted;
    mark.dataset.lucide=r.done?'circle-check':'circle';check.append(mark);check.addEventListener('click',guarded(()=>toggleDone(id)));b.append(check);
   }
   const open=document.createElement('button');open.className='record-open';open.title=r.title;open.setAttribute('aria-label','查看 '+r.title);
   const i=document.createElement('i');i.dataset.lucide=icons[r.kind]||'file-text';
   const wrap=document.createElement('div'),title=document.createElement('strong'),meta=document.createElement('small');
   // A to-do's check already says what it is, so its second line shows its tag and when it was added or finished.
   title.textContent=r.title;
   if(todo){
    if(r.tag){const pill=document.createElement('span');pill.className='todo-tag';pill.textContent=r.tag;meta.append(pill);}
    meta.append(todoTime(r)+(waiting.has(id)?' · 待同步':''));
   // A config says which format it is in, and previews its 说明, or its code when it has none.
   }else meta.textContent=(config?formatNames[formatOf(r)]:names[r.kind])+' · '+(r.tag||'未分类')+(waiting.has(id)?' · 待同步':'');
   wrap.append(title,meta);
   if(previews&&(!todo||r.body)){
    const preview=document.createElement('p'),code=config&&!r.note;preview.className='record-preview'+(code?' code-preview':'');
    // Each line of the preview stays one line (the first two show, cut short with … when too long).
    const lines=(r.kind==='password'?(r.account||'未填写账户'):code?r.body:plainText(config?r.note:r.body||'')).split('\n');
    lines.forEach((line,index)=>{if(index)preview.append('\n');const span=document.createElement('span');span.textContent=line;preview.append(span);});wrap.append(preview);
   }
   if(!todo)open.append(i);open.append(wrap);open.addEventListener('click',()=>{if(mayLeave())loadEditor(id);});b.append(open);
   const actions=document.createElement('div');actions.className='record-actions';
   // run() returns false when nothing reached the clipboard yet, e.g. a dialog took over.
   const action=(icon,label,enabled,run)=>{
    const button=document.createElement('button');button.title=label;button.setAttribute('aria-label',label);button.disabled=!enabled;
    const drawIcon=name=>{const symbol=document.createElement('i');symbol.dataset.lucide=name;button.replaceChildren(symbol);refreshIcons();};
    const symbol=document.createElement('i');symbol.dataset.lucide=icon;button.append(symbol);
    button.addEventListener('click',guarded(async()=>{
     if(await run()===false)return;
     button.classList.add('copied');drawIcon('check');
     setTimeout(()=>{if(button.isConnected){button.classList.remove('copied');drawIcon(icon);}},1400);
    }));actions.append(button);
   };
   const copyAction=(icon,label,text,secret=false)=>action(icon,label,!!text,()=>copy(text,secret));
   const link=r.deleted?null:firstLink(r);
   if(link)action('external-link','用默认浏览器打开链接',true,()=>openLink(link));
   if(!r.deleted){
    if(r.kind==='password'){copyAction('user-round','复制账号',r.account);copyAction('key-round','复制密码',r.password,true);}
    // Copying a template with unfilled {{variables}} is never what is wanted; ask for the values first.
    else if(r.kind==='prompt'&&promptVariables(r.body).length)action('braces','填充变量后复制',true,()=>{openPromptDialog(r.body);return false;});
    else if(config)copyAction('copy','复制配置',r.body);
    else if(!todo)copyAction('copy',r.body?'复制内容':'复制标题',r.body||r.title);
   }
   b.append(actions);return b;
 }
 const quickRows=ordered.filter(([,r])=>!r.deleted&&matches(r,quickQuery)&&(quickFilter==='all'||r.kind===quickFilter||(quickFilter==='pinned'&&r.pinned))&&inCategory(r,quickFilter)&&(quickFilter!=='todo'||!todoTag||r.tag===todoTag));
 for(const [id,category] of [['todo-add-quick',quickFilter],['todo-add-library',filter]])$(id).parentElement.hidden=category!=='todo';
 // Tag filters for to-dos: 全部 and each tag with its open count. A tag with nothing left to do is left out, unless it
 // is the one being filtered by. Choosing the chosen tag again shows all.
 const shownTags=tags.filter(([tag,count])=>count||tag===todoTag);
 for(const [id,category] of [['todo-tags-quick',quickFilter],['todo-tags-library',filter]]){
  const box=$(id);box.replaceChildren();box.hidden=category!=='todo'||!shownTags.length;if(box.hidden)continue;
  for(const [tag,count] of [['',0],...shownTags]){
   const chip=document.createElement('button'),active=tag===todoTag;chip.textContent=tag||'全部';
   if(count){const n=document.createElement('small');n.textContent=count;chip.append(n);}
   chip.title=tag?'只看标签“'+tag+'”':'看全部待办';chip.classList.toggle('active',active);chip.setAttribute('aria-pressed',String(active));
   chip.addEventListener('click',()=>chooseTodoTag(active?'':tag));box.append(chip);
   if(tag)chip.addEventListener('contextmenu',event=>openRowMenu(event,chip,[{icon:'trash-2',label:'删除“'+tag+'”的全部待办',danger:true,run:()=>deleteTodoTag(tag)}]));
  }
  // With a tag chosen, the end of the row offers to move all of that tag's to-dos to the trash at once.
  if(todoTag){
   const tag=todoTag,remove=document.createElement('button'),icon=document.createElement('i'),text=document.createElement('span');
   remove.className='todo-tag-delete';remove.title='把标签“'+tag+'”的待办全部移到回收站';remove.setAttribute('aria-label',remove.title);
   icon.dataset.lucide='trash-2';text.textContent='删除全部';remove.append(icon,text);remove.addEventListener('click',guarded(()=>deleteTodoTag(tag)));box.append(remove);
   // The chosen chip stays in sight beside the button (the row's scroll padding keeps it clear of the button).
   box.querySelector('button.active')?.scrollIntoView({block:'nearest',inline:'nearest'});
  }
 }
 $('todo-tag-list').replaceChildren(...todoTagHistory().map(tag=>Object.assign(document.createElement('option'),{value:tag})));
 draw($('record-list'),visible,false,filter==='todo');draw($('recent-list'),quickRows,true,quickFilter==='todo');
 $('quick-title').textContent={all:'全部记录',pinned:'已置顶'}[quickFilter]||names[quickFilter];
 $('quick-count').textContent=quickFilter==='todo'?quickRows.filter(([,r])=>!r.done).length+' 条未完成':quickRows.length+' 条';refreshIcons();
}
function doneHeading(ids){
 const head=document.createElement('div'),toggle=document.createElement('button'),chevron=document.createElement('i'),text=document.createElement('span'),clear=document.createElement('button');
 head.className='todo-done-heading';toggle.className='text';clear.className='text';
 chevron.dataset.lucide=showDone?'chevron-down':'chevron-right';text.textContent='已完成 '+ids.length;toggle.append(chevron,text);toggle.setAttribute('aria-expanded',String(showDone));
 toggle.addEventListener('click',()=>{showDone=!showDone;try{localStorage.setItem('tnotes-todo-done-open',showDone?'1':'0');}catch{}renderList();});
 clear.textContent='清除';clear.title='把已完成的待办移到回收站';clear.addEventListener('click',guarded(()=>clearDone(ids)));
 head.append(toggle,clear);return head;
}
async function saveInner(){
 if(!keys)return;
 const id=selected||crypto.randomUUID(),value=recordFromForm();
 const encoded=await encrypt(keys.key,profile().id,id,value);
 const existing=cache.data.items.find(r=>r.id===id),previous=existing?{...existing}:null;
 if(existing){existing.envelope=encoded;existing.pending=true;}else cache.data.items.push({id,rev:0,envelope:encoded,pending:true});
 try{await persist();}catch(e){if(previous)Object.assign(existing,previous);else cache.data.items=cache.data.items.filter(x=>x.id!==id);throw e;}
 plain.set(id,value);selected=id;dirty=false;loadEditor(id,false,library);
 status('本机已加密保存 · '+pending()+' 条待同步');notice('已保存');settleErrors('save');
}
async function save(){await exclusive(saveInner);void sync();}
// Quick changes (adding or checking off a to-do, pinning, deleting) show at once. They are encrypted and saved in the
// background, one after another, behind any sync that is running, and synced together a moment after the last one,
// so neither the server nor a running sync holds the window up. Until a change is saved, a sync does not overwrite it.
// If saving fails, records still showing the change go back to how they were and the error is shown.
const unsaved=new Map();let syncTimer;
function syncSoon(){clearTimeout(syncTimer);syncTimer=setTimeout(()=>{if(keys)void sync();},1500);}
function applyLocal(entries){
 for(const {id,value} of entries){plain.set(id,value);unsaved.set(id,(unsaved.get(id)||0)+1);}
 const release=()=>{for(const {id} of entries){const left=(unsaved.get(id)||1)-1;if(left)unsaved.set(id,left);else unsaved.delete(id);}};
 const saved=exclusive(async()=>{
  if(!keys)throw Error('已退出登录，修改没有保存');
  const touched=[];
  for(const {id,value} of entries){
   const envelope=await encrypt(keys.key,profile().id,id,value),item=cache.data.items.find(x=>x.id===id);
   touched.push([id,item,item?{...item}:null]);
   if(item){item.envelope=envelope;item.pending=true;}else cache.data.items.push({id,rev:0,envelope,pending:true});
  }
  try{await persist();}
  catch(e){for(const [id,item,previous] of touched){if(item)Object.assign(item,previous);else cache.data.items=cache.data.items.filter(x=>x.id!==id);}throw e;}
 });
 saved.then(()=>{release();settleErrors('save');syncSoon();},e=>{
  release();if(!keys)return;
  for(const {id,value,previous} of entries)if(plain.get(id)===value){if(previous)plain.set(id,previous);else plain.delete(id);}
  if(selected&&!plain.has(selected))selected=null;
  if(!editing){if(selected)showViewer();else openDefaultRecord();}
  renderList();notice('保存失败，已撤回这次修改：'+e.message,'error');
 });
 return saved;
}
function updateRecords(ids,change){
 const now=Date.now(),entries=[];
 for(const id of ids){const r=plain.get(id);if(r)entries.push({id,previous:r,value:{...r,...change(r),updated:now}});}
 return applyLocal(entries);
}
function toggleDone(id){
 const r=plain.get(id);if(!r||r.deleted)return;
 updateRecords([id],x=>({done:!x.done,doneAt:x.done?undefined:Date.now()}));
 if(id===selected&&!editing)showViewer();
 renderList();notice(r.done?'已标为未完成':'已完成');
}
function clearDone(ids){
 // A to-do open in the editor is left alone; saving it would bring it back from the trash.
 const gone=ids.filter(id=>!(editing&&id===selected));
 if(!gone.length||!confirm('把 '+gone.length+' 条已完成的待办移到回收站？'))return;
 updateRecords(gone,()=>({deleted:true}));
 if(gone.includes(selected)){selected=null;openDefaultRecord();}else renderList();
 notice('已移到回收站');
}
// Every to-do with the tag, finished ones included, goes to the trash (where each can be restored). With the tag gone,
// the tag filter shows all to-dos again.
function deleteTodoTag(tag){
 const ids=[...plain].filter(([id,r])=>r.kind==='todo'&&!r.deleted&&r.tag===tag&&!(editing&&id===selected)).map(([id])=>id);
 if(!ids.length)return;
 const done=ids.filter(id=>plain.get(id).done).length;
 if(!confirm('把标签“'+tag+'”的 '+ids.length+' 条待办'+(done?'（其中 '+done+' 条已完成）':'')+'移到回收站？'))return;
 updateRecords(ids,()=>({deleted:true}));
 if(ids.includes(selected)){selected=null;openDefaultRecord();}else renderList();
 rememberPlace();notice('已把 '+ids.length+' 条待办移到回收站');
}
// One record to the trash, or back from it. Choosing this from the right-click menu is the decision, so it does not ask
// again (the trash keeps it); unsaved edits to it still ask first.
function trashRecord(id,restore=false){
 const r=plain.get(id);if(!r||!!r.deleted!==restore)return;
 if(editing&&id===selected&&!mayLeave())return;
 updateRecords([id],()=>({deleted:!restore}));
 if(id===selected){selected=null;editing=false;dirty=false;openDefaultRecord();}else renderList();
 notice(restore?'已恢复':'已移到回收站，可在回收站恢复');
}
function togglePin(id){
 // While the record is being edited, pinning belongs to the form like the 置顶 button there.
 if(editing&&id===selected){$('pin').click();return;}
 const r=plain.get(id);if(!r)return;
 updateRecords([id],x=>({pinned:!x.pinned}));
 if(id===selected){pinned=!r.pinned;$('pin').setAttribute('aria-pressed',String(pinned));}
 renderList();notice(r.pinned?'已取消置顶':'已置顶');
}
// A row's right-click menu holds what its buttons and the record panel offer, then delete; in the trash, view and restore.
function recordMenu(id){
 const r=plain.get(id);if(!r)return [];
 const view={icon:'eye',label:'查看',run:()=>{if(mayLeave())loadEditor(id);}};
 if(r.deleted)return [view,null,{icon:'undo-2',label:'恢复',run:()=>trashRecord(id,true)}];
 const items=[view,{icon:'pencil',label:'编辑',run:()=>{if(mayLeave())loadEditor(id,true);}}];
 if(r.kind==='todo')items.push({icon:r.done?'circle':'circle-check',label:r.done?'标为未完成':'标记完成',run:()=>toggleDone(id)});
 items.push({icon:r.pinned?'pin-off':'pin',label:r.pinned?'取消置顶':'置顶',run:()=>togglePin(id)});
 if(r.kind==='password'){
  if(r.account)items.push({icon:'user-round',label:'复制账号',run:()=>copy(r.account)});
  if(r.password)items.push({icon:'key-round',label:'复制密码',run:()=>copy(r.password,true)});
 }else if(r.kind==='prompt'&&promptVariables(r.body).length)items.push({icon:'braces',label:'填充变量后复制',run:()=>openPromptDialog(r.body)});
 else if(r.kind==='config')items.push({icon:'copy',label:'复制配置',run:()=>copy(r.body)});
 else if(r.kind==='todo')items.push({icon:'copy',label:'复制文字',run:()=>copy([r.title,r.body].filter(Boolean).join('\n'))});
 else items.push({icon:'copy',label:r.body?'复制内容':'复制标题',run:()=>copy(r.body||r.title)});
 const link=firstLink(r);if(link)items.push({icon:'external-link',label:'用默认浏览器打开链接',run:()=>openLink(link)});
 items.push(null,{icon:'trash-2',label:'删除',danger:true,run:()=>trashRecord(id)});
 return items;
}
// Right-clicking a list row (or a to-do tag) opens this menu at the pointer; Shift+right-click still opens the browser's
// own menu. From the keyboard (the menu key) it opens under the focused row, and the arrow keys move through it. It
// closes on Escape, on a click elsewhere, and when anything scrolls or the window loses focus.
let menuTarget=null;
function closeRowMenu(){if($('row-menu').hidden)return;$('row-menu').hidden=true;menuTarget?.classList.remove('menu-target');menuTarget=null;}
function openRowMenu(event,target,items){
 if(event.shiftKey)return;
 event.preventDefault();closeRowMenu();
 const menu=$('row-menu');
 menu.replaceChildren(...items.map(item=>{
  if(!item){const line=document.createElement('div');line.className='row-menu-line';line.setAttribute('role','separator');return line;}
  const {icon,label,danger,run}=item,button=document.createElement('button'),symbol=document.createElement('i'),text=document.createElement('span');
  button.type='button';button.setAttribute('role','menuitem');button.classList.toggle('danger',!!danger);symbol.dataset.lucide=icon;text.textContent=label;button.append(symbol,text);
  button.addEventListener('click',()=>{closeRowMenu();guarded(run)();});return button;
 }));
 menuTarget=target;target.classList.add('menu-target');menu.hidden=false;refreshIcons();
 const keyboard=!event.clientX&&!event.clientY,box=target.getBoundingClientRect();
 const x=keyboard?box.left+16:event.clientX,y=keyboard?box.bottom:event.clientY;
 menu.style.left=Math.max(4,Math.min(x,innerWidth-menu.offsetWidth-4))+'px';menu.style.top=Math.max(4,Math.min(y,innerHeight-menu.offsetHeight-4))+'px';
 menu.querySelector('button')?.focus({preventScroll:true});
}
for(const list of ['recent-list','record-list'])$(list).addEventListener('contextmenu',event=>{
 const row=event.target.closest('.record'),id=row?.dataset.id,r=plain.get(id);if(!r)return;
 openRowMenu(event,row,recordMenu(id));
});
document.addEventListener('pointerdown',event=>{if(!$('row-menu').contains(event.target))closeRowMenu();},true);
document.addEventListener('keydown',event=>{
 if($('row-menu').hidden)return;
 if(event.key==='Escape'){event.preventDefault();event.stopPropagation();closeRowMenu();return;}
 if(!['ArrowDown','ArrowUp','Home','End'].includes(event.key))return;
 event.preventDefault();event.stopPropagation();
 const buttons=[...$('row-menu').querySelectorAll('button')],at=buttons.indexOf(document.activeElement);
 const next={ArrowDown:(at+1)%buttons.length,ArrowUp:(at-1+buttons.length)%buttons.length,Home:0,End:buttons.length-1}[event.key];
 buttons[next]?.focus();
},true);
document.addEventListener('scroll',closeRowMenu,true);window.addEventListener('blur',closeRowMenu);window.addEventListener('resize',closeRowMenu);
// The add box grows with its text up to about seven lines, then scrolls.
function fitTodoBox(box){box.style.height='';if(box.value&&box.scrollHeight>box.clientHeight)box.style.height=Math.min(box.scrollHeight,180)+'px';}
// A typed title is the to-do's title and the text box, all of it, its note. Without one, pasted text keeps its line
// breaks: the first line becomes the title and the rest the note. The to-do shows at once and the boxes are emptied so
// the next one can be typed (the tag box goes back to the tag being filtered by); if saving fails, the text comes back
// into the empty boxes. Markdown marks (# or **) stay out of the title; a paste that starts with a table keeps the
// whole table as the note and is named after its columns.
function addTodo(box,tagBox,titleBox){
 const text=box.value.replace(/\r\n?/g,'\n').trim(),typed=titleBox.value.trim();if(!text&&!typed||!keys)return;
 const cut=text.indexOf('\n'),first=(cut<0?text:text.slice(0,cut)).trim(),table=first.startsWith('|')||tabCells(first)>=2;
 const title=typed||plainText(first).trim()||first,body=typed||table?text:cut<0?'':text.slice(cut+1).replace(/^(?:[ \t]*\n)+/,'').trimEnd();
 const tag=tagBox.value.trim();box.value='';titleBox.value='';fitTodoBox(box);tagBox.value=todoTag;
 if(document.activeElement===box)titleBox.focus();
 const now=Date.now(),value={kind:'todo',title,body,tag,pinned:false,account:'',password:'',site:'',done:false,deleted:false,created:now,updated:now};
 applyLocal([{id:crypto.randomUUID(),value}]).catch(()=>{if(!box.value&&!titleBox.value){box.value=text;titleBox.value=typed;fitTodoBox(box);}});
 renderList();
 if(todoTag&&tag!==todoTag)notice('已添加到'+(tag?'标签“'+tag+'”':'无标签')+'；现在只显示“'+todoTag+'”');
}
async function copy(text,secret=false){
 if(!text){notice('没有可复制的内容');return;}
 await navigator.clipboard.writeText(text);notice(secret?'已复制密码，30 秒后尝试清除剪贴板':'已复制');
 if(secret){clearTimeout(clipboardTimer);clipboardTimer=setTimeout(async()=>{try{if(await navigator.clipboard.readText()===text)await navigator.clipboard.writeText('');}catch{notice('浏览器未允许自动清除剪贴板，请手动覆盖已复制的密码','keep');}},30000);}
}
function guarded(fn){return async event=>{try{await fn(event);}catch(e){notice(e.message,'error');}};}
// Web addresses in notes become links. They open in the default browser through the local backend, since this
// window runs on its own browser profile, not the one the user browses with.
const linkPattern=/(?:https?:\/\/|www\.)[^\s<>"'`，。；、！？（）【】《》「」]+/gi;
const trailing=/[.,;:!?'"。，；：！？…]+$/u;
function trimLink(text){
 let value=text.replace(trailing,'');
 const count=(s,pattern)=>(s.match(pattern)||[]).length;
 // A closing bracket belongs to the address only when the address also opens one, as in Wikipedia links.
 while(/[)\]}]$/.test(value)&&count(value,/[)\]}]/g)>count(value,/[([{]/g))value=value.slice(0,-1).replace(trailing,'');
 return value;
}
function linkTarget(text){
 const value=(text||'').trim();
 if(!value||/\s/.test(value))return null;
 try{
  const url=new URL(/^https?:\/\//i.test(value)?value:'https://'+value);
  return ['http:','https:'].includes(url.protocol)&&url.hostname.includes('.')&&!url.username&&!url.password?url.href:null;
 }catch{return null;}
}
function firstLink(r){
 // The website field may be a bare domain; in other text only addresses starting with http(s):// or www. count.
 const site=linkTarget(r.site);if(site)return site;
 for(const text of [r.body,r.note,r.title])for(const match of (text||'').matchAll(linkPattern)){const href=linkTarget(trimLink(match[0]));if(href)return href;}
 return null;
}
async function openLink(href){await api('/api/open-url',{method:'POST',body:{url:href}});notice('已用默认浏览器打开');}
function linkElement(label,href){
 const a=document.createElement('a');a.className='web-link';a.href=href;a.textContent=label;a.title='用默认浏览器打开：'+href;a.rel='noreferrer';
 const go=event=>{event.preventDefault();guarded(()=>openLink(href))();};
 a.addEventListener('click',go);a.addEventListener('auxclick',event=>{if(event.button===1)go(event);});
 return a;
}
function appendLinked(element,text){
 const source=text||'';let last=0;
 for(const match of source.matchAll(linkPattern)){
  const label=trimLink(match[0]),href=linkTarget(label);
  if(!href)continue;
  if(match.index>last)element.append(source.slice(last,match.index));
  element.append(linkElement(label,href));last=match.index+label.length;
 }
 if(last<source.length)element.append(source.slice(last));
}
function renderLinked(element,text){element.replaceChildren();appendLinked(element,text);}
// Rich text in notes, to-dos and 说明 is kept as Markdown and drawn here: tables (also rows of tab-separated cells),
// fenced code, headings, rules, **bold**, `code`, [links](https://…) and <br> inside table cells. Everything else is shown
// as written, line by line, so plain notes look as before. It is all built as text nodes, never parsed as HTML.
const tableRule=line=>line.includes('|')&&line.includes('-')&&/^[\s|:-]+$/.test(line);
const tabCells=line=>/^\S[^\t]*\t/.test(line)?line.split('\t').length:0;
const splitRow=line=>line.trim().replace(/^\|/,'').replace(/(?<!\\)\|$/,'').split(/(?<!\\)\|/).map(cell=>cell.trim().replace(/\\\|/g,'|'));
const inlinePattern=/(`+)(.+?)\1(?!`)|\*\*(?=\S)(.+?)\*\*|\[([^\]\n]+)\]\(([^\s)]+)\)|<br\s*\/?>/gi;
function renderInline(parent,text){
 let last=0;
 for(const m of text.matchAll(inlinePattern)){
  if(m.index>last)appendLinked(parent,text.slice(last,m.index));
  if(m[1]){const code=document.createElement('code');code.className='md-code';code.textContent=m[2].replace(/^ (.+) $/,'$1');parent.append(code);}
  else if(m[3]){const strong=document.createElement('strong');renderInline(strong,m[3]);parent.append(strong);}
  // A link to a web page opens in the browser; one to anything else (a local file, as in Codex answers) shows its name,
  // with where it points when the pointer rests on it.
  else if(m[4]){const href=/^https?:\/\//i.test(m[5])&&linkTarget(m[5]);if(href)parent.append(linkElement(m[4],href));else{const name=document.createElement('span');name.className='md-file';name.textContent=m[4];name.title=m[5];parent.append(name);}}
  else parent.append(document.createElement('br'));
  last=m.index+m[0].length;
 }
 if(last<text.length)appendLinked(parent,text.slice(last));
}
// Markdown reduced to what reads well as plain text: list previews, titles, table labels.
function plainText(text){
 return (text||'').split('\n').filter(line=>!tableRule(line)&&!/^\s*(?:```|~~~)/.test(line))
  .map(line=>line.replace(/^\s*#{1,6}\s+/,'').replace(/^\s*\|.*\|?\s*$/,row=>splitRow(row).filter(Boolean).join(' · ')).replace(/\t+/g,' · '))
  .join('\n').replace(/\*\*(?=\S)(.+?)\*\*/g,'$1').replace(/(`+)(.+?)\1(?!`)/g,'$2').replace(/\[([^\]\n]+)\]\(([^\s)]+)\)/g,'$1').replace(/<br\s*\/?>/gi,' ');
}
// How wide a line of a table cell is drawn: `code` in the smaller fixed-width font with its padding, the rest as text.
function cellLineWidth(line){
 const pen=(measureCanvas||=document.createElement('canvas')).getContext('2d');let width=0;
 line.split(/(`[^`]+`)/).forEach((part,index)=>{
  if(index%2){pen.font='12px "Cascadia Mono","Cascadia Code",Consolas,"Microsoft YaHei",monospace';width+=pen.measureText(part.slice(1,-1)).width+12;}
  else{pen.font='14px "Segoe UI","Microsoft YaHei",sans-serif';width+=pen.measureText(plainText(part)).width;}
 });
 return width;
}
// Each cell carries its column's name, shown above the value when a narrow window stacks the table into cards.
function tableBlock(head,rows){
 const wrap=document.createElement('div'),table=document.createElement('table'),thead=document.createElement('thead'),tbody=document.createElement('tbody'),top=document.createElement('tr');
 wrap.className='md-table-wrap';table.className='md-table';
 for(const cell of head){const th=document.createElement('th');renderInline(th,cell);top.append(th);}
 thead.append(top);
 for(const row of rows){
  const tr=document.createElement('tr');
  head.forEach((name,index)=>{const td=document.createElement('td');td.dataset.label=plainText(name);renderInline(td,index===head.length-1?row.slice(index).join(' | '):row[index]||'');tr.append(td);});
  tbody.append(tr);
 }
 // Each column's share of the width follows how wide its longest line is (up to 380 px; longer text wraps anyway), so
 // a column of names or file names keeps them on one line wherever the table is wide enough. The total is what the
 // table window is sized by.
 const colgroup=document.createElement('colgroup'),weights=head.map((name,index)=>{
  const lines=[name,...rows.map(row=>row[index]||'')].flatMap(cell=>cell.split(/<br\s*\/?>/i)).map(cellLineWidth);
  return Math.min(380,Math.max(30,...lines))+40;
 }),total=weights.reduce((sum,weight)=>sum+weight,0);table.dataset.width=String(Math.ceil(total+2));
 for(const weight of weights){const col=document.createElement('col');col.style.width=(weight/total*100).toFixed(1)+'%';colgroup.append(col);}
 table.append(colgroup,thead,tbody);wrap.append(table);return wrap;
}
const fenceFormats={json:'json',jsonc:'json',yaml:'yaml',yml:'yaml',ini:'ini',toml:'ini',env:'ini',properties:'ini',xml:'xml',html:'xml',svg:'xml',sh:'shell',bash:'shell',shell:'shell',zsh:'shell',powershell:'powershell',ps1:'powershell',pwsh:'powershell',bat:'bat',cmd:'bat',js:'js',javascript:'js',ts:'js',typescript:'js',jsx:'js',tsx:'js',java:'clike',kotlin:'clike',kt:'clike',kts:'clike',c:'clike',cpp:'clike','c++':'clike',cs:'clike',csharp:'clike',go:'clike',rust:'clike',swift:'clike',dart:'clike',python:'python',py:'python',sql:'sql',css:'css',scss:'css',nginx:'conf',conf:'conf'};
function codeBlock(code,lang){
 const pre=document.createElement('pre');pre.className='md-pre';
 for(const [type,text] of tokenize(code,grammars[fenceFormats[lang.toLowerCase()]]||[])){
  if(!type){pre.append(text);continue;}
  const span=document.createElement('span');span.className='tk-'+type;span.textContent=text;pre.append(span);
 }
 return pre;
}
function renderRich(element,text){
 element.replaceChildren();
 const lines=(text||'').replace(/\r\n?/g,'\n').split('\n');let buffer=[];
 // Text between blocks keeps its lines; only the blank lines right next to a table, code block or heading are dropped.
 const flush=(before)=>{
  let chunk=buffer.join('\n');buffer=[];
  if(element.lastChild)chunk=chunk.replace(/^\n+/,'');if(before)chunk=chunk.replace(/\n+$/,'');
  if(!chunk||(element.lastChild||before)&&!chunk.trim())return;
  const block=document.createElement('div');block.className='md-text';renderInline(block,chunk);element.append(block);
 };
 const add=node=>{flush(true);element.append(node);};
 for(let i=0;i<lines.length;){
  const line=lines[i],fence=line.match(/^\s*(`{3,}|~{3,})\s*([\w+#.-]*)\s*$/);
  if(fence){
   let j=i+1;const code=[];while(j<lines.length&&!lines[j].trim().startsWith(fence[1]))code.push(lines[j++]);
   add(codeBlock(code.join('\n'),fence[2]));i=j+1;continue;
  }
  if(line.includes('|')&&tableRule(lines[i+1]||'')){
   let j=i+2;const rows=[];while(j<lines.length&&lines[j].includes('|')&&lines[j].trim())rows.push(splitRow(lines[j++]));
   add(tableBlock(splitRow(line),rows));i=j;continue;
  }
  const cells=tabCells(line);
  if(cells>=2){
   let j=i+1;while(j<lines.length&&tabCells(lines[j])===cells)j++;
   if(j-i>=2){const rows=lines.slice(i,j).map(row=>row.split('\t').map(cell=>cell.trim()));add(tableBlock(rows[0],rows.slice(1)));i=j;continue;}
  }
  const heading=line.match(/^(#{1,6})\s+(.+?)\s*#*\s*$/);
  if(heading){const h=document.createElement('div');h.className='md-h md-h'+Math.min(heading[1].length,3);renderInline(h,heading[2]);add(h);i++;continue;}
  if(/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)){const hr=document.createElement('hr');hr.className='md-hr';add(hr);i++;continue;}
  buffer.push(line);i++;
 }
 flush(false);
}
// Pasting from a page or an answer keeps its structure as Markdown text: tables, code, bold, headings, lists and web
// links (links to anything but a web page keep only their text). Plain text in tab-separated columns, as a table copied
// from a program without rich copy arrives, becomes a table too. Code in a config is always pasted as it is.
const blockTags=new Set(['P','DIV','SECTION','ARTICLE','HEADER','FOOTER','MAIN','ASIDE','NAV','FIGURE','H1','H2','H3','H4','H5','H6','UL','OL','LI','PRE','BLOCKQUOTE','TABLE','HR','DL','DT','DD']);
const blockSelector=[...blockTags].join(',');
function htmlInline(node){
 let out='';
 for(const child of node.childNodes){
  if(child.nodeType===3){out+=child.nodeValue.replace(/\s+/g,' ');continue;}
  if(child.nodeType!==1)continue;
  const tag=child.tagName;
  if(['SCRIPT','STYLE','TEMPLATE','NOSCRIPT','HEAD','TITLE'].includes(tag))continue;
  if(tag==='BR'){out+='\n';continue;}
  if(blockTags.has(tag)||child.querySelector(blockSelector)){out+='\n'+(blockTags.has(tag)?htmlBlock(child):htmlBlocks(child))+'\n';continue;}
  if(['CODE','KBD','SAMP','TT'].includes(tag)){const code=child.textContent.replace(/\s+/g,' '),ticks=code.includes('`')?'`` ':'`';if(code.trim())out+=ticks+code+[...ticks].reverse().join('');continue;}
  if(tag==='STRONG'||tag==='B'){const inner=htmlInline(child).trim();if(inner)out+='**'+inner+'**';continue;}
  if(tag==='A'){const inner=htmlInline(child).trim(),href=child.getAttribute('href')||'';out+=/^https?:\/\//i.test(href)&&inner&&inner!==href?'['+inner.replace(/[[\]]/g,'')+']('+href.replace(/[()\s]/g,c=>encodeURIComponent(c))+')':inner;continue;}
  if(tag==='IMG'){out+=child.getAttribute('alt')||'';continue;}
  out+=htmlInline(child);
 }
 return out;
}
function htmlList(list,depth){
 const lines=[];let number=Number(list.getAttribute('start'))||1;
 for(const item of list.children){
  if(item.tagName!=='LI')continue;
  const marker=list.tagName==='OL'?(number++)+'. ':'- ',pad='  '.repeat(depth),own=[],nested=[];
  for(const child of item.childNodes){if(child.nodeType===1&&(child.tagName==='UL'||child.tagName==='OL'))nested.push(htmlList(child,depth+1));else own.push(child);}
  lines.push(pad+marker+htmlBlocks({childNodes:own}).replace(/\n+/g,'\n'+pad+'  '),...nested);
 }
 return lines.join('\n');
}
function htmlTable(table){
 const rows=[...table.querySelectorAll('tr')].filter(tr=>tr.closest('table')===table).map(tr=>[...tr.children].filter(cell=>cell.tagName==='TD'||cell.tagName==='TH').map(cell=>htmlBlocks(cell).replace(/\n+/g,'<br>').replace(/\|/g,'\\|')));
 if(!rows.length)return '';
 const width=Math.max(...rows.map(row=>row.length)),line=row=>'| '+[...row,...Array(width-row.length).fill('')].join(' | ')+' |';
 return [line(rows[0]),'|'+' --- |'.repeat(width),...rows.slice(1).map(line)].join('\n');
}
function htmlBlock(element){
 const tag=element.tagName;
 if(/^H[1-6]$/.test(tag))return '#'.repeat(Number(tag[1]))+' '+htmlInline(element).trim().replace(/\s*\n\s*/g,' ');
 if(tag==='PRE'){const code=element.querySelector('code'),lang=((code||element).className.match(/(?:language|lang)-([\w+#-]+)/)||[])[1]||'',text=(code||element).textContent.replace(/\n$/,''),fence=text.includes('```')?'~~~':'```';return fence+lang+'\n'+text+'\n'+fence;}
 if(tag==='UL'||tag==='OL')return htmlList(element,0);
 if(tag==='TABLE')return htmlTable(element);
 if(tag==='HR')return '---';
 if(tag==='BLOCKQUOTE')return htmlBlocks(element).split('\n').map(line=>'> '+line).join('\n');
 return htmlBlocks(element);
}
function htmlBlocks(node){
 const parts=[];let line='';
 const flush=()=>{const text=line.replace(/[ \t]*\n[ \t]*/g,'\n').trim();if(text)parts.push(text);line='';};
 for(const child of node.childNodes){
  if(child.nodeType===1&&(blockTags.has(child.tagName)||child.querySelector(blockSelector))){flush();const md=htmlBlock(child);if(md)parts.push(md);}
  else line+=htmlInline({childNodes:[child]});
 }
 flush();return parts.join('\n\n');
}
// A selection that starts inside a table (as copied from Codex) arrives as rows and cells without their <table>; the
// parser would drop those tags and run the cells together, so such a fragment is put back into a table first.
function htmlToMarkdown(html){
 const fragment=html.match(/<!--StartFragment-->([\s\S]*?)<!--EndFragment-->/)?.[1]??html;
 const source=/^\s*<(?:thead|tbody|tfoot|tr|th|td)\b/i.test(fragment)?'<table>'+fragment+'</table>':html;
 return htmlBlocks(new DOMParser().parseFromString(source,'text/html').body).replace(/\n{3,}/g,'\n\n').trim();
}
function tabsToMarkdown(text){
 const lines=text.replace(/\r\n?/g,'\n').split('\n'),out=[];let changed=false;
 for(let i=0;i<lines.length;){
  const cells=tabCells(lines[i]);let j=i+1;
  if(cells>=2)while(j<lines.length&&tabCells(lines[j])===cells)j++;
  if(cells>=2&&j-i>=2){
   const rows=lines.slice(i,j).map(row=>row.split('\t').map(cell=>cell.trim().replace(/\|/g,'\\|')));
   out.push('| '+rows[0].join(' | ')+' |','|'+' --- |'.repeat(cells),...rows.slice(1).map(row=>'| '+row.join(' | ')+' |'));i=j;changed=true;continue;
  }
  out.push(lines[i]);i++;
 }
 return changed?out.join('\n'):null;
}
// The clipboard as Markdown, or null when it is plain text that needs no change.
function richPaste(data){
 if(!data)return null;
 const html=data.getData('text/html'),text=data.getData('text/plain');
 const markdown=html&&/<(?:table|pre|code|strong|b|h[1-6]|ul|ol|blockquote)\b|<a\s[^>]*href\s*=\s*["']?https?:/i.test(html)?htmlToMarkdown(html):text?tabsToMarkdown(text):null;
 return !markdown||markdown===text?null:markdown;
}
function pasteRich(event){
 const markdown=richPaste(event.clipboardData);if(markdown===null)return;
 event.preventDefault();document.execCommand('insertText',false,markdown);
}
function renderSite(element,site){
 const href=linkTarget(site);
 if(href)element.replaceChildren(linkElement(site.trim(),href));else element.textContent=site||'';
}
// Configs: code shown with its syntax coloured and its comments set apart. A small built-in highlighter: each format is
// a list of rules tried in order at every position, and the first that matches takes the text. A rule's type may
// depend on the word it matched (keywords, calls), and a rule may colour the inside of its match with other rules (XML
// tags). The result is drawn as text nodes, never as HTML, so nothing in a record can run as code.
const formats=[['','自动识别'],['json','JSON'],['yaml','YAML'],['ini','INI / TOML / .env'],['xml','XML / HTML'],['shell','Shell / Bash'],['powershell','PowerShell'],['bat','CMD / BAT'],['js','JavaScript / TypeScript'],['clike','Java / Kotlin / C# / Go'],['python','Python'],['sql','SQL'],['css','CSS'],['conf','Nginx / SSH / 其他配置'],['text','纯文本']];
const formatNames=Object.fromEntries(formats);
$('lang').replaceChildren(...formats.map(([value,label])=>Object.assign(document.createElement('option'),{value,textContent:label})));
const rule=(type,source,flags='')=>({type,re:new RegExp(source,'y'+flags)});
const wordSet=text=>new Set(text.split(' '));
const keywordRule=(list,flags='')=>rule('keyword','(?:'+list.split(' ').join('|')+String.raw`)(?![\w$.-])`,flags);
const dq=String.raw`"(?:[^"\\\n]|\\.)*"`,sq=String.raw`'(?:[^'\\\n]|\\.)*'`,num=String.raw`-?(?:0[xX][\da-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![\w.])`;
const lineComment=rule('comment','//.*'),blockComment=rule('comment',String.raw`/\*[\s\S]*?(?:\*/|$)`),hashComment=rule('comment',String.raw`(?<=^|\s)#.*`,'m');
const plainWord=rule(null,String.raw`[\w$][\w$.-]*`);
// Words in code: keywords, constants, calls (a word followed by "(") and, where asked, capitalised type names.
function words(keywords,literals,{types=false,fold=false}={}){
 return rule((word,source,end)=>{
  const key=fold?word.toUpperCase():word;
  if(keywords.has(key))return 'keyword';if(literals.has(key))return 'literal';
  if(/^[ \t]*\(/.test(source.slice(end,end+20)))return 'func';
  return types&&/^[A-Z][a-z0-9]*[a-z]/.test(word)?'type':null;
 },String.raw`[A-Za-z_$][\w$]*`);
}
const literalWords=wordSet('true false null undefined NaN nil None');
const jsKeywords=wordSet('const let var function return if else for while do switch case break continue new class extends import export from default async await try catch finally throw typeof instanceof in of this super yield delete void static get set interface type enum implements public private protected readonly as declare namespace abstract keyof satisfies');
const clikeKeywords=wordSet('abstract as break case catch class const continue data default defer do else enum extends final finally for fun func go goto if implements import in interface internal is lateinit let namespace new object open override package private protected public return sealed static struct super switch this throw throws try typealias using val var void when where while yield chan range select fn impl mut pub mod trait use async await suspend companion init by lazy inline reified vararg operator infix tailrec annotation record');
const pyKeywords=wordSet('and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self');
const sqlKeywords=wordSet('SELECT FROM WHERE AND OR NOT INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE ALTER DROP INDEX VIEW JOIN LEFT RIGHT INNER OUTER FULL CROSS ON AS GROUP BY ORDER HAVING LIMIT OFFSET UNION ALL DISTINCT CASE WHEN THEN ELSE END IS LIKE IN BETWEEN EXISTS PRIMARY KEY FOREIGN REFERENCES DEFAULT UNIQUE CHECK CONSTRAINT DATABASE SCHEMA GRANT REVOKE COMMIT ROLLBACK BEGIN TRANSACTION IF DESC ASC WITH RETURNING CASCADE AUTO_INCREMENT INT INTEGER BIGINT SMALLINT VARCHAR CHAR TEXT DATE DATETIME TIMESTAMP BOOLEAN DECIMAL NUMERIC FLOAT DOUBLE REAL SERIAL USE SHOW REPLACE TRUNCATE ADD COLUMN RENAME TO EXPLAIN');
const xmlInside=[rule('tag',String.raw`<[/?!]?[\w:.-]*|[/?]?>`),rule('attr',String.raw`[\w:.-]+(?=\s*=)`),rule('string',String.raw`"[^"]*"|'[^']*'`),rule('punct','='),plainWord];
const grammars={
 json:[lineComment,blockComment,rule('key',dq+String.raw`(?=\s*:)`),rule('string',dq),rule('literal',String.raw`(?:true|false|null)(?![\w$])`),rule('number',num),rule('punct',String.raw`[{}\[\],:]`),plainWord],
 yaml:[hashComment,rule('keyword',String.raw`^(?:---|\.\.\.)(?=\s|$)`,'m'),
  rule('key',String.raw`(?<=^[ \t]*(?:-[ \t]+){0,3})(?:${dq}|${sq}|[^\s#'"\[\]{},:&*!|>-][^\n#]*?)(?=[ \t]*:(?:\s|$))`,'m'),
  rule('string',dq),rule('string',sq),rule('variable',String.raw`[&*][\w-]+|\$\{[^}\n]*\}`),
  rule('literal',String.raw`(?:true|false|yes|no|on|off|null|~)(?![\w.-])`,'i'),rule('number',num),rule('punct',String.raw`-(?=[ \t]|$)|[:{}\[\],|>]`,'m'),plainWord],
 ini:[rule('comment',String.raw`(?<=^[ \t]*)[;#].*`,'m'),rule('comment',String.raw`(?<=\s)#.*`),rule('type',String.raw`(?<=^[ \t]*)\[\[?[^\]\n]*\]\]?`,'m'),
  rule('keyword',String.raw`(?<=^[ \t]*)export(?=[ \t])`,'m'),rule('key',String.raw`(?<=^[ \t]*(?:export[ \t]+)?)(?:${dq}|[^\s=:#;\[][^=:\n]*?)(?=[ \t]*[=:])`,'m'),
  rule('string',String.raw`"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)`),rule('string',dq),rule('string',sq),rule('variable',String.raw`\$\{[^}\n]*\}|\$\w+|%\w+%`),
  rule('literal',String.raw`(?:true|false|yes|no|on|off|null)(?![\w.-])`,'i'),rule('number',num),rule('punct','[=:]'),plainWord],
 xml:[rule('comment',String.raw`<!--[\s\S]*?(?:-->|$)`),rule('string',String.raw`<!\[CDATA\[[\s\S]*?(?:\]\]>|$)`),
  {...rule('tag',String.raw`<[/?!]?[\w:.-]+(?:[^<>"']|"[^"]*"|'[^']*')*>`),inside:xmlInside},rule('literal',String.raw`&#?\w+;`),plainWord],
 shell:[rule('comment',String.raw`(?<=^|[\s;|&(])#.*`,'m'),rule('string',String.raw`"(?:[^"\\]|\\[\s\S])*"`),rule('string',String.raw`'[^']*'`),
  rule('variable',String.raw`\$(?:\{[^}\n]*\}|\w+|[@#?$!*0-9-])`),rule('key',String.raw`(?<=^[ \t]*(?:(?:export|local|readonly|declare)[ \t]+)?)[A-Za-z_]\w*(?==)`,'m'),
  keywordRule('if then else elif fi for while until do done case esac in function return exit export local readonly declare source alias unset set shift break continue eval exec trap select'),
  rule('func',String.raw`(?<=(?:^|[|;&(]|\$\(|\b(?:then|do|else|sudo|time|exec|xargs)[ \t])[ \t]*)[\w./~+-]+`,'m'),
  rule('attr',String.raw`(?<=\s)--?[A-Za-z][\w-]*`),rule('number',num),rule('punct',String.raw`&&|\|\||[|&;<>]`),rule(null,String.raw`[\w./~:@%+,-]+`)],
 powershell:[rule('comment',String.raw`<#[\s\S]*?(?:#>|$)`),rule('comment','#.*'),rule('string',String.raw`@"[\s\S]*?(?:\n"@|$)`),rule('string',String.raw`@'[\s\S]*?(?:\n'@|$)`),
  rule('string',String.raw`"(?:[^"\x60]|\x60[\s\S]|"")*"`),rule('string',String.raw`'(?:[^']|'')*'`),rule('literal',String.raw`\$(?:true|false|null)(?![\w:])`,'i'),
  rule('variable',String.raw`\$(?:\{[^}]*\}|[\w:?]+)`),rule('type',String.raw`\[[A-Za-z][\w.]*(?:\[\])?\]`),
  keywordRule('if elseif else foreach for while do until switch function filter param return break continue try catch finally throw trap in begin process end class enum using exit','i'),
  rule('func',String.raw`[A-Za-z]+-[A-Za-z]\w*`),rule('attr',String.raw`(?<![\w)\]])-[A-Za-z]\w*`),rule('number',num),rule('punct','[|;=(){}]'),rule(null,String.raw`[\w.]+`)],
 bat:[rule('comment',String.raw`(?<=^[ \t]*@?)(?:rem(?=[ \t]|$).*|::.*)`,'im'),rule('type',String.raw`(?<=^[ \t]*):[\w.-]+`,'m'),rule('string',String.raw`"[^"\n]*"`),
  rule('variable',String.raw`%%~?\w|%~?\d|%[^%\s]+%|![^!\s]+!`),
  keywordRule('echo set setlocal endlocal if else goto call exit for in do not exist defined errorlevel pause shift start cd pushd popd equ neq lss leq gtr geq','i'),
  rule('attr',String.raw`(?<=\s)/[A-Za-z?]\w*`),rule('number',num),rule('punct','[@=|&<>()]'),rule(null,String.raw`[\w.-]+`)],
 js:[lineComment,blockComment,rule('string',dq),rule('string',sq),rule('string',String.raw`\x60(?:[^\x60\\]|\\[\s\S])*\x60`),rule('attr',String.raw`@[\w.]+`),words(jsKeywords,literalWords,{types:true}),rule('number',num)],
 clike:[lineComment,blockComment,rule('string',String.raw`"""[\s\S]*?(?:"""|$)`),rule('string',dq),rule('string',sq),rule('string',String.raw`\x60[^\x60]*\x60`),rule('attr',String.raw`@[\w.]+`),
  words(clikeKeywords,literalWords,{types:true}),rule('number',String.raw`(?:0[xX][\da-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)[fFdDlLuU]*(?![\w.])`)],
 python:[rule('comment','#.*'),rule('string',String.raw`[rRbBuUfF]{0,2}(?:"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)|${dq}|${sq})`),rule('attr',String.raw`@[\w.]+`),words(pyKeywords,wordSet('True False None')),rule('number',num)],
 sql:[rule('comment','--.*'),blockComment,rule('string',String.raw`'(?:[^']|'')*'`),rule('key',String.raw`"[^"\n]*"|\x60[^\x60\n]*\x60`),words(sqlKeywords,wordSet('NULL TRUE FALSE'),{fold:true}),rule('number',num)],
 css:[blockComment,rule('string',dq),rule('string',sq),rule('keyword',String.raw`@[\w-]+|!important`),rule('number',String.raw`#[\da-fA-F]{3,8}(?![\w-])`),
  rule('key',String.raw`-{0,2}[A-Za-z][\w-]*(?=\s*:[^;{}]{0,500}[;}])`),rule('type',String.raw`[.#][A-Za-z_-][\w-]*`),
  rule('number',String.raw`-?(?:\d+\.?\d*|\.\d+)(?:%|[a-zA-Z]+)?(?![\w.])`),rule('variable',String.raw`\$[\w-]+`),rule('punct','[{}:;,>+~()]'),rule(null,String.raw`[\w-]+`)],
 conf:[hashComment,rule('comment',String.raw`(?<=^[ \t]*);.*`,'m'),rule('string',dq),rule('string',sq),rule('variable',String.raw`\$\{[^}\n]*\}|\$\w+`),
  rule('type',String.raw`(?<=^[ \t]*)(?:\[[^\]\n]+\]|<\/?[\w-]+[^>\n]*>)`,'m'),rule('key',String.raw`(?<=^[ \t]*)[A-Za-z_][\w.-]*`,'m'),
  rule('literal',String.raw`(?:on|off|true|false|yes|no)(?![\w.-])`,'i'),rule('number',String.raw`-?\d+(?:\.\d+)?[kKmMgGsShHdD%]?(?![\w.])`),rule('punct','[{};=]'),rule(null,String.raw`[\w.-]+`)],
 text:[]
};
// [type, text] pieces; a null type is plain text. Runs of spaces are skipped quickly: no rule starts with one.
function tokenize(code,rules,out=[]){
 const space=/[ \t\n]+/y;let i=0,text='';
 const flush=()=>{if(text){out.push([null,text]);text='';}};
 while(i<code.length){
  space.lastIndex=i;const gap=space.exec(code);if(gap){text+=gap[0];i+=gap[0].length;continue;}
  let hit=null;
  for(const r of rules){r.re.lastIndex=i;const m=r.re.exec(code);if(m&&m[0]){hit=[r,m[0]];break;}}
  if(!hit){text+=code[i++];continue;}
  const [r,match]=hit,end=i+match.length,type=typeof r.type==='function'?r.type(match,code,end):r.type;
  if(r.inside){flush();tokenize(match,r.inside,out);}else if(type){flush();out.push([type,match]);}else text+=match;
  i=end;
 }
 flush();return out;
}
// A guess good enough for the colours; the format can always be chosen by hand. Every pattern stays within one line
// or a bounded stretch, so a long or odd text cannot make the guess slow.
function detectLang(code){
 const s=(code||'').replace(/\r\n?/g,'\n').trim(),has=re=>re.test(s);if(!s)return 'text';
 if(/^[{[]/.test(s)){try{JSON.parse(s);return 'json';}catch{}if(has(/^[ \t]*"[^"\n]+"[ \t]*:/m))return 'json';}
 if(s.startsWith('<'))return 'xml';
 if(has(/^#!.*\b(?:ba|z|da)?sh\b/))return 'shell';
 if(has(/^[ \t]*(?:server|location|http|upstream|events|stream)\b[^\n{]*\{/m)||has(/^[ \t]*(?:Host|HostName|IdentityFile|ProxyCommand)[ \t]+\S/m))return 'conf';
 if(has(/^[ \t]*@echo[ \t]+off\b/im)||has(/^[ \t]*(?:rem[ \t]|::)/im)||has(/%~?\w+%/)&&has(/^[ \t]*(?:set|if|goto|call)[ \t]/im))return 'bat';
 if(has(/\b(?:Get|Set|New|Remove|Add|Start|Stop|Write|Import|Export|Invoke|Test|Copy|Move|Out|Select|Where|ForEach)-[A-Z][A-Za-z]+/)||has(/^[ \t]*\$[\w:]+[ \t]*=/m)||has(/^[ \t]*param[ \t]*\(/im))return 'powershell';
 if(has(/^[ \t]*(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|WITH|GRANT)\s[\s\S]{0,2000}?\b(?:FROM|INTO|TABLE|SET|VIEW|INDEX|DATABASE|AS|ON)\b/im))return 'sql';
 if(has(/^[ \t]*(?:package[ \t]+[\w.]+|(?:public|private|internal|protected)[ \t]+(?:static[ \t]+)?(?:class|fun|void|val|interface)\b|fun[ \t]+\w+|val[ \t]+\w+[ \t]*[:=]|func[ \t]+\w+|using[ \t]+System)/m))return 'clike';
 if(has(/^[ \t]*(?:def[ \t]+\w+[ \t]*\(|class[ \t]+\w+.*:[ \t]*$|if[ \t]+__name__)/m)||has(/^[ \t]*(?:from[ \t]+[\w.]+[ \t]+import[ \t]|import[ \t]+[\w.]+[ \t]*$)/m)&&!has(/[{};][ \t]*$/m))return 'python';
 // Commands typed at the start of a line (indented ones may be a YAML script block).
 if(has(/^(?:(?:git|npm|npx|pnpm|yarn|docker|kubectl|curl|wget|ssh|scp|cd|ls|sudo|apt|apt-get|brew|pip|pip3|echo|export|source|chmod|chown|mkdir|cp|mv|rm|systemctl|adb|gradle)(?=[ \t]|$)|\.\/\S)/m))return 'shell';
 if(has(/^[ \t]*(?:(?:const|let|var|function)[ \t]|import[ \t].*[ \t]from[ \t]|import[ \t]*['"{]|export[ \t]+(?:default|const|let|var|function|class|async|type|interface|\{)|module\.exports)|=>/m))return 'js';
 if(has(/^[ \t]*\[[^\]\n]+\][ \t]*$/m)&&has(/^[ \t]*[\w."-]+[ \t]*=/m)||has(/^[ \t]*(?:export[ \t]+)?[A-Z][A-Z0-9_]*=/m))return 'ini';
 if(has(/^[ \t]*(?:-[ \t]+)?[\w"'.-]+[ \t]*:(?:[ \t]|$)/m)&&!has(/[;{][ \t]*$/m))return 'yaml';
 if(has(/\{/)&&has(/(?<![\w-])[\w-]+[ \t]*:[ \t]*[^;{}\n]{1,300};/))return 'css';
 if(has(/^[ \t]*[\w.-]+[ \t]*=/m))return 'ini';
 if(has(/(?:^|\s)#\s/m))return 'conf';
 return 'text';
}
// The format a config is drawn in: the one chosen, or else the guess (kept per record value, since lists redraw often).
const guessed=new WeakMap();
function formatOf(r){
 if(grammars[r.lang])return r.lang;
 if(!guessed.has(r))guessed.set(r,detectLang(r.body));
 return guessed.get(r);
}
// One element per line, so the line numbers (drawn by CSS, never copied) stay beside lines that wrap. Returns the count.
function renderCode(element,code,format){
 const source=(code||'').replace(/\r\n?/g,'\n').replace(/\n+$/,''),lines=[];
 const newLine=()=>{const line=document.createElement('span');line.className='code-line';lines.push(line);return line;};
 let line=newLine();
 for(const [type,text] of tokenize(source,grammars[format]||[]))text.split('\n').forEach((part,index)=>{
  if(index)line=newLine();if(!part)return;
  if(!type){line.append(part);return;}
  const span=document.createElement('span');span.className='tk-'+type;span.textContent=part;line.append(span);
 });
 element.style.setProperty('--gutter',String(lines.length).length+'ch');element.replaceChildren(...lines);
 return lines.length;
}
function backupData(raw){
 const data=raw?.format==='tnotes-encrypted-backup-v1'?raw.data:null,p=data?.profile;
 const envelope=e=>!!e&&typeof e.iv==='string'&&typeof e.data==='string';
 if(!p||typeof p.id!=='string'||typeof p.name!=='string'||typeof p.salt!=='string'||!envelope(p.check)||!Array.isArray(data.items)||!data.items.every(x=>x&&typeof x.id==='string'&&envelope(x.envelope)))throw Error('这不是有效的 T Notes 加密备份文件');
 return data;
}
async function readBackup(file){
 if(file.size>32*1024*1024)throw Error('备份文件过大，无法读取');
 let raw;try{raw=JSON.parse(await file.text());}catch{throw Error('这不是有效的 T Notes 加密备份文件');}
 return backupData(raw);
}
// Merging never overwrites: records this computer lacks come back as they were, and records
// whose content differs are added beside the current version as a copy.
async function importBackup(file){
 const data=await readBackup(file);
 if(data.profile.id!==profile().id)throw Error('这个备份属于另一个资料库（'+data.profile.name+'），不能合并到当前资料库');
 const incoming=[];
 try{for(const item of data.items)incoming.push([item,await decrypt(keys.key,profile().id,item.id,item.envelope)]);}
 catch{throw Error('备份内容校验失败，文件可能已损坏，未导入任何记录');}
 const signature=r=>JSON.stringify([r.kind,r.title,r.body,r.tag,r.account,r.password,r.site,r.note||'',r.lang||'']);
 let restored=0,copies=0;
 await exclusive(async()=>{
  const before=cache.data.items.length,added=[],known=new Set([...plain.values()].map(signature));
  for(const [item,value] of incoming){
   const local=plain.get(item.id);
   if(!local){
    // Revision 0 marks it as a new write: a server that lost the record accepts it, one that still has it matches the ciphertext.
    cache.data.items.push({id:item.id,rev:0,envelope:item.envelope,pending:true});added.push([item.id,value]);known.add(signature(value));restored++;continue;
   }
   if(value.deleted||signature(local)===signature(value))continue;
   const duplicate={...value,title:value.title+'（备份副本）',pinned:false,deleted:false,updated:Date.now()};
   // Importing the same file twice must not pile up copies.
   if(known.has(signature(duplicate)))continue;
   const id=crypto.randomUUID();
   cache.data.items.push({id,rev:0,envelope:await encrypt(keys.key,profile().id,id,duplicate),pending:true});added.push([id,duplicate]);known.add(signature(duplicate));copies++;
  }
  if(!added.length)return;
  try{await persist();}catch(e){cache.data.items.length=before;throw e;}
  for(const [id,value] of added)plain.set(id,value);
 });
 if(restored+copies){if(editing)renderList();else openDefaultRecord();void sync();}
 return {restored,copies};
}
function setRestoring(data){
 restoring=data;
 $('restore-hint').hidden=!data;$('username').readOnly=!!data;$('auth-mode').hidden=!!data;
 $('restore-backup').textContent=data?'取消恢复':'从加密备份恢复';
 $('auth-submit').querySelector('span').textContent=data?'恢复资料库':createMode?'创建加密资料库':'登录资料库';
 if(data){
  $('username').value=data.profile.name;$('auth-error').textContent='';
  $('restore-hint').textContent='已选择备份“'+data.profile.name+'”，共 '+data.items.length+' 条记录。输入它的主密码完成恢复。';$('master').focus();
 }
}
function showBackup(info){
 $('backup-dir').value=info.dir;
 const summary=info.latest?'最近一次 '+new Date(info.latest.time).toLocaleString([],{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'})+' · 共 '+info.count+' 份':'尚未生成备份，创建资料库后自动开始';
 $('backup-state').textContent=info.error?'上次备份失败：'+info.error:summary;
}
async function loadBackup(){try{showBackup(await api('/api/backup'));}catch(e){$('backup-state').textContent=e.message;}}
function clearUnlocked(){
 if(!library)closeBig();keys=null;token=null;plain.clear();selected=null;dirty=false;editing=false;remembered=false;lastSyncError='';
 $('master').value='';$('master-confirm').value='';$('workspace').hidden=true;$('auth-screen').hidden=false;$('lock-state').textContent='未登录';
 for(const id of [...fields,'prompt-output','view-password','search','quick-search','tag-filter','todo-add-quick','todo-add-library','todo-title-quick','todo-title-library','todo-tag-quick','todo-tag-library'])$(id).value='';
 todoTag='';for(const id of ['todo-add-quick','todo-add-library'])fitTodoBox($(id));
 for(const id of ['todo-tags-quick','todo-tags-library','todo-tag-list'])$(id).replaceChildren();
 for(const menu of document.querySelectorAll('.todo-tag-menu')){menu.hidden=true;menu.replaceChildren();}
 for(const id of ['read-title','read-body','read-tag','read-when','read-account','read-site','read-format','read-lines'])$(id).textContent='';
 $('record-list').replaceChildren();$('recent-list').replaceChildren();$('variables').replaceChildren();$('read-code').replaceChildren();
 for(const d of document.querySelectorAll('dialog[open]'))d.close();closeRowMenu();
 for(const id of ['view','lock','sync-now','export','import','backup-now'])$(id).disabled=true;
 status('已退出登录');notice('');
}
async function lockInner(){
 if(!keys)return;if(dirty)await saveInner();
 await api('/api/session',{method:'DELETE'});
 clearUnlocked();channel.postMessage({type:'logout'});
}
function authMode(){
 createMode=!createMode;$('confirm-row').hidden=!createMode;$('create-warning').hidden=!createMode;
 $('master-confirm').required=createMode;$('auth-submit').querySelector('span').textContent=createMode?'创建加密资料库':'登录资料库';
 $('auth-mode').textContent=createMode?'已有资料库，返回登录':'创建新资料库';
 $('master').autocomplete=createMode?'new-password':'current-password';$('auth-error').textContent='';
}
async function finishLogin(){
 plain=await decryptAll(cache.data.items);if(createMode)authMode();
 $('master').value='';$('master-confirm').value='';$('auth-screen').hidden=true;$('workspace').hidden=false;$('lock-state').textContent=profile().name;
 $('restore-backup').hidden=true;
 for(const id of ['view','lock','sync-now','export','import','backup-now'])$(id).disabled=false;
 restorePlace();status('本机已登录');
 if(!library)$('quick-search').focus({preventScroll:true});
}
$('auth-form').addEventListener('submit',async event=>{
 event.preventDefault();if(busy)return;busy=true;$('auth-submit').disabled=true;$('auth-error').textContent='';
 try {
  const name=$('username').value.trim(),master=$('master').value;
  const remember=!!config.rememberSupported&&$('remember').checked;
  cache=await api('/api/cache');
  if(restoring){
   if(cache.data)throw Error('本机已有资料库。请先登录，再到“同步与备份”中导入这个备份。');
   const p=restoring.profile;keys=await derive(master,p.salt,remember);
   // Nothing is written until the master password has verified every record in the file.
   try{
    if((await decrypt(keys.key,p.id,'check',p.check)).ok!=='tnotes-v1')throw Error('check');
    for(const item of restoring.items)await decrypt(keys.key,p.id,item.id,item.envelope);
   }catch{throw Error('主密码错误，或备份文件已损坏');}
   // Revision 0 and pending: a server that lost the vault receives every record again, and one
   // that still has it matches them by ciphertext without creating duplicates.
   cache.data={profile:p,items:restoring.items.map(x=>({id:x.id,rev:0,envelope:x.envelope,pending:true})),enrolled:false,lastSync:null};
   await persist();setRestoring(null);
  } else if(createMode){
   if(cache.data)throw Error('本机已有资料库，请先使用原资料库登录并导出备份，不会覆盖现有数据。');
   if(master.length<12)throw Error('主密码至少 12 个字符，建议使用不重复的长口令。');
   if(master!==$('master-confirm').value)throw Error('两次主密码不一致');
   const p={id:crypto.randomUUID(),name,salt:randomSalt(),kdf:'pbkdf2-sha256-hkdf-v1'};
   keys=await derive(master,p.salt,remember);p.check=await encrypt(keys.key,p.id,'check',{ok:'tnotes-v1'});
   if(config.remote){if(!config.enrollment)throw Error('此电脑没有首次初始化授权。已有资料库请返回登录。');await api('/v1/register',{method:'POST',body:{...p,auth:keys.auth}});config.enrollment=false;}
   cache.data={profile:p,items:[],enrolled:!!config.remote,lastSync:null};await persist();
  } else {
   if(cache.data&&cache.data.profile.name!==name)throw Error('此电脑已有其他资料库，不能直接覆盖。请使用已缓存的资料库名称。');
   let p=cache.data?.profile;
   if(!p){if(!config.remote)throw Error('本机没有资料库且服务器尚未配置');p=await api('/v1/profile?name='+encodeURIComponent(name));}
   keys=await derive(master,p.salt,remember);let check;
   try{check=await decrypt(keys.key,p.id,'check',p.check);}catch{throw Error('主密码错误或资料库数据损坏');}
   if(check.ok!=='tnotes-v1')throw Error('资料库校验失败');
   if(!cache.data){cache.data={profile:p,items:[],enrolled:true,lastSync:null};await persist();}
  }
  try {
   if(remember){await api('/api/session',{method:'PUT',body:{version:1,vaultId:profile().id,encryptionKey:keys.material,auth:keys.auth}});remembered=true;}
   else{await api('/api/session',{method:'DELETE'});remembered=false;}
  }catch{notice('本次登录成功，但未能记住这台电脑。下次打开仍需要主密码。','keep');}
  keys.material=null;
  await finishLogin();void sync();
 }catch(e){keys=null;token=null;$('auth-error').textContent=e.message;}
 finally{busy=false;$('auth-submit').disabled=false;}
});
$('auth-mode').addEventListener('click',authMode);
$('restore-backup').addEventListener('click',()=>{if(restoring)setRestoring(null);else $('restore-file').click();});
$('restore-file').addEventListener('change',async event=>{
 const file=event.target.files[0];event.target.value='';if(!file)return;
 try{const data=await readBackup(file);if(createMode)authMode();setRestoring(data);}
 catch(e){$('auth-error').textContent=e.message;}
});
$('view').addEventListener('click',()=>setView(!library));$('open-library').addEventListener('click',()=>setView(true));
$('lock').addEventListener('click',guarded(()=>exclusive(lockInner)));
$('save').addEventListener('click',guarded(save));$('sync-now').addEventListener('click',guarded(()=>sync(true)));
for(const id of ['new-record','quick-new','new-from-empty'])$(id).addEventListener('click',()=>{if(mayLeave())resetEditor();});
$('edit').addEventListener('click',()=>{if(selected)loadEditor(selected,true);});
$('back-to-list').addEventListener('click',showQuickList);
$('cancel-edit').addEventListener('click',()=>{if(mayLeave()){if(selected)loadEditor(selected);else openDefaultRecord();}});
for(const id of fields)$(id).addEventListener('input',markDirty);
$('body').addEventListener('input',formatHint);
for(const id of ['body','note','todo-add-quick','todo-add-library'])$(id).addEventListener('paste',event=>{if(id==='body'&&$('kind').value==='config')return;pasteRich(event);});
$('kind').addEventListener('change',()=>{markDirty();categorySelection($('kind').value);updateKind();renderList();});
$('pin').addEventListener('click',guarded(async()=>{
 if(editing){pinned=!pinned;markDirty();$('pin').setAttribute('aria-pressed',String(pinned));return;}
 if(!selected)return;
 const id=selected;updateRecords([id],r=>({pinned:!r.pinned}));loadEditor(id);
}));
$('done').addEventListener('click',guarded(()=>selected&&toggleDone(selected)));
for(const [button,input] of [['reveal','password'],['view-reveal','view-password']])$(button).addEventListener('click',()=>{$(input).type=$(input).type==='password'?'text':'password';});
$('generate').addEventListener('click',()=>{
 const alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%&*';let result='';
 while(result.length<22){const [n]=crypto.getRandomValues(new Uint8Array(1));if(n<Math.floor(256/alphabet.length)*alphabet.length)result+=alphabet[n%alphabet.length];}
 $('password').value=result;markDirty();
});
$('copy').addEventListener('click',guarded(()=>copy($('body').value)));
$('copy-code').addEventListener('click',guarded(()=>copy(plain.get(selected)?.body||'')));
for(const id of ['copy-account','view-copy-account'])$(id).addEventListener('click',guarded(()=>copy($('account').value)));
for(const id of ['copy-password','view-copy-password'])$(id).addEventListener('click',guarded(()=>copy($('password').value,true)));
$('delete').addEventListener('click',guarded(async()=>{
 if(!selected)return;if(!mayLeave())return;const r=plain.get(selected),restoreRecord=!!r.deleted;
 if(!confirm(restoreRecord?'恢复这条记录？':'将这条记录移到回收站？'))return;
 updateRecords([selected],()=>({deleted:!restoreRecord}));
 selected=null;editing=false;dirty=false;openDefaultRecord();notice(restoreRecord?'已恢复':'已移到回收站');
}));
document.querySelectorAll('[data-filter]').forEach(b=>b.addEventListener('click',()=>chooseCategory(b.dataset.filter)));
document.querySelectorAll('[data-quick-filter]').forEach(b=>b.addEventListener('click',()=>chooseCategory(b.dataset.quickFilter)));
for(const id of ['search','quick-search','tag-filter'])$(id).addEventListener('input',renderList);
// Enter adds the to-do, from the title, text or tag box; Shift+Enter or Ctrl+Enter starts a new line in the text box
// (from the title it goes on to the text box).
// While an input method is composing, Enter only confirms the candidate. Escape closes the tag list, empties the title
// or text box, or puts the tag box back to the tag being filtered by.
// The tag box opens a list of the tags to-dos have used: all of them on focus or with the arrow, narrowed while typing.
// Several lines pasted into the one-line title box go to the text box instead, so no line break is lost.
for(const [boxId,tagId,titleId] of [['todo-add-quick','todo-tag-quick','todo-title-quick'],['todo-add-library','todo-tag-library','todo-title-library']]){
 const box=$(boxId),tagBox=$(tagId),titleBox=$(titleId),menu=tagBox.parentElement.querySelector('.todo-tag-menu'),arrow=tagBox.parentElement.querySelector('.todo-tag-open');
 titleBox.addEventListener('paste',event=>{
  const text=event.clipboardData?.getData('text/plain')||'';if(!/\n/.test(text.trim()))return;
  event.preventDefault();box.focus();box.setSelectionRange(box.value.length,box.value.length);
  document.execCommand('insertText',false,(box.value&&!box.value.endsWith('\n')?'\n':'')+(richPaste(event.clipboardData)??text));fitTodoBox(box);
 });
 const closeMenu=()=>{menu.hidden=true;};
 const showMenu=(typed=false)=>{
  const query=typed?tagBox.value.trim().toLowerCase():'',current=tagBox.value.trim();
  const tags=todoTagHistory().filter(tag=>tag.toLowerCase().includes(query));
  menu.replaceChildren(...tags.map(tag=>{
   const option=document.createElement('button');option.type='button';option.textContent=tag;option.classList.toggle('active',tag===current);
   // Pressing keeps the focus in the tag box, so choosing does not close the list before the click lands.
   option.addEventListener('mousedown',event=>event.preventDefault());
   option.addEventListener('click',()=>{tagBox.value=tag;closeMenu();titleBox.focus();});
   return option;
  }));
  menu.hidden=!tags.length;
 };
 tagBox.addEventListener('focus',()=>showMenu());tagBox.addEventListener('input',()=>showMenu(true));tagBox.addEventListener('blur',closeMenu);
 arrow.addEventListener('mousedown',event=>event.preventDefault());
 arrow.addEventListener('click',()=>{if(!menu.hidden)closeMenu();else if(document.activeElement===tagBox)showMenu();else tagBox.focus();});
 box.addEventListener('input',()=>fitTodoBox(box));
 for(const field of [box,tagBox,titleBox])field.addEventListener('keydown',event=>{
  if(event.isComposing)return;
  if(event.key==='Enter'&&field===box&&(event.shiftKey||event.ctrlKey)){if(event.ctrlKey){event.preventDefault();document.execCommand('insertText',false,'\n');}return;}
  // In the one-line title, a new line means going on to the text under it.
  if(event.key==='Enter'&&field===titleBox&&(event.shiftKey||event.ctrlKey)){event.preventDefault();box.focus();return;}
  if(event.key==='Enter'){event.preventDefault();closeMenu();addTodo(box,tagBox,titleBox);return;}
  if(event.key!=='Escape')return;
  if(field===tagBox&&!menu.hidden){event.stopPropagation();closeMenu();}
  else if(field===box&&box.value){event.stopPropagation();box.value='';fitTodoBox(box);}
  else if(field===titleBox&&titleBox.value){event.stopPropagation();titleBox.value='';}
  else if(field===tagBox&&tagBox.value!==todoTag){event.stopPropagation();tagBox.value=todoTag;}
 });
}
$('notice').addEventListener('click',()=>notice(''));
$('error-log').addEventListener('click',()=>{drawErrors();$('error-dialog').showModal();});
$('error-clear').addEventListener('click',()=>{errorLog=[];keepErrors();drawErrors();});
showErrors();
$('settings').addEventListener('click',()=>{
 $('server-url').textContent=config.remote||'尚未配置';$('pending-count').textContent=pending();
 $('remember-state').textContent=remembered?'已记住这台电脑 · Windows 用户加密保护':'未记住登录';
 $('settings-dialog').showModal();void loadBackup();
});
document.querySelectorAll('[data-close]').forEach(b=>b.addEventListener('click',()=>$(b.dataset.close).close()));
// A message still showing when its dialog closes moves back to the page instead of vanishing with it.
document.querySelectorAll('dialog').forEach(dialog=>dialog.addEventListener('close',()=>{if(dialog.contains($('notice')))document.body.append($('notice'));}));
$('backup-dir-save').addEventListener('click',guarded(async()=>{
 showBackup(await api('/api/backup',{method:'PUT',body:{dir:$('backup-dir').value.trim()}}));notice('备份文件夹已更新');
}));
$('backup-now').addEventListener('click',guarded(async()=>{
 // Waiting in the queue also lets changes still being saved in the background land first.
 await exclusive(async()=>{if(dirty)await saveInner();});
 const info=await api('/api/backup',{method:'POST'});showBackup(info);notice('已备份到 '+info.dir);
}));
$('export').addEventListener('click',guarded(async()=>{
 await exclusive(async()=>{if(dirty)await saveInner();});
 const raw=JSON.stringify({format:'tnotes-encrypted-backup-v1',data:cache.data});
 const url=URL.createObjectURL(new Blob([raw],{type:'application/json'}));const a=document.createElement('a');
 a.href=url;a.download='tnotes-encrypted-'+new Date().toISOString().slice(0,10)+'.json';a.click();
 setTimeout(()=>URL.revokeObjectURL(url),1000);notice('已导出加密备份；恢复时仍需要主密码。');
}));
$('import').addEventListener('click',()=>$('import-file').click());
$('import-file').addEventListener('change',guarded(async event=>{
 const file=event.target.files[0];event.target.value='';if(!file||!keys)return;
 const {restored,copies}=await importBackup(file);$('settings-dialog').close();
 notice(restored+copies?'导入完成：恢复 '+restored+' 条记录，另存 '+copies+' 条“备份副本”。':'备份中的记录本机都已存在，没有需要导入的内容。','keep');
}));
$('fill-prompt').addEventListener('click',()=>openPromptDialog($('body').value));
$('copy-prompt').addEventListener('click',guarded(async()=>{await copy($('prompt-output').value);$('prompt-dialog').close();}));
document.addEventListener('keydown',event=>{
 const key=event.key.toLowerCase(),open=!!document.querySelector('dialog[open]');
 if((event.ctrlKey||event.metaKey)&&!event.altKey&&['s','n','t','f'].includes(key)){
  // An app window hands these to the page first. Left alone they open the browser's save dialog,
  // its find bar, or a second browser window, which this tool must never have.
  event.preventDefault();
  if(event.shiftKey||!keys||open)return;
  if(key==='s'){if(editing&&!$('save').disabled)$('save').click();}
  else if(key==='n'){if(mayLeave())resetEditor();}
  else if(key==='f')focusSearch();
  return;
 }
 if(event.key==='Escape'&&!event.isComposing&&keys&&!open){
  if(editing)$('cancel-edit').click();
  else if(!library&&!document.body.classList.contains('quick-list'))showQuickList();
  else{const box=library?$('search'):$('quick-search');if(box.value){box.value='';renderList();}}
 }
});
setInterval(()=>{if(keys&&config.remote)void sync();},30000);
window.addEventListener('online',()=>{if(keys)void sync();});
window.addEventListener('beforeunload',event=>{if(dirty||unsaved.size){event.preventDefault();event.returnValue='';}});
window.addEventListener('pagehide',rememberPlace);
$('recent-list').addEventListener('scroll',()=>{listScroll.quick=$('recent-list').scrollTop;rememberPlaceSoon();});
$('record-list').addEventListener('scroll',()=>{listScroll.library=$('record-list').scrollTop;rememberPlaceSoon();});
channel.onmessage=event=>{
 if(event.data.type==='logout'){
  void exclusive(async()=>{remembered=false;if(dirty)notice('另一窗口已退出登录。请先保存当前修改，再退出此窗口，避免丢失内容。','error');else clearUnlocked();});return;
 }
 if(event.data.version>cache.version&&keys)notice('另一窗口更新了记录。为避免覆盖，请退出后重新登录，再继续编辑。','error');
};
// A remembered login opens the vault without the master password. Right after Windows sign-in or a backend restart
// the local backend, or the Windows protection it unlocks the login with, may not answer yet; that is retried for
// about 20 seconds instead of falling back to the login screen. Only a definite answer (no remembered login, or one
// that does not match the vault) asks for the password.
for(let attempt=1;;attempt++){
 try{
  config=await api('/api/config');cache=await api('/api/cache');
  if(cache.data)$('username').value=cache.data.profile.name;
  // Restoring is only offered where it cannot overwrite anything: a computer without a vault.
  $('restore-backup').hidden=!!cache.data;
  $('remember-row').hidden=!config.rememberSupported;$('remember').checked=!!config.rememberSupported;
  $('connection-hint').textContent=config.remote?'已配置加密同步服务':'本机离线模式 · 可在部署后启用同步';
  const saved=await api('/api/session');
  if(saved.session&&cache.data){
   keys=await restore(saved.session);
   const check=await decrypt(keys.key,profile().id,'check',profile().check);
   if(check.ok!=='tnotes-v1')throw Error('本机登录记忆校验失败，请重新登录');
   remembered=true;$('auth-error').textContent='';await finishLogin();void sync();
  }
  break;
 }catch(e){
  keys=null;token=null;
  if(!e.transient||attempt>=14){$('auth-error').textContent=e.message;break;}
  $('auth-error').textContent='正在连接本机后台，自动登录中…';
  await new Promise(resolve=>setTimeout(resolve,1500));
 }
}
busy=false;$('auth-submit').disabled=false;
refreshIcons();

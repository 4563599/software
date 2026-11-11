import {derive,restore,encrypt,decrypt,randomSalt} from './crypto.js';
const $=id=>document.getElementById(id);
let csrf=document.querySelector('meta[name="tnotes-csrf"]').content;
const names={note:'备忘录',prompt:'AI 提示词',password:'账号密码'};
const icons={note:'sticky-note',prompt:'sparkles',password:'key-round'};
const refreshIcons=()=>globalThis.lucide?.createIcons();
const fields=['title','body','tag','account','password','site'];
let config={},cache={version:0,data:null},keys=null,token=null,plain=new Map(),selected=null;
let createMode=false,filter='all',quickFilter='all',dirty=false,pinned=false,library=false,editing=false,busy=true,remembered=false,clipboardTimer;
let serial=Promise.resolve();
const notice=text=>$('notice').textContent=text;
const channel=new BroadcastChannel('tnotes-cache');
function exclusive(task){const next=serial.then(task,task);serial=next.catch(()=>{});return next;}
async function api(url,options={}) {
 const body=options.body?JSON.stringify(options.body):undefined;
 for(let attempt=0;attempt<2;attempt++){
  const headers={'X-TNotes-CSRF':csrf,...options.headers};
  if(token)headers.Authorization='Bearer '+token;
  if(body)headers['Content-Type']='application/json';
  let res;try{res=await fetch(url,{...options,body,headers});}catch{throw Error('本机后台暂时无法连接，当前未保存的修改仍保留在窗口中。');}
  let data;try{data=await res.json();}catch{throw Error('服务返回了无法识别的响应');}
  // Rejected before dispatch: refreshing this token cannot duplicate a write.
  if(res.status===403&&data.code==='LOCAL_SESSION_STALE'&&attempt===0){
   const bootstrap=await fetch('/api/bootstrap',{cache:'no-store'});
   if(!bootstrap.ok)throw Error('本地连接无法恢复，请从 T 按钮重新打开');
   const fresh=await bootstrap.json();
   if(typeof fresh.csrf!=='string'||!/^[a-f0-9]{64}$/.test(fresh.csrf))throw Error('本地服务校验失败，请重新打开');
   csrf=fresh.csrf;continue;
  }
  if(!res.ok){const e=Error(data.error||'操作失败');e.status=res.status;throw e;}return data;
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
 if(!config.remote)throw Error('服务器尚未配置，记录已加密保存在本机');
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
async function syncInner(retried=false){
 if(!keys)return;status('同步中…');
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
  for(const item of incoming){const local=cache.data.items.find(x=>x.id===item.id);if(local?.pending)continue;if(local)Object.assign(local,item,{pending:false});else cache.data.items.push({...item,pending:false});plain.set(item.id,verified.get(item.id));}
  cache.data.lastSync=Date.now();await persist();
  if(!editing){if(selected&&plain.has(selected))loadEditor(selected,false,!document.body.classList.contains('quick-list'));else openDefaultRecord();}
  renderList();
  status(pending()?String(pending())+' 条等待同步':'已同步 · '+new Date().toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}));
  if(conflicts)notice('已保留 '+conflicts+' 个冲突副本，请在资料库中核对。');
 } catch(e){if(e.status===401){token=null;if(!retried)return syncInner(true);}status(pending()?'离线 · '+pending()+' 条待同步':'同步未完成');notice(e.message);}
}
const sync=()=>exclusive(()=>syncInner());
function updateKind(){
 const secret=$('kind').value==='password';
 $('secret-fields').hidden=!secret;$('prompt-tools').hidden=$('kind').value!=='prompt';
 $('body-label').textContent=secret?'备注':'内容';$('password').type='password';
}
function recordFromForm(){return {kind:$('kind').value,title:$('title').value.trim()||'未命名记录',body:$('body').value,tag:$('tag').value.trim(),pinned,account:$('account').value,password:$('password').value,site:$('site').value,deleted:false,updated:Date.now()};}
function orderedRecords(){return [...plain].sort((a,b)=>Number(b[1].pinned)-Number(a[1].pinned)||b[1].updated-a[1].updated);}
function isRecordKind(value){return Object.prototype.hasOwnProperty.call(names,value);}
function categorySelection(value){filter=value;quickFilter=value==='trash'?'all':value;}
function syncCategoryButtons(){
 for(const [selector,current,field] of [['[data-filter]',filter,'filter'],['[data-quick-filter]',quickFilter,'quickFilter']]){
  document.querySelectorAll(selector).forEach(button=>{const active=button.dataset[field]===current;button.classList.toggle('active',active);button.setAttribute('aria-pressed',String(active));});
 }
}
function libraryRecords(){
 const query=$('search').value.toLowerCase(),tag=$('tag-filter').value.toLowerCase();
 return orderedRecords().filter(([,r])=>(filter==='trash'?r.deleted:!r.deleted)&&(filter==='all'||filter==='trash'||r.kind===filter||(filter==='pinned'&&r.pinned))&&(!tag||r.tag.toLowerCase().includes(tag))&&(!query||(r.title+' '+r.body+' '+r.account).toLowerCase().includes(query)));
}
function chooseCategory(value){
 const draft=editing&&selected===null;
 if(library&&editing&&!draft&&!mayLeave())return;
 categorySelection(value);
 if(draft&&isRecordKind(value)){
  if($('kind').value!==value){$('kind').value=value;dirty=true;$('edited').textContent='未保存的修改';}
  updateKind();
 }else if(library&&!draft){openDefaultRecord();}
 renderList();
}
function setEditing(value){
 editing=value;$('edit-fields').hidden=!value;$('record-view').hidden=value;
 $('kind').hidden=!value;$('kind-label').hidden=value;$('edit').hidden=value;
 $('edit').disabled=!selected||!!plain.get(selected)?.deleted;
 $('pin').disabled=!selected&&!value;$('copy').disabled=!selected&&!value;
 $('delete').disabled=!selected;$('save').disabled=!!plain.get(selected)?.deleted;
}
function showViewer(){
 const r=plain.get(selected);
 $('empty-record').hidden=!!r;$('read-content').hidden=!r;
 if(!r){$('kind-label').textContent='备忘录';$('edited').textContent='';$('prompt-tools').hidden=true;return;}
 $('kind-label').textContent=names[r.kind]||'记录';
 $('read-title').textContent=r.title;$('read-body').textContent=r.body||'';
 $('read-tag').textContent=r.tag||'';$('read-secret').hidden=r.kind!=='password';
 $('read-account').textContent=r.account||'';$('view-password').value=r.password||'';
 $('view-password').type='password';$('read-site').textContent=r.site||'';
 $('read-site-row').hidden=!r.site;$('prompt-tools').hidden=r.kind!=='prompt';
}
function resetEditor(){
 document.body.classList.remove('quick-list');
 const category=library?filter:quickFilter;
 if(category==='trash')categorySelection('all');
 selected=null;$('kind').value=isRecordKind(category)?category:'note';for(const id of fields)$(id).value='';
 pinned=false;$('pin').setAttribute('aria-pressed','false');$('edited').textContent='新建记录';
 dirty=false;updateKind();setEditing(true);renderList();$('title').focus();
}
function loadEditor(id,edit=false,open=true){
 const r=plain.get(id);if(!r)return;selected=id;
 document.body.classList.toggle('quick-list',!open);
 for(const field of fields)$(field).value=r[field]||'';
 $('kind').value=r.kind;pinned=!!r.pinned;$('pin').setAttribute('aria-pressed',String(pinned));
 $('edited').textContent=(r.deleted?'已移到回收站 · ':'更新于 ')+new Date(r.updated).toLocaleString();
 dirty=false;updateKind();setEditing(edit&&!r.deleted);showViewer();renderList();
 try{localStorage.setItem('tnotes-last-viewed',id);}catch{}
}
function openDefaultRecord(){
 let previous;try{previous=localStorage.getItem('tnotes-last-viewed');}catch{}
 const candidates=library?libraryRecords():orderedRecords().filter(([,r])=>!r.deleted);
 const available=new Set(candidates.map(([id])=>id));
 const wanted=available.has(selected)?selected:available.has(previous)?previous:candidates[0]?.[0];
 if(wanted){loadEditor(wanted,false,false);return;}
 selected=null;for(const id of fields)$(id).value='';pinned=false;dirty=false;
 $('pin').setAttribute('aria-pressed','false');setEditing(false);showViewer();if(library&&isRecordKind(filter))$('kind-label').textContent=names[filter];document.body.classList.add('quick-list');renderList();
}
function mayLeave(){return !dirty||confirm('当前修改尚未保存。确定放弃这次修改吗？');}
function showQuickList(){
 if(!mayLeave())return;
 if(selected)loadEditor(selected,false,false);else openDefaultRecord();
 $('quick-search').focus({preventScroll:true});
}
function setView(value){if(!value&&!mayLeave())return;library=value;document.body.classList.toggle('library',library);$('app-title').textContent=library?'我的资料库':'随手记';try{window.resizeTo(library?1060:470,library?820:810);}catch{}if(!library){if(selected)loadEditor(selected,false,false);else openDefaultRecord();$('quick-search').focus({preventScroll:true});}else renderList();}
function renderList(){
 syncCategoryButtons();
 const quickQuery=$('quick-search').value.toLowerCase();
 const ordered=orderedRecords(),matches=(r,q)=>!q||(r.title+' '+r.body+' '+r.account).toLowerCase().includes(q);
 const visible=libraryRecords();
 function draw(container,rows,previews=false){
  container.replaceChildren();
  if(!rows.length){const p=document.createElement('p');p.className='empty';p.textContent='暂无记录';container.append(p);return;}
  for(const [id,r]of rows){
   const b=document.createElement('div');b.className='record'+(id===selected?' active':'');b.dataset.id=id;
   const open=document.createElement('button');open.className='record-open';open.title='查看记录';open.setAttribute('aria-label','查看 '+r.title);
   const i=document.createElement('i');i.dataset.lucide=icons[r.kind]||'file-text';
   const wrap=document.createElement('div'),title=document.createElement('strong'),meta=document.createElement('small');
   title.textContent=r.title;meta.textContent=names[r.kind]+' · '+(r.tag||'未分类')+(cache.data.items.find(x=>x.id===id)?.pending?' · 待同步':'');
   wrap.append(title,meta);
   if(previews){const preview=document.createElement('p');preview.className='record-preview';preview.textContent=r.kind==='password'?(r.account||'未填写账户'):(r.body||'');wrap.append(preview);}
   open.append(i,wrap);open.addEventListener('click',()=>{if(mayLeave())loadEditor(id);});b.append(open);
   const actions=document.createElement('div');actions.className='record-actions';
   const action=(icon,label,text,secret=false)=>{
    const button=document.createElement('button');button.title=label;button.setAttribute('aria-label',label);button.disabled=!text;
    const drawIcon=name=>{const symbol=document.createElement('i');symbol.dataset.lucide=name;button.replaceChildren(symbol);refreshIcons();};
    const symbol=document.createElement('i');symbol.dataset.lucide=icon;button.append(symbol);
    button.addEventListener('click',guarded(async()=>{
     await copy(text,secret);button.classList.add('copied');drawIcon('check');
     setTimeout(()=>{if(button.isConnected){button.classList.remove('copied');drawIcon(icon);}},1400);
    }));actions.append(button);
   };
   if(!r.deleted){if(r.kind==='password'){action('user-round','复制账号',r.account);action('key-round','复制密码',r.password,true);}else action('copy',r.body?'复制内容':'复制标题',r.body||r.title);}
   b.append(actions);container.append(b);
  }
 }
 const quickRows=ordered.filter(([,r])=>!r.deleted&&matches(r,quickQuery)&&(quickFilter==='all'||r.kind===quickFilter||(quickFilter==='pinned'&&r.pinned)));
 draw($('record-list'),visible);draw($('recent-list'),quickRows,true);$('quick-count').textContent=quickRows.length+' 条';refreshIcons();
}
async function saveInner(){
 if(!keys)return;
 const id=selected||crypto.randomUUID(),value=recordFromForm();
 const encoded=await encrypt(keys.key,profile().id,id,value);
 const existing=cache.data.items.find(r=>r.id===id),previous=existing?{...existing}:null;
 if(existing){existing.envelope=encoded;existing.pending=true;}else cache.data.items.push({id,rev:0,envelope:encoded,pending:true});
 try{await persist();}catch(e){if(previous)Object.assign(existing,previous);else cache.data.items=cache.data.items.filter(x=>x.id!==id);throw e;}
 plain.set(id,value);selected=id;dirty=false;loadEditor(id,false,library);
 status('本机已加密保存 · '+pending()+' 条待同步');notice('已保存');
}
async function save(){await exclusive(saveInner);void sync();}
async function copy(text,secret=false){
 await navigator.clipboard.writeText(text);notice(secret?'已复制密码，30 秒后尝试清除剪贴板':'已复制');
 if(secret){clearTimeout(clipboardTimer);clipboardTimer=setTimeout(async()=>{try{if(await navigator.clipboard.readText()===text)await navigator.clipboard.writeText('');}catch{notice('浏览器未允许自动清除剪贴板，请手动覆盖已复制的密码');}},30000);}
}
function guarded(fn){return async event=>{try{await fn(event);}catch(e){notice(e.message);}};}
function clearUnlocked(){
 keys=null;token=null;plain.clear();selected=null;dirty=false;editing=false;remembered=false;
 $('master').value='';$('master-confirm').value='';$('workspace').hidden=true;$('auth-screen').hidden=false;$('lock-state').textContent='未登录';
 for(const id of [...fields,'prompt-output','view-password','search','quick-search','tag-filter'])$(id).value='';
 for(const id of ['read-title','read-body','read-tag','read-account','read-site'])$(id).textContent='';
 $('record-list').replaceChildren();$('recent-list').replaceChildren();$('variables').replaceChildren();
 for(const d of document.querySelectorAll('dialog[open]'))d.close();
 for(const id of ['view','lock','sync-now','export'])$(id).disabled=true;
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
 for(const id of ['view','lock','sync-now','export'])$(id).disabled=false;
 openDefaultRecord();status('本机已登录');
 if(!library)$('quick-search').focus({preventScroll:true});
}
$('auth-form').addEventListener('submit',async event=>{
 event.preventDefault();if(busy)return;busy=true;$('auth-submit').disabled=true;$('auth-error').textContent='';
 try {
  const name=$('username').value.trim(),master=$('master').value;
  const remember=!!config.rememberSupported&&$('remember').checked;
  cache=await api('/api/cache');
  if(createMode){
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
  }catch{notice('本次登录成功，但未能记住这台电脑。下次打开仍需要主密码。');}
  keys.material=null;
  await finishLogin();void sync();
 }catch(e){keys=null;token=null;$('auth-error').textContent=e.message;}
 finally{busy=false;$('auth-submit').disabled=false;}
});
$('auth-mode').addEventListener('click',authMode);
$('view').addEventListener('click',()=>setView(!library));$('open-library').addEventListener('click',()=>setView(true));
$('lock').addEventListener('click',guarded(()=>exclusive(lockInner)));
$('save').addEventListener('click',guarded(save));$('sync-now').addEventListener('click',guarded(sync));
for(const id of ['new-record','quick-new','new-from-empty'])$(id).addEventListener('click',()=>{if(mayLeave())resetEditor();});
$('edit').addEventListener('click',()=>{if(selected)loadEditor(selected,true);});
$('back-to-list').addEventListener('click',showQuickList);
$('cancel-edit').addEventListener('click',()=>{if(mayLeave()){if(selected)loadEditor(selected);else openDefaultRecord();}});
for(const id of fields)$(id).addEventListener('input',()=>{dirty=true;$('edited').textContent='未保存的修改';});
$('kind').addEventListener('change',()=>{dirty=true;$('edited').textContent='未保存的修改';categorySelection($('kind').value);updateKind();renderList();});
$('pin').addEventListener('click',guarded(async()=>{
 if(editing){pinned=!pinned;dirty=true;$('pin').setAttribute('aria-pressed',String(pinned));return;}
 if(!selected)return;
 await exclusive(async()=>{
  const id=selected,value={...plain.get(id),pinned:!plain.get(id).pinned,updated:Date.now()};
  const item=cache.data.items.find(x=>x.id===id),previous={...item};
  item.envelope=await encrypt(keys.key,profile().id,id,value);item.pending=true;
  try{await persist();}catch(e){Object.assign(item,previous);throw e;}
  plain.set(id,value);loadEditor(id);
 });void sync();
}));
for(const [button,input] of [['reveal','password'],['view-reveal','view-password']])$(button).addEventListener('click',()=>{$(input).type=$(input).type==='password'?'text':'password';});
$('generate').addEventListener('click',()=>{
 const alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%&*';let result='';
 while(result.length<22){const [n]=crypto.getRandomValues(new Uint8Array(1));if(n<Math.floor(256/alphabet.length)*alphabet.length)result+=alphabet[n%alphabet.length];}
 $('password').value=result;dirty=true;
});
$('copy').addEventListener('click',guarded(()=>copy($('body').value)));
for(const id of ['copy-account','view-copy-account'])$(id).addEventListener('click',guarded(()=>copy($('account').value)));
for(const id of ['copy-password','view-copy-password'])$(id).addEventListener('click',guarded(()=>copy($('password').value,true)));
$('delete').addEventListener('click',guarded(async()=>{
 if(!selected)return;if(!mayLeave())return;const r=plain.get(selected),restoreRecord=!!r.deleted;
 if(!confirm(restoreRecord?'恢复这条记录？':'将这条记录移到回收站？'))return;
 await exclusive(async()=>{
  const id=selected,item=cache.data.items.find(x=>x.id===id),previous={...item};
  const value={...r,deleted:!restoreRecord,updated:Date.now()};
  item.envelope=await encrypt(keys.key,profile().id,id,value);item.pending=true;
  try{await persist();}catch(e){Object.assign(item,previous);throw e;}
  plain.set(id,value);selected=null;editing=false;dirty=false;openDefaultRecord();
 });void sync();
}));
document.querySelectorAll('[data-filter]').forEach(b=>b.addEventListener('click',()=>chooseCategory(b.dataset.filter)));
document.querySelectorAll('[data-quick-filter]').forEach(b=>b.addEventListener('click',()=>chooseCategory(b.dataset.quickFilter)));
for(const id of ['search','quick-search','tag-filter'])$(id).addEventListener('input',renderList);
$('settings').addEventListener('click',()=>{
 $('server-url').textContent=config.remote||'尚未配置';$('pending-count').textContent=pending();
 $('remember-state').textContent=remembered?'已记住这台电脑 · Windows 用户加密保护':'未记住登录';
 $('settings-dialog').showModal();
});
document.querySelectorAll('[data-close]').forEach(b=>b.addEventListener('click',()=>$(b.dataset.close).close()));
$('export').addEventListener('click',guarded(async()=>{
 if(dirty)await exclusive(saveInner);
 const raw=JSON.stringify({format:'tnotes-encrypted-backup-v1',data:cache.data});
 const url=URL.createObjectURL(new Blob([raw],{type:'application/json'}));const a=document.createElement('a');
 a.href=url;a.download='tnotes-encrypted-'+new Date().toISOString().slice(0,10)+'.json';a.click();
 setTimeout(()=>URL.revokeObjectURL(url),1000);notice('已导出加密备份；恢复时仍需要主密码。');
}));
$('fill-prompt').addEventListener('click',()=>{
 const template=$('body').value;const variables=[...new Set([...template.matchAll(/\{\{([^{}]+)\}\}/g)].map(m=>m[1]))];$('variables').replaceChildren();
 const update=()=>{let text=template;for(const input of $('variables').querySelectorAll('input'))text=text.split('{{'+input.dataset.variable+'}}').join(input.value);$('prompt-output').value=text;};
 for(const name of variables){const label=document.createElement('label'),input=document.createElement('input');label.textContent=name;input.dataset.variable=name;input.addEventListener('input',update);label.append(input);$('variables').append(label);}
 update();$('prompt-dialog').showModal();
});
$('copy-prompt').addEventListener('click',guarded(()=>copy($('prompt-output').value)));
setInterval(()=>{if(keys&&config.remote)void sync();},30000);
window.addEventListener('online',()=>{if(keys)void sync();});
window.addEventListener('beforeunload',event=>{if(dirty){event.preventDefault();event.returnValue='';}});
channel.onmessage=event=>{
 if(event.data.type==='logout'){
  void exclusive(async()=>{remembered=false;if(dirty)notice('另一窗口已退出登录。请先保存当前修改，再退出此窗口，避免丢失内容。');else clearUnlocked();});return;
 }
 if(event.data.version>cache.version&&keys)notice('另一窗口更新了记录。为避免覆盖，请退出后重新登录，再继续编辑。');
};
try{
 config=await api('/api/config');cache=await api('/api/cache');
 if(cache.data)$('username').value=cache.data.profile.name;
 $('remember-row').hidden=!config.rememberSupported;$('remember').checked=!!config.rememberSupported;
 $('connection-hint').textContent=config.remote?'已配置加密同步服务':'本机离线模式 · 可在部署后启用同步';
 const saved=await api('/api/session');
 if(saved.session&&cache.data){
  keys=await restore(saved.session);
  const check=await decrypt(keys.key,profile().id,'check',profile().check);
  if(check.ok!=='tnotes-v1')throw Error('本机登录记忆校验失败，请重新登录');
  remembered=true;await finishLogin();void sync();
 }
}catch(e){keys=null;token=null;$('auth-error').textContent=e.message;}
finally{busy=false;$('auth-submit').disabled=false;}
refreshIcons();

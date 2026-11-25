// Local-only UI test: no sync server, throwaway data directories, fictional records.
// Covers layout, messages, shortcuts, search, trash, prompt variables, to-dos, configs, daily backup, import and restore.
const {chromium}=require('playwright');
const {spawn,spawnSync}=require('node:child_process');
const crypto=require('node:crypto');
const fs=require('node:fs');
const net=require('node:net');
const os=require('node:os');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const work=fs.mkdtempSync(path.join(os.tmpdir(),'tnotes-ui-test-'));
const master=crypto.randomBytes(15).toString('base64');
const secret='QA-'+crypto.randomBytes(9).toString('hex');
const children=[];
const assert=(condition,message)=>{if(!condition)throw Error(message);};
const freePort=()=>new Promise((resolve,reject)=>{const probe=net.createServer();probe.once('error',reject);probe.listen(0,'127.0.0.1',()=>{const {port}=probe.address();probe.close(()=>resolve(port));});});
async function startBackend(port,dataDir,extraEnv={}){
 fs.mkdirSync(dataDir,{recursive:true});
 // A config path that does not exist keeps the test away from any real sync server.
 const child=spawn(process.execPath,[path.join(root,'client','desktop.cjs')],{env:{...process.env,TNOTES_PORT:String(port),TNOTES_DATA:dataDir,TNOTES_CONFIG:path.join(dataDir,'no-server.json'),...extraEnv},stdio:'ignore',windowsHide:true});
 children.push(child);
 for(let attempt=0;attempt<60;attempt++){
  try{if((await (await fetch('http://127.0.0.1:'+port+'/health')).json()).app==='TNotes')return child;}catch{}
  await new Promise(resolve=>setTimeout(resolve,100));
 }
 throw Error('Test backend did not start');
}
const today=()=>{const d=new Date();return [d.getFullYear(),d.getMonth()+1,d.getDate()].map(n=>String(n).padStart(2,'0')).join('-');};
const backups=dir=>fs.existsSync(dir)?fs.readdirSync(dir).filter(name=>/^tnotes-backup-\d{4}-\d{2}-\d{2}\.json$/.test(name)).sort():[];
function browserPreferences(){
 const script=path.join(root,'client','browser-prefs.cjs'),profile=path.join(work,'profile');
 const run=()=>spawnSync(process.execPath,[script,profile]).status;
 const read=()=>JSON.parse(fs.readFileSync(path.join(profile,'Default','Preferences'),'utf8'));
 assert(run()===0&&read().credentials_enable_service===false&&read().profile.password_manager_enabled===false,'New profile still offers to save passwords');
 fs.writeFileSync(path.join(profile,'Default','Preferences'),JSON.stringify({credentials_enable_service:true,profile:{name:'kept'},browser:{window_placement:{left:5}}}));
 assert(run()===0,'Preferences update failed');
 const merged=read();
 assert(merged.credentials_enable_service===false&&merged.profile.password_manager_enabled===false&&merged.autofill.profile_enabled===false,'Existing profile still offers to save passwords');
 assert(merged.profile.name==='kept'&&merged.browser.window_placement.left===5,'Unrelated browser preferences were lost');
 fs.writeFileSync(path.join(profile,'Default','Preferences'),'{broken');
 assert(run()===3&&fs.readFileSync(path.join(profile,'Default','Preferences'),'utf8')==='{broken','An unreadable preferences file was overwritten');
}
(async()=>{
 browserPreferences();
 const portA=await freePort(),portB=await freePort(),dataA=path.join(work,'a'),dataB=path.join(work,'b');
 let backendA=await startBackend(portA,dataA);await startBackend(portB,dataB);
 const browser=await chromium.launch({headless:true,channel:'chrome'});
 try{
  const errors=[];
  const open=async port=>{
   const context=await browser.newContext({viewport:{width:470,height:810}});
   await context.addInitScript(()=>{window.qaClipboard='';Object.defineProperty(navigator,'clipboard',{value:{writeText:async value=>{window.qaClipboard=value;},readText:async()=>window.qaClipboard}});});
   const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));page.on('dialog',dialog=>dialog.accept());
   await page.goto('http://127.0.0.1:'+port);await page.waitForFunction(()=>!document.querySelector('#auth-submit').disabled);
   return page;
  };
  const toast=(page,text,error=false)=>page.waitForFunction(([wanted,red])=>{const box=document.getElementById('notice');return box.classList.contains('show')&&box.classList.contains('error')===red&&box.textContent.includes(wanted);},[text,error],{timeout:15000});
  const row=(page,title)=>page.locator('#recent-list .record').filter({has:page.getByText(title,{exact:true})});
  const rows=page=>page.locator('#recent-list .record').count();
  const addRecord=async(page,title,fill)=>{
   await page.keyboard.press('Control+n');await page.locator('#title').waitFor({state:'visible'});
   await fill();await page.locator('#title').fill(title);await page.keyboard.press('Control+s');await row(page,title).waitFor();
  };

  const a=await open(portA);
  assert(await a.locator('#restore-backup').isVisible(),'Restore is not offered on a computer without a vault');
  await a.locator('#auth-mode').click();
  await a.locator('#username').fill('qa-local');await a.locator('#master').fill(master);await a.locator('#master-confirm').fill(master);await a.locator('#remember').uncheck();
  await a.locator('#auth-submit').click();await a.locator('#workspace').waitFor({state:'visible',timeout:20000});
  await a.waitForFunction(()=>document.getElementById('sync-label').textContent.includes('未配置同步服务器'));
  assert(!await a.locator('#notice.show').count(),'A vault without a sync server reported an error');
  assert(await a.locator('#restore-backup').isHidden(),'Restore is still offered after a vault exists');

  // Shortcuts and messages.
  await a.keyboard.press('Control+n');await a.locator('#title').waitFor({state:'visible'});
  await a.locator('#title').fill('Alpha note');await a.locator('#body').fill('first body');await a.locator('#tag').fill('工作');
  await a.keyboard.press('Control+s');await toast(a,'已保存');await row(a,'Alpha note').waitFor();
  await a.waitForFunction(()=>!document.getElementById('notice').classList.contains('show'),null,{timeout:8000});
  await addRecord(a,'Mail',async()=>{await a.locator('#kind').selectOption('password');await a.locator('#account').fill('user@example.com');await a.locator('#password').fill(secret);await a.locator('#site').fill('https://mail.example.com');});
  await addRecord(a,'Explain',async()=>{await a.locator('#kind').selectOption('prompt');await a.locator('#body').fill('解释 {{topic}} 给 {{who}}');});

  // Choosing a record type also selects its category, so go back to all records first.
  await a.locator('[data-quick-filter="all"]').click();assert(await rows(a)===3,'Records are missing from the list');

  // Search covers tags and sites; Ctrl+F focuses it and Escape clears it.
  await a.keyboard.press('Control+f');assert(await a.evaluate(()=>document.activeElement.id)==='quick-search','Ctrl+F did not focus the search box');
  await a.locator('#quick-search').fill('mail.example');assert(await rows(a)===1&&await row(a,'Mail').count()===1,'Search did not match the site');
  await a.locator('#quick-search').fill('工作');assert(await rows(a)===1&&await row(a,'Alpha note').count()===1,'Search did not match the tag');
  await a.locator('#quick-search').fill(secret);assert(await rows(a)===0,'Passwords became searchable');
  await a.keyboard.press('Escape');assert(await a.locator('#quick-search').inputValue()===''&&await rows(a)===3,'Escape did not clear the search');

  // A prompt with variables asks for them instead of copying the raw template.
  await row(a,'Explain').getByRole('button',{name:'填充变量后复制',exact:true}).click();
  await a.locator('#prompt-dialog').waitFor({state:'visible'});
  await a.locator('#variables input').nth(0).fill('泛型');await a.locator('#variables input').nth(1).fill('新手');await a.locator('#variables input').nth(1).press('Enter');
  await a.locator('#prompt-dialog').waitFor({state:'hidden'});
  assert(await a.evaluate(()=>window.qaClipboard)==='解释 泛型 给 新手','Filled prompt was not copied');
  await row(a,'Alpha note').getByRole('button',{name:'复制内容',exact:true}).click();assert(await a.evaluate(()=>window.qaClipboard)==='first body','One-click copy failed');

  // With many records only the list scrolls; search and footer stay in view.
  for(let index=1;index<=14;index++)await addRecord(a,'Filler '+index,async()=>{await a.locator('#body').fill('filler body '+index);});
  const layout=await a.evaluate(()=>{
   const list=document.getElementById('recent-list'),footer=document.querySelector('footer').getBoundingClientRect(),search=document.getElementById('quick-search').getBoundingClientRect();
   list.scrollTop=list.scrollHeight;
   return {page:document.documentElement.scrollHeight<=innerHeight,list:list.scrollHeight>list.clientHeight&&list.scrollTop>0,footer:Math.abs(footer.bottom-innerHeight)<=1,search:search.top>=0&&search.bottom<=innerHeight};
  });
  assert(layout.page&&layout.list&&layout.footer&&layout.search,'Fixed layout regressed: '+JSON.stringify(layout));
  await a.evaluate(()=>{document.getElementById('recent-list').scrollTop=0;});

  // Trash: the button restores, and says so.
  await a.locator('#quick-search').fill('Alpha');await row(a,'Alpha note').locator('.record-open').click();
  assert(await a.locator('#delete').getAttribute('title')==='移到回收站','Delete button is mislabelled');
  await a.locator('#delete').click();await toast(a,'已移到回收站');
  await a.locator('#view').click();await a.locator('[data-filter="trash"]').click();await a.locator('#record-list .record-open').first().click();
  assert(await a.locator('#delete').getAttribute('title')==='恢复记录'&&await a.locator('#delete svg.lucide-undo-2').count()===1,'Trash still shows a delete button instead of restore');
  await a.locator('#delete').click();await toast(a,'已恢复');
  await a.locator('[data-filter="all"]').click();assert(await a.locator('#record-list .record').filter({hasText:'Alpha note'}).count()===1,'Record was not restored');
  await a.locator('#view').click();await a.keyboard.press('Escape');
  await a.locator('#quick-search').fill('');await row(a,'Alpha note').locator('.record-open').click();await a.locator('#read-content').waitFor({state:'visible'});
  await a.keyboard.press('Escape');assert(await a.locator('body').evaluate(e=>e.classList.contains('quick-list')),'Escape did not return to the list');

  // Backup to a fixed folder: ciphertext only, old files pruned, other files untouched.
  const defaultDir=path.join(dataA,'backups'),chosenDir=path.join(work,'chosen backups');
  await a.locator('#settings').click();await a.waitForFunction(()=>document.getElementById('backup-dir').value.length>0);
  assert(await a.locator('#backup-dir').inputValue()===defaultDir,'Unexpected default backup folder');
  await a.locator('#backup-now').click();await toast(a,'已备份到');
  assert(await a.evaluate(()=>{const box=document.getElementById('notice'),r=box.getBoundingClientRect();return document.elementFromPoint(r.left+r.width/2,r.top+r.height/2)===box;}),'Message is hidden behind the dialog');
  const first=path.join(defaultDir,'tnotes-backup-'+today()+'.json'),firstText=fs.readFileSync(first,'utf8');
  assert(JSON.parse(firstText).format==='tnotes-encrypted-backup-v1'&&JSON.parse(firstText).data.items.length===17,'Backup file is incomplete');
  for(const plain of ['Alpha note','first body','user@example.com',secret,master])assert(!firstText.includes(plain),'Plaintext found in the backup file');
  for(let day=1;day<=34;day++)fs.writeFileSync(path.join(defaultDir,'tnotes-backup-2020-01-'+String(day).padStart(2,'0')+'.json'),'{}');
  fs.writeFileSync(path.join(defaultDir,'keep-me.txt'),'unrelated');
  await a.locator('#backup-now').click();await a.waitForFunction(()=>document.getElementById('backup-state').textContent.includes('共 30 份'));
  const kept=backups(defaultDir);
  assert(kept.length===30&&kept.includes('tnotes-backup-'+today()+'.json')&&!kept.includes('tnotes-backup-2020-01-05.json')&&fs.existsSync(path.join(defaultDir,'keep-me.txt')),'Backup retention regressed');
  await a.locator('#backup-dir').fill('backups');await a.locator('#backup-dir-save').click();await toast(a,'完整路径',true);
  await a.locator('#backup-dir').fill(chosenDir);await a.locator('#backup-dir-save').click();await toast(a,'备份文件夹已更新');
  const chosen=path.join(chosenDir,'tnotes-backup-'+today()+'.json');assert(fs.existsSync(chosen),'Changing the folder did not write a backup there');
  const snapshot=path.join(work,'snapshot.json');fs.copyFileSync(chosen,snapshot);
  await a.locator('[data-close="settings-dialog"]').click();

  // Import never overwrites: a changed record gets a copy, and importing twice adds nothing.
  await row(a,'Alpha note').locator('.record-open').click();await a.locator('#edit').click();await a.locator('#body').fill('changed body');await a.keyboard.press('Control+s');await toast(a,'已保存');
  await a.locator('#settings').click();await a.locator('#import-file').setInputFiles(snapshot);await toast(a,'恢复 0 条记录，另存 1 条');
  assert(await a.locator('#settings-dialog').isHidden(),'Import left the dialog open');
  assert(await row(a,'Alpha note（备份副本）').locator('.record-preview').innerText()==='first body'&&await row(a,'Alpha note').locator('.record-preview').innerText()==='changed body','Import did not keep both versions');
  await a.locator('#settings').click();await a.locator('#import-file').setInputFiles(snapshot);await toast(a,'没有需要导入的内容');
  const foreign=JSON.parse(fs.readFileSync(snapshot,'utf8'));foreign.data.profile.id=crypto.randomUUID();foreign.data.profile.name='other-vault';
  const foreignFile=path.join(work,'foreign.json'),brokenFile=path.join(work,'broken.json');fs.writeFileSync(foreignFile,JSON.stringify(foreign));fs.writeFileSync(brokenFile,'not a backup');
  await a.locator('#settings').click();await a.locator('#import-file').setInputFiles(foreignFile);await toast(a,'另一个资料库',true);
  await a.locator('#import-file').setInputFiles(brokenFile);await toast(a,'不是有效的',true);
  await a.locator('#notice').click();await a.locator('[data-close="settings-dialog"]').click();
  await addRecord(a,'Only on A',async()=>{await a.locator('#body').fill('made after the snapshot');});
  await a.locator('#settings').click();await a.locator('#backup-now').click();await toast(a,'已备份到');await a.locator('[data-close="settings-dialog"]').click();
  const later=path.join(work,'later.json');fs.copyFileSync(chosen,later);

  // Restore on a computer without a vault: nothing is written until the master password checks out.
  const b=await open(portB);
  await b.locator('#restore-file').setInputFiles(snapshot);await b.locator('#restore-hint').waitFor({state:'visible'});
  assert(await b.locator('#username').inputValue()==='qa-local'&&(await b.locator('#restore-hint').innerText()).includes('17 条'),'Restore did not describe the chosen backup');
  await b.locator('#master').fill('wrong-'+master);await b.locator('#remember').uncheck();await b.locator('#auth-submit').click();
  await b.waitForFunction(()=>document.getElementById('auth-error').textContent.includes('主密码错误'));
  assert(!fs.existsSync(path.join(dataB,'encrypted-cache.json')),'A failed restore wrote data');
  await b.locator('#master').fill(master);await b.locator('#auth-submit').click();await b.locator('#workspace').waitFor({state:'visible',timeout:20000});
  assert(await rows(b)===17&&await row(b,'Alpha note').locator('.record-preview').innerText()==='first body','Restore did not bring the records back');
  await b.locator('#settings').click();await b.locator('#import-file').setInputFiles(later);await toast(b,'恢复 2 条记录，另存 1 条');
  assert(await rows(b)===20&&await row(b,'Only on A').count()===1,'Import did not add the records this computer lacked');

  // The layout button grows the window to the library and back without drifting away from the T button.
  // A simulated window frame stands in for the real one; single_window_test.ps1 covers the real window.
  const frameOf=page=>page.evaluate(()=>({...window.qaFrame}));
  const sameFrame=(actual,expected,label)=>assert(['x','y','w','h'].every(key=>actual[key]===expected[key]),label+': '+JSON.stringify(actual)+' instead of '+JSON.stringify(expected));
  // Signs in with the master password unless a remembered login already opened the vault.
  const signIn=async page=>{
   await page.waitForFunction(()=>!document.querySelector('#auth-submit').disabled);
   if(await page.locator('#auth-screen').isVisible()){await page.locator('#master').fill(master);await page.locator('#remember').uncheck();await page.locator('#auth-submit').click();}
   await page.locator('#workspace').waitFor({state:'visible',timeout:20000});
  };
  // The frame outlives a reload of the page, like a real window.
  const simulate=async(frame,port=portA)=>{
   const context=await browser.newContext({viewport:{width:470,height:810}});
   await context.addInitScript(start=>{
    let saved=null;try{saved=JSON.parse(sessionStorage.getItem('qa-frame')||'null');}catch{}
    const state={...(saved||start)};window.qaFrame=state;const keep=()=>{try{sessionStorage.setItem('qa-frame',JSON.stringify(state));}catch{}};
    const define=(name,get)=>Object.defineProperty(window,name,{get,configurable:true});
    define('screenX',()=>state.x);define('screenY',()=>state.y);define('outerWidth',()=>state.w);define('outerHeight',()=>state.h);
    Object.defineProperty(window,'screen',{value:{availLeft:0,availTop:0,availWidth:1920,availHeight:1040},configurable:true});
    window.resizeTo=(w,h)=>{state.w=w;state.h=h;keep();};window.moveTo=(x,y)=>{state.x=x;state.y=y;keep();};
   },frame);
   const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));page.on('dialog',dialog=>dialog.accept());
   await page.goto('http://127.0.0.1:'+port);await signIn(page);
   return page;
  };
  // The library opens larger from the toolbar side: its right and bottom edges stay where the quick window's were and
  // it grows to the left and up, kept on the screen. It comes back exactly.
  const libraryFrame={x:440,y:26,w:1480,h:940};
  for(const [name,start,enlarged] of [['T at the right edge',{x:1450,y:156,w:470,h:810},libraryFrame],['T at the left edge',{x:0,y:156,w:470,h:810},{x:0,y:26,w:1480,h:940}],['T in the middle',{x:1100,y:156,w:470,h:810},{x:90,y:26,w:1480,h:940}]]){
   const page=await simulate(start);
   await page.locator('#view').click();sameFrame(await frameOf(page),enlarged,'Enlarged window ('+name+')');
   await page.locator('#view').click();sameFrame(await frameOf(page),start,'Window did not return ('+name+')');
   await page.context().close();
  }
  // Moved while enlarged (another click on T puts it above the button, here after the bar was dragged): the quick
  // window keeps its centre and bottom edge...
  const moved=await simulate({x:591,y:156,w:470,h:810});
  await moved.locator('#view').click();await moved.evaluate(()=>{window.qaFrame.x=100;window.qaFrame.y=26;});
  await moved.locator('#view').click();sameFrame(await frameOf(moved),{x:605,y:156,w:470,h:810},'Window moved while enlarged');
  // ...or stays against the screen edge it touches.
  await moved.locator('#view').click();await moved.evaluate(()=>{window.qaFrame.x=440;window.qaFrame.y=26;});
  await moved.locator('#view').click();sameFrame(await frameOf(moved),{x:1450,y:156,w:470,h:810},'Window moved to the right edge while enlarged');
  await moved.context().close();

  // The backend writes the daily file by itself after a restart.
  for(const name of backups(chosenDir))fs.unlinkSync(path.join(chosenDir,name));
  backendA.kill();await new Promise(resolve=>backendA.once('exit',resolve));backendA=await startBackend(portA,dataA);
  const deadline=Date.now()+15000;while(!fs.existsSync(chosen)){if(Date.now()>deadline)throw Error('Automatic daily backup was not written');await new Promise(resolve=>setTimeout(resolve,250));}
  assert(JSON.parse(fs.readFileSync(chosen,'utf8')).data.items.length===19,'Automatic backup is incomplete');

  // Web addresses in notes are links that open in the default browser. This backend writes what it
  // would open to a file instead of starting a browser.
  const portC=await freePort(),dataC=path.join(work,'c'),openLog=path.join(work,'opened.txt');
  await startBackend(portC,dataC,{TNOTES_OPEN_LOG:openLog});
  const c=await open(portC);
  await c.locator('#auth-mode').click();
  await c.locator('#username').fill('qa-links');await c.locator('#master').fill(master);await c.locator('#master-confirm').fill(master);await c.locator('#remember').uncheck();
  await c.locator('#auth-submit').click();await c.locator('#workspace').waitFor({state:'visible',timeout:20000});
  const linkBody='官网：https://example.com/a?b=1&c=2。\n文档 www.example.org/docs/(v2) 和 (https://wiki.example.net/x)\n不是链接：app.js';
  await addRecord(c,'Links',async()=>{await c.locator('#body').fill(linkBody);});
  await addRecord(c,'Bank',async()=>{await c.locator('#kind').selectOption('password');await c.locator('#account').fill('qa');await c.locator('#site').fill('bank.example.com');});
  await addRecord(c,'Plain',async()=>{await c.locator('#body').fill('没有网址 app.js');});
  await c.locator('[data-quick-filter="all"]').click();
  assert(await row(c,'Plain').getByRole('button',{name:'用默认浏览器打开链接',exact:true}).count()===0,'A record without an address offers to open a link');
  await row(c,'Links').locator('.record-open').click();await c.locator('#read-content').waitFor({state:'visible'});
  const shown=await c.locator('#read-body a.web-link').evaluateAll(links=>links.map(a=>a.textContent+' -> '+a.href));
  assert(JSON.stringify(shown)===JSON.stringify(['https://example.com/a?b=1&c=2 -> https://example.com/a?b=1&c=2','www.example.org/docs/(v2) -> https://www.example.org/docs/(v2)','https://wiki.example.net/x -> https://wiki.example.net/x']),'Links in a note regressed: '+JSON.stringify(shown));
  assert(await c.locator('#read-body').textContent()===linkBody,'Linking changed the note text');
  const before=c.url();
  await c.locator('#read-body a.web-link').first().click();await toast(c,'已用默认浏览器打开');
  assert(c.url()===before,'Clicking a link navigated the notes window');
  await c.keyboard.press('Escape');
  await row(c,'Bank').getByRole('button',{name:'用默认浏览器打开链接',exact:true}).click();await toast(c,'已用默认浏览器打开');
  await row(c,'Bank').locator('.record-open').click();
  assert(await c.locator('#read-site a.web-link').getAttribute('href')==='https://bank.example.com/','A bare website was not linked');
  assert(fs.readFileSync(openLog,'utf8')==='https://example.com/a?b=1&c=2\nhttps://bank.example.com/\n','Opened addresses regressed: '+fs.readFileSync(openLog,'utf8'));
  // The backend opens web addresses only, and only for the notes page itself.
  const refused=await c.evaluate(async()=>{
   const csrf=document.querySelector('meta[name="tnotes-csrf"]').content,send=(url,headers)=>fetch('/api/open-url',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify({url})}).then(r=>r.status);
   const statuses=[];
   for(const url of ['javascript:alert(1)','file:///C:/Windows/win.ini','https://user:pw@example.com/','https://exa mple.com','ms-settings:'])statuses.push(await send(url,{'X-TNotes-CSRF':csrf}));
   statuses.push(await send('https://example.com/',{}));
   return statuses;
  });
  assert(JSON.stringify(refused)==='[400,400,400,400,400,403]','Unsafe or foreign open requests were not refused: '+JSON.stringify(refused));
  assert(fs.readFileSync(openLog,'utf8').split('\n').filter(Boolean).length===2,'A refused address was opened');
  await c.context().close();

  // To-dos: added from the box with Enter, checked off in the list, finished ones fold under 已完成 and stay out of
  // the other lists. Editing keeps a to-do done, and 清除 moves the finished ones to the trash.
  const portE=await freePort(),dataE=path.join(work,'e');
  await startBackend(portE,dataE);
  const e=await open(portE);
  await e.locator('#auth-mode').click();
  await e.locator('#username').fill('qa-todo');await e.locator('#master').fill(master);await e.locator('#master-confirm').fill(master);
  await e.locator('#auth-submit').click();await e.locator('#workspace').waitFor({state:'visible',timeout:20000});
  await addRecord(e,'Plain note',async()=>{await e.locator('#body').fill('不是待办');});
  assert(await e.locator('#todo-add-quick').isHidden(),'The to-do box shows outside 待办');
  await e.locator('[data-quick-filter="todo"]').click();
  assert(await e.evaluate(()=>document.activeElement.id)==='todo-title-quick','Opening 待办 did not focus the add box');
  for(const title of ['Buy milk','Call Li','Write report']){await e.keyboard.type(title);await e.keyboard.press('Enter');await row(e,title).waitFor();}
  assert(await rows(e)===3&&await e.locator('#recent-list .record.todo').count()===3&&await e.locator('#todo-add-quick').inputValue()==='','To-dos were not added from the box');
  assert(await e.locator('#quick-count').textContent()==='3 条未完成','Wrong open count: '+await e.locator('#quick-count').textContent());
  await e.keyboard.type('draft');await e.keyboard.press('Escape');assert(await e.locator('#todo-title-quick').inputValue()==='','Escape did not empty the add box');
  // Checked off, it folds under 已完成 (closed at first); opened, the group shows it struck through, and it can be unchecked.
  await row(e,'Call Li').locator('.todo-check').click();await toast(e,'已完成');
  const heading=e.locator('#recent-list .todo-done-heading');
  assert(await rows(e)===2&&(await heading.innerText()).includes('已完成 1')&&await e.locator('#quick-count').textContent()==='2 条未完成','A finished to-do did not move under 已完成');
  await heading.getByRole('button',{name:'已完成 1'}).click();
  assert(await row(e,'Call Li').evaluate(el=>el.classList.contains('done')&&getComputedStyle(el.querySelector('strong')).textDecorationLine==='line-through'),'A finished to-do is not struck through');
  await row(e,'Call Li').locator('.todo-check').click();await toast(e,'已标为未完成');
  assert(await heading.count()===0&&await rows(e)===3,'Unchecking did not bring the to-do back');
  await row(e,'Call Li').locator('.todo-check').click();await toast(e,'已完成');
  // To-dos are a feature of their own: 全部 and its search never show them.
  await e.locator('[data-quick-filter="all"]').click();
  assert(await e.locator('#recent-list .record.todo').count()===0&&await row(e,'Plain note').count()===1&&await e.locator('#quick-count').textContent()==='1 条','全部 shows to-dos');
  await e.locator('#quick-search').fill('Buy');assert(await rows(e)===0,'The search in 全部 finds to-dos');await e.locator('#quick-search').fill('');
  // In the record a done button takes the place of copy, and editing keeps the to-do done.
  await e.locator('[data-quick-filter="todo"]').click();
  await row(e,'Buy milk').locator('.record-open').click();await e.locator('#read-content').waitFor({state:'visible'});
  assert(await e.locator('#done').isVisible()&&await e.locator('#copy').isHidden()&&await e.locator('#done').innerText()==='完成','A to-do has no done button');
  await e.locator('#done').click();await e.waitForFunction(()=>document.getElementById('done').getAttribute('aria-pressed')==='true');
  assert(await e.locator('#done').innerText()==='已完成'&&await e.locator('#read-title').evaluate(el=>el.classList.contains('done')),'The done button did not finish the to-do');
  assert(/^添加于 今天 \d{2}:\d{2} · 完成于 今天 \d{2}:\d{2}$/.test(await e.locator('#edited').textContent()),'The record does not say when it was added and finished: '+await e.locator('#edited').textContent());
  // Pinned, a to-do still stays out of 已置顶.
  await e.locator('#pin').click();await e.waitForFunction(()=>document.getElementById('pin').getAttribute('aria-pressed')==='true');
  await e.keyboard.press('Escape');await e.locator('[data-quick-filter="pinned"]').click();
  assert(await row(e,'Buy milk').count()===0,'A pinned to-do shows in 已置顶');
  await e.locator('[data-quick-filter="todo"]').click();await row(e,'Buy milk').locator('.record-open').click();await e.locator('#read-content').waitFor({state:'visible'});
  await e.locator('#edit').click();await e.locator('#body').fill('两盒');await e.keyboard.press('Control+s');await toast(e,'已保存');
  assert(await e.locator('#done').getAttribute('aria-pressed')==='true','Editing a finished to-do undid it');
  await e.locator('[data-quick-filter="todo"]').click();
  assert((await heading.innerText()).includes('已完成 2'),'Finished count is wrong');
  await heading.getByRole('button',{name:'清除'}).click();await toast(e,'已移到回收站');
  assert(await heading.count()===0&&await rows(e)===1&&await row(e,'Write report').count()===1,'清除 did not remove the finished to-dos');
  // Pasted text keeps its lines: the first is the title, the rest the note. The box grows with the text and shrinks back.
  const addBox=e.locator('#todo-add-quick');
  await addBox.fill('Release notes\n  - fix crash\n  - new icon\n');
  assert(await addBox.evaluate(el=>el.offsetHeight>60),'The add box did not grow with the text');
  await addBox.press('Enter');await row(e,'Release notes').waitFor();
  assert(await row(e,'Release notes').locator('.record-preview').textContent()==='  - fix crash\n  - new icon','Pasted lines were not kept');
  assert(await addBox.evaluate(el=>el.offsetHeight<50),'The add box did not shrink back');
  // Shift+Enter and Ctrl+Enter start a new line instead of adding.
  await e.keyboard.type('Two lines');await e.keyboard.press('Shift+Enter');await e.keyboard.type('second');await e.keyboard.press('Control+Enter');await e.keyboard.type('third');
  assert(await rows(e)===2,'Shift+Enter or Ctrl+Enter added the to-do');
  await e.keyboard.press('Enter');await row(e,'Two lines').waitFor();
  assert(await row(e,'Two lines').locator('.record-preview').textContent()==='second\nthird','Shift+Enter or Ctrl+Enter did not start a new line');
  // Tags: typed beside the box, shown in the list with the time, and offered as filters. Filtering by a tag gives
  // new to-dos that tag.
  assert(/^今天 \d{2}:\d{2}/.test(await row(e,'Write report').locator('small').textContent()),'The list does not show when a to-do was added');
  assert(await e.locator('#todo-tags-quick').isHidden(),'Tag filters show without any tags');
  await e.locator('#todo-tag-quick').fill('工作');await addBox.fill('Ship build');await addBox.press('Enter');await row(e,'Ship build').waitFor();
  const shipMeta=await row(e,'Ship build').locator('small').textContent();
  assert(/^工作今天 \d{2}:\d{2}/.test(shipMeta)&&await row(e,'Ship build').locator('.todo-tag').textContent()==='工作','The list does not show the tag and time: '+shipMeta);
  assert(await e.locator('#todo-tag-quick').inputValue()==='','The tag stayed in the box without a tag filter');
  await e.locator('#todo-tags-quick button',{hasText:'工作'}).click();
  assert(await rows(e)===1&&await e.locator('#todo-tag-quick').inputValue()==='工作','Filtering by tag failed');
  await addBox.fill('Write tests');await addBox.press('Enter');await row(e,'Write tests').waitFor();
  assert(await row(e,'Write tests').locator('.todo-tag').textContent()==='工作'&&await rows(e)===2,'A to-do added under a tag filter did not get the tag');
  assert(await e.locator('#todo-tags-quick button',{hasText:'工作'}).textContent()==='工作2','The tag filter does not count open to-dos');
  await e.locator('#todo-tags-quick button:not(.todo-tag-delete)',{hasText:'全部'}).click();
  assert(await rows(e)===5&&await e.locator('#todo-tag-quick').inputValue()==='','Showing all to-dos again failed');
  // The tag box lists the tags used before, newest first: all of them on focus, narrowed while typing; clicking one
  // fills it in and goes back to the text box. The arrow opens the list too, and Escape closes it.
  await e.locator('#todo-tag-quick').fill('生活');await addBox.fill('Plan trip');await addBox.press('Enter');await row(e,'Plan trip').waitFor();
  const tagMenu=e.locator('#todo-tag-quick ~ .todo-tag-menu'),menuTags=async()=>JSON.stringify(await tagMenu.locator('button').allTextContents());
  await e.locator('#todo-tag-quick').focus();await tagMenu.waitFor();
  assert(await menuTags()==='["生活","工作"]','The used tags are not listed newest first: '+await menuTags());
  await e.keyboard.type('工');assert(await menuTags()==='["工作"]','Typing does not narrow the used tags');
  await tagMenu.locator('button',{hasText:'工作'}).click();
  assert(await tagMenu.isHidden()&&await e.locator('#todo-tag-quick').inputValue()==='工作'&&await e.evaluate(()=>document.activeElement.id)==='todo-title-quick','Choosing a used tag failed');
  await e.keyboard.type('Review PR');await e.keyboard.press('Enter');await row(e,'Review PR').waitFor();
  assert(await row(e,'Review PR').locator('.todo-tag').textContent()==='工作','A chosen tag was not used');
  await e.locator('#todo-tag-quick ~ .todo-tag-open').click();await tagMenu.waitFor();
  await e.keyboard.press('Escape');assert(await tagMenu.isHidden(),'Escape did not close the tag list');
  // The library has the same box; the cleared to-dos are in the trash.
  await e.locator('#view').click();await e.locator('[data-filter="trash"]').click();
  assert(await e.locator('#record-list .record').count()===2,'Cleared to-dos are not in the trash');
  await e.locator('[data-filter="todo"]').click();
  assert(await e.evaluate(()=>document.activeElement.id)==='todo-title-library','Library 待办 did not focus its add box');
  await e.keyboard.type('From library');await e.keyboard.press('Enter');await e.locator('#record-list .record').filter({hasText:'From library'}).waitFor();
  await e.locator('#view').click();
  // Saved for good: they are there again after reopening.
  await e.reload();await e.locator('#workspace').waitFor({state:'visible',timeout:20000});
  assert(await e.locator('[data-quick-filter="todo"]').getAttribute('aria-pressed')==='true'&&await rows(e)===8&&await row(e,'From library').count()===1,'To-dos did not survive reopening');
  assert(await row(e,'Release notes').locator('.record-preview').textContent()==='  - fix crash\n  - new icon'&&await row(e,'Ship build').locator('.todo-tag').textContent()==='工作','Lines or tags were lost on reopening');
  // Adding and checking off show at once even while saving is slow (here every save waits 1.5 s, as behind a sync
  // with the server); the saves finish in the background and are kept.
  const savedVersion=()=>JSON.parse(fs.readFileSync(path.join(dataE,'encrypted-cache.json'),'utf8')).version,versionBefore=savedVersion();
  await e.route('**/api/cache',async route=>{if(route.request().method()==='PUT')await new Promise(resolve=>setTimeout(resolve,1500));await route.continue();});
  let started=Date.now();await addBox.fill('Instant');await addBox.press('Enter');await row(e,'Instant').waitFor({timeout:1000});
  const addMs=Date.now()-started;
  started=Date.now();await row(e,'Instant').locator('.todo-check').click();await heading.waitFor({timeout:1000});
  const checkMs=Date.now()-started;
  assert(addMs<1000&&checkMs<1000,'Adding or checking off waited for the save: '+addMs+' ms / '+checkMs+' ms');
  const saveDeadline=Date.now()+10000;
  while(savedVersion()<versionBefore+2){if(Date.now()>saveDeadline)throw Error('Background saves did not finish');await new Promise(resolve=>setTimeout(resolve,200));}
  await e.unroute('**/api/cache');
  await e.reload();await e.locator('#workspace').waitFor({state:'visible',timeout:20000});
  assert(await row(e,'Instant').count()===1&&(await heading.innerText()).includes('已完成 1'),'A change saved in the background was lost');
  // A chosen tag offers to move all its to-dos to the trash at once, finished ones included; the filter then shows all.
  assert(await e.locator('#todo-tags-quick .todo-tag-delete').count()===0,'Delete-all shows without a chosen tag');
  await row(e,'Write tests').locator('.todo-check').click();await toast(e,'已完成');
  await e.locator('#todo-tags-quick button',{hasText:'工作'}).click();
  const asked=new Promise(resolve=>e.once('dialog',dialog=>resolve(dialog.message())));
  await e.locator('#todo-tags-quick .todo-tag-delete').click();
  assert(await asked==='把标签“工作”的 3 条待办（其中 1 条已完成）移到回收站？','Delete-all asked: '+await asked);
  await toast(e,'已把 3 条待办移到回收站');
  assert(await e.locator('#todo-tags-quick button',{hasText:'工作'}).count()===0&&await e.locator('#todo-tag-quick').inputValue()===''&&await e.locator('#todo-tags-quick .todo-tag-delete').count()===0,'The tag filter did not go back to all');
  // A tag whose to-dos are all deleted is no longer offered in the tag box.
  await e.locator('#todo-tag-quick').focus();await tagMenu.waitFor();
  assert(await menuTags()==='["生活"]','A deleted tag is still offered: '+await menuTags());await e.keyboard.press('Escape');
  assert(await e.locator('#quick-count').textContent()==='5 条未完成'&&await row(e,'Ship build').count()===0&&await row(e,'Review PR').count()===0&&await row(e,'Plan trip').count()===1,'Delete-all removed the wrong to-dos');
  await e.locator('#view').click();await e.locator('[data-filter="trash"]').click();
  assert(await e.locator('#record-list .record').count()===5,'The tag\'s to-dos are not in the trash');
  await e.locator('#view').click();
  // Right-clicking a tag offers the same delete-all; right-clicking a to-do deletes just that one.
  await e.locator('[data-quick-filter="todo"]').click();
  await e.locator('#todo-tags-quick button',{hasText:'生活'}).click({button:'right'});
  await e.locator('#row-menu button',{hasText:'删除“生活”的全部待办'}).click();await toast(e,'已把 1 条待办移到回收站');
  assert(await row(e,'Plan trip').count()===0&&await e.locator('#quick-count').textContent()==='4 条未完成','Right-click on a tag did not delete its to-dos');
  await row(e,'Two lines').click({button:'right'});await e.locator('#row-menu button',{hasText:'删除'}).click();await toast(e,'已移到回收站');
  assert(await row(e,'Two lines').count()===0&&await e.locator('#quick-count').textContent()==='3 条未完成','Right-click did not delete the to-do');
  await row(e,'Write report').click({button:'right'});
  assert(JSON.stringify(await e.locator('#row-menu button').allTextContents())==='["查看","编辑","标记完成","置顶","复制文字","删除"]','The to-do menu is wrong');
  await e.locator('#row-menu button',{hasText:'标记完成'}).click();await toast(e,'已完成');
  assert(await e.locator('#quick-count').textContent()==='2 条未完成','Finishing from the menu failed');
  // The title box: a typed title names the to-do and keeps all of the text as its note, and the next one starts in the
  // title again. Shift+Enter goes on to the text; several lines pasted into the title go to the text box.
  const titleBox=e.locator('#todo-title-quick');
  await titleBox.fill('Release plan');await titleBox.press('Shift+Enter');
  assert(await e.evaluate(()=>document.activeElement.id)==='todo-add-quick','Shift+Enter in the title did not go on to the text');
  await e.keyboard.type('Step one');await e.keyboard.press('Shift+Enter');await e.keyboard.type('Step two');await e.keyboard.press('Enter');await row(e,'Release plan').waitFor();
  assert(await row(e,'Release plan').locator('.record-preview').textContent()==='Step one\nStep two'&&await titleBox.inputValue()===''&&await addBox.inputValue()===''&&await e.evaluate(()=>document.activeElement.id)==='todo-title-quick','A typed title did not keep the whole text as the note');
  await titleBox.evaluate(box=>{box.focus();const data=new DataTransfer();data.setData('text/plain','Line A\nLine B');box.dispatchEvent(new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true}));});
  assert(await titleBox.inputValue()===''&&await addBox.inputValue()==='Line A\nLine B'&&await e.evaluate(()=>document.activeElement.id)==='todo-add-quick','Lines pasted into the title did not go to the text box');
  await addBox.fill('');
  // A tag with nothing left to do is no filter any more, but the tag box still offers it while its to-dos exist.
  await e.locator('#todo-tag-quick').fill('收尾');await titleBox.fill('Wrap up');await titleBox.press('Enter');await row(e,'Wrap up').waitFor();
  assert(await e.locator('#todo-tags-quick button',{hasText:'收尾'}).count()===1,'A new tag is not offered as a filter');
  await row(e,'Wrap up').locator('.todo-check').click();await toast(e,'已完成');
  assert(await e.locator('#todo-tags-quick button',{hasText:'收尾'}).count()===0,'A tag with nothing left to do still shows as a filter');
  await e.locator('#todo-tag-quick').focus();await tagMenu.waitFor();
  assert((await tagMenu.locator('button').allTextContents()).includes('收尾'),'A tag of finished to-dos is not offered: '+await menuTags());await e.keyboard.press('Escape');
  // A failed save goes to the error log in the footer instead of a message over the page; the next successful save
  // strikes it out, and the log can be emptied.
  assert(await e.locator('#error-log').isHidden(),'The error log shows without errors');
  await e.route('**/api/cache',route=>route.request().method()==='PUT'?route.fulfill({status:500,contentType:'application/json',body:'{"error":"disk full"}'}):route.continue());
  await titleBox.fill('Will fail');await titleBox.press('Enter');
  await e.waitForFunction(()=>document.getElementById('error-log').classList.contains('open'));
  assert(await e.locator('#error-log').innerText()==='1 个错误'&&await e.locator('#notice.show.error').count()===0&&await row(e,'Will fail').count()===0,'A failed save was not logged, or covered the page');
  await e.unroute('**/api/cache');
  await titleBox.fill('Saved fine');await titleBox.press('Enter');await row(e,'Saved fine').waitFor();
  await e.waitForFunction(()=>!document.getElementById('error-log').classList.contains('open'));
  await e.locator('#error-log').click();await e.locator('#error-dialog').waitFor();
  const logged=await e.locator('#error-list li').evaluateAll(items=>items.map(li=>({done:li.classList.contains('done'),struck:getComputedStyle(li.querySelector('span')).textDecorationLine,text:li.querySelector('span').textContent,note:li.querySelector('small')?.textContent})));
  assert(logged.length===1&&logged[0].done&&logged[0].struck==='line-through'&&logged[0].text.startsWith('保存失败，已撤回这次修改')&&/^已于 今天 \d{2}:\d{2} 保存成功$/.test(logged[0].note),'The error was not struck out after a successful save: '+JSON.stringify(logged));
  assert(await e.locator('#error-log').innerText()==='错误日志','The footer still counts a settled error');
  await e.locator('#error-clear').click();await e.locator('[data-close="error-dialog"]').click();
  assert(await e.locator('#error-log').isHidden(),'Emptying the log did not hide it');
  await e.context().close();

  // Configs: code shown coloured with line numbers and its comments set apart, a 说明 under it, and the format guessed
  // or chosen. Like to-dos they are a feature of their own, never in 全部, 已置顶 or their search.
  const portF=await freePort(),dataF=path.join(work,'f');
  await startBackend(portF,dataF);
  const f=await open(portF);
  await f.locator('#auth-mode').click();
  await f.locator('#username').fill('qa-config');await f.locator('#master').fill(master);await f.locator('#master-confirm').fill(master);
  await f.locator('#auth-submit').click();await f.locator('#workspace').waitFor({state:'visible',timeout:20000});
  await addRecord(f,'Plain note',async()=>{await f.locator('#body').fill('不是配置');});
  const order=await f.evaluate(()=>['[data-quick-filter]','[data-filter]','#kind option'].map(selector=>[...document.querySelectorAll(selector)].map(el=>el.dataset.quickFilter||el.dataset.filter||el.value).join(',')));
  assert(JSON.stringify(order)===JSON.stringify(['all,note,prompt,password,config,todo,pinned','all,note,prompt,password,config,todo,pinned,trash','note,prompt,password,config,todo']),'配置 is not before 待办: '+JSON.stringify(order));
  assert(await f.evaluate(()=>document.getElementById('format-row').hidden&&document.getElementById('note-row').hidden),'A note shows the config fields');
  await f.locator('[data-quick-filter="config"]').click();
  assert(await f.locator('#quick-title').textContent()==='配置'&&await rows(f)===0,'The config list is not empty at first');
  const compose='# 本地开发\nservices:\n  db:\n    image: postgres:16   # 和线上同一版本\n    ports:\n      - "5432:5432"\n    restart: unless-stopped';
  await addRecord(f,'Compose',async()=>{
   assert(await f.locator('#kind').inputValue()==='config'&&await f.locator('#format-row').isVisible()&&await f.locator('#note-row').isVisible(),'A new record under 配置 is not a config');
   assert(await f.locator('#body-label').textContent()==='配置内容'&&await f.locator('#body').evaluate(el=>el.classList.contains('code')&&getComputedStyle(el).whiteSpace==='pre'),'The config box is not a code box');
   await f.locator('#body').fill(compose);
   assert(await f.locator('#lang option').first().textContent()==='自动识别 · YAML','The format is not guessed while typing');
   await f.locator('#note').fill('端口冲突时改成 5433');await f.locator('#tag').fill('部署');
  });
  assert((await row(f,'Compose').locator('small').textContent()).startsWith('YAML · 部署')&&await row(f,'Compose').locator('.record-preview').textContent()==='端口冲突时改成 5433','The config row does not show its format and 说明');
  await row(f,'Compose').locator('.record-open').click();await f.locator('#read-config').waitFor({state:'visible'});
  const view=await f.evaluate(()=>{const code=document.getElementById('read-code'),texts=selector=>[...code.querySelectorAll(selector)].map(el=>el.textContent);
   return {format:document.getElementById('read-format').textContent,lines:document.getElementById('read-lines').textContent,count:code.querySelectorAll('.code-line').length,
    text:[...code.querySelectorAll('.code-line')].map(line=>line.textContent).join('\n'),comments:texts('.tk-comment'),keys:texts('.tk-key'),strings:texts('.tk-string'),
    italic:getComputedStyle(code.querySelector('.tk-comment')).fontStyle,note:document.getElementById('read-body').textContent,noteLabel:getComputedStyle(document.getElementById('read-body'),'::before').content};});
  assert(view.format==='YAML'&&view.lines==='7 行'&&view.count===7&&view.text===compose,'The code is not shown line by line: '+JSON.stringify(view));
  assert(JSON.stringify(view.comments)==='["# 本地开发","# 和线上同一版本"]'&&view.italic==='italic','Comments are not set apart: '+JSON.stringify(view.comments));
  assert(view.keys.includes('image')&&view.keys.includes('restart')&&view.strings.includes('"5432:5432"'),'Keys or strings are not coloured: '+JSON.stringify(view));
  assert(view.note==='端口冲突时改成 5433'&&view.noteLabel==='"说明"','The 说明 is not shown under the code: '+JSON.stringify(view));
  await f.locator('#copy-code').click();await toast(f,'已复制');assert(await f.evaluate(()=>window.qaClipboard)===compose,'The code copy button did not copy the code');
  // Pinned, a config still stays out of 已置顶; 全部 and its search never show configs, while the config search covers code and 说明.
  await f.locator('#pin').click();await f.waitForFunction(()=>document.getElementById('pin').getAttribute('aria-pressed')==='true');
  await f.keyboard.press('Escape');await f.locator('[data-quick-filter="pinned"]').click();
  assert(await row(f,'Compose').count()===0,'A pinned config shows in 已置顶');
  await f.locator('[data-quick-filter="all"]').click();
  assert(await row(f,'Compose').count()===0&&await row(f,'Plain note').count()===1&&await f.locator('#quick-count').textContent()==='1 条','全部 shows configs');
  await f.locator('#quick-search').fill('postgres');assert(await rows(f)===0,'The search in 全部 finds configs');await f.locator('#quick-search').fill('');
  await f.locator('[data-quick-filter="config"]').click();
  for(const query of ['postgres','5433']){await f.locator('#quick-search').fill(query);assert(await rows(f)===1,'The config search misses '+query);}
  await f.locator('#quick-search').fill('');
  await row(f,'Compose').getByRole('button',{name:'复制配置',exact:true}).click();assert(await f.evaluate(()=>window.qaClipboard)===compose,'The row copy did not copy the code');
  // The guess while typing, for the common formats.
  await f.keyboard.press('Control+n');await f.locator('#body').waitFor({state:'visible'});
  const guesses=[['{\n  // 注释\n  "a": 1\n}','JSON'],['# 代理\ngit config --global http.proxy x','Shell / Bash'],['server {\n  listen 80;\n}','Nginx / SSH / 其他配置'],
   ['$dir = "C:\\\\tools"\nGet-ChildItem $dir','PowerShell'],['[server]\nport = 8080','INI / TOML / .env'],['DB_HOST=127.0.0.1','INI / TOML / .env'],['<config><a b="1"/></config>','XML / HTML'],
   ['SELECT id FROM users;','SQL'],['def run():\n    pass','Python'],['fun main() {\n  val a = 1\n}','Java / Kotlin / C# / Go'],['const a = require("x");','JavaScript / TypeScript'],
   ['@echo off\nset A=1','CMD / BAT'],['.btn { color: red; }','CSS'],['hello world','纯文本']];
  for(const [code,label] of guesses){await f.locator('#body').fill(code);const hint=await f.locator('#lang option').first().textContent();assert(hint==='自动识别 · '+label,'Guessed '+hint+' for '+JSON.stringify(code));}
  await f.locator('#cancel-edit').click();
  // A format chosen by hand is kept, and the code is drawn as text: markup in it never becomes part of the page.
  await row(f,'Compose').locator('.record-open').click();await f.locator('#edit').click();
  await f.locator('#body').fill('<b>bold</b> <img src=x>\n# not a comment here');await f.locator('#lang').selectOption('text');await f.keyboard.press('Control+s');await toast(f,'已保存');
  await row(f,'Compose').locator('.record-open').click();await f.locator('#read-config').waitFor({state:'visible'});
  const raw=await f.evaluate(()=>{const code=document.getElementById('read-code');return {format:document.getElementById('read-format').textContent,tags:code.querySelectorAll('b,img,[class^="tk-"]').length,text:code.textContent};});
  assert(raw.format==='纯文本'&&raw.tags===0&&raw.text.includes('<b>bold</b> <img src=x>'),'A chosen format or markup in code was mishandled: '+JSON.stringify(raw));
  // Saved for good, and in the library under 配置.
  await f.reload();await f.locator('#workspace').waitFor({state:'visible',timeout:20000});
  assert(await f.locator('[data-quick-filter="config"]').getAttribute('aria-pressed')==='true'&&await f.locator('#read-format').textContent()==='纯文本','The config or its format did not survive reopening');
  await f.locator('#view').click();await f.locator('[data-filter="config"]').click();
  assert(await f.locator('#record-list .record').count()===1&&await f.locator('#record-list .record').filter({hasText:'Compose'}).count()===1,'The library 配置 list is wrong');
  await f.locator('[data-filter="all"]').click();assert(await f.locator('#record-list .record').filter({hasText:'Compose'}).count()===0,'The library 全部 shows configs');
  // Every list row's right-click menu holds the row's actions and delete (view and restore in the trash); deleting does
  // not ask again. Escape closes the menu, the arrow keys move through it, and Shift+right-click leaves the browser's menu.
  let asks=0;f.on('dialog',()=>asks++);
  const libraryRow=title=>f.locator('#record-list .record').filter({hasText:title}),menu=f.locator('#row-menu');
  const menuItems=async()=>JSON.stringify(await menu.locator('button').allTextContents());
  await libraryRow('Plain note').click({button:'right'});await menu.waitFor();
  assert(await menuItems()==='["查看","编辑","置顶","复制内容","删除"]'&&await libraryRow('Plain note').evaluate(el=>el.classList.contains('menu-target')),'The row menu is wrong: '+await menuItems());
  await f.keyboard.press('ArrowDown');assert(await f.evaluate(()=>document.activeElement.textContent)==='编辑','The arrow keys do not move through the menu');
  await f.keyboard.press('Escape');assert(await menu.isHidden()&&await libraryRow('Plain note').count()===1&&await f.locator('#workspace').isVisible(),'Escape did not just close the menu');
  await libraryRow('Plain note').click({button:'right'});await menu.locator('button',{hasText:'复制内容'}).click();await toast(f,'已复制');
  assert(await f.evaluate(()=>window.qaClipboard)==='不是配置','Copy from the menu failed');
  await libraryRow('Plain note').click({button:'right'});await menu.locator('button',{hasText:'置顶'}).click();await toast(f,'已置顶');
  await libraryRow('Plain note').click({button:'right'});assert((await menuItems()).includes('"取消置顶"'),'Pinning from the menu failed');await f.keyboard.press('Escape');
  const shiftClick=await libraryRow('Plain note').evaluate(el=>{const e=new MouseEvent('contextmenu',{bubbles:true,cancelable:true,shiftKey:true,clientX:20,clientY:20});el.dispatchEvent(e);return e.defaultPrevented;});
  assert(!shiftClick&&await menu.isHidden(),'Shift+right-click does not leave the browser menu');
  await libraryRow('Plain note').click({button:'right'});await menu.locator('button',{hasText:'删除'}).click();await toast(f,'已移到回收站');
  assert(await libraryRow('Plain note').count()===0&&asks===0,'Right-click delete failed or asked again');
  await f.locator('[data-filter="trash"]').click();await libraryRow('Plain note').click({button:'right'});
  assert(await menuItems()==='["查看","恢复"]','The trash menu does not offer restore: '+await menuItems());
  await menu.locator('button',{hasText:'恢复'}).click();await toast(f,'已恢复');
  await f.locator('[data-filter="all"]').click();assert(await libraryRow('Plain note').count()===1,'Right-click restore failed');
  // The quick list too, in any category.
  await f.locator('#view').click();await f.locator('[data-quick-filter="config"]').click();
  await row(f,'Compose').click({button:'right'});await menu.locator('button',{hasText:'删除'}).click();await toast(f,'已移到回收站');
  assert(await rows(f)===0&&asks===0,'Right-click delete in the quick list failed');
  await f.context().close();

  // Rich text: a table pasted from an answer or a page is kept as Markdown and shown as a table (cards in the narrow
  // quick view, a real table in the library), with code, bold, headings and web links. Tab-separated columns become a
  // table as well; a config's code is pasted as it is; plain notes look as before.
  const portG=await freePort(),dataG=path.join(work,'g');
  await startBackend(portG,dataG);
  const g=await open(portG);
  await g.locator('#auth-mode').click();
  await g.locator('#username').fill('qa-rich');await g.locator('#master').fill(master);await g.locator('#master-confirm').fill(master);
  await g.locator('#auth-submit').click();await g.locator('#workspace').waitFor({state:'visible',timeout:20000});
  const paste=(selector,html,text)=>g.locator(selector).evaluate((box,[html,text])=>{box.focus();const data=new DataTransfer();if(html)data.setData('text/html',html);data.setData('text/plain',text);box.dispatchEvent(new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true}));},[html,text]);
  const answer='<meta charset="utf-8"><!--StartFragment--><p><strong>TODO 总结</strong></p><table><thead><tr><th>类名</th><th>位置</th><th>后面怎么做</th></tr></thead><tbody>'+
   '<tr><td><code>ChargerInfoState</code>（<code>supportOcpp</code>）</td><td><a href="app/src/Repo.kt#L108">Repo.kt:108</a></td><td>加字段 a|b，见 <a href="https://example.com/design">设计稿</a></td></tr>'+
   '<tr><td><code>MoreSettingsActivity</code></td><td><a href="app/src/More.kt#L443">More.kt:443</a></td><td>需要确认</td></tr></tbody></table><!--EndFragment-->';
  await g.locator('[data-quick-filter="todo"]').click();
  await paste('#todo-add-quick',answer,'TODO 总结\n类名\t位置\t后面怎么做');
  const pasted=await g.locator('#todo-add-quick').inputValue();
  assert(pasted==='**TODO 总结**\n\n| 类名 | 位置 | 后面怎么做 |\n| --- | --- | --- |\n| `ChargerInfoState`（`supportOcpp`） | Repo.kt:108 | 加字段 a\\|b，见 [设计稿](https://example.com/design) |\n| `MoreSettingsActivity` | More.kt:443 | 需要确认 |','The pasted table was not kept as Markdown: '+JSON.stringify(pasted));
  await g.locator('#todo-add-quick').press('Enter');await row(g,'TODO 总结').waitFor();
  assert((await row(g,'TODO 总结').locator('.record-preview').textContent()).startsWith('类名 · 位置 · 后面怎么做\nChargerInfoState（supportOcpp） · Repo.kt:108'),'The preview shows Markdown marks');
  await row(g,'TODO 总结').locator('.record-open').click();await g.locator('#read-content').waitFor({state:'visible'});
  const richView=()=>g.evaluate(()=>{const body=document.getElementById('read-body'),cell=body.querySelector('tbody td:nth-child(3)');
   return {tables:body.querySelectorAll('table.md-table').length,rows:body.querySelectorAll('tbody tr').length,cellDisplay:cell&&getComputedStyle(cell).display,label:cell?.dataset.label,cell:cell?.textContent,
    codes:[...body.querySelectorAll('.md-code')].map(code=>code.textContent),links:[...body.querySelectorAll('a.web-link')].map(a=>a.textContent+' -> '+a.href),heading:document.getElementById('read-title').textContent};});
  let rich=await richView();
  assert(rich.tables===1&&rich.rows===2&&rich.cellDisplay==='block'&&rich.label==='后面怎么做'&&rich.cell==='加字段 a|b，见 设计稿','The quick view does not show the table as cards: '+JSON.stringify(rich));
  assert(JSON.stringify(rich.codes)==='["ChargerInfoState","supportOcpp","MoreSettingsActivity"]'&&JSON.stringify(rich.links)==='["设计稿 -> https://example.com/design"]'&&rich.heading==='TODO 总结','Code, bold or links are not shown: '+JSON.stringify(rich));
  await g.setViewportSize({width:1060,height:820});await g.locator('#view').click();await g.locator('#read-content').waitFor({state:'visible'});
  rich=await richView();assert(rich.cellDisplay==='table-cell','The library does not show a real table: '+JSON.stringify(rich));
  await g.locator('#view').click();await g.setViewportSize({width:470,height:810});
  // Tab-separated text: converted when pasted, and shown as a table when it was saved as it is.
  await g.locator('[data-quick-filter="note"]').click();
  await addRecord(g,'Pasted columns',async()=>{await paste('#body','','名称\t端口\nweb\t8080\ndb\t5432');
   assert(await g.locator('#body').inputValue()==='| 名称 | 端口 |\n| --- | --- |\n| web | 8080 |\n| db | 5432 |','Tab-separated text was not turned into a table');});
  await addRecord(g,'Saved columns',async()=>{await g.locator('#body').fill('说明在前\n名称\t端口\nweb\t8080\n说明在后');});
  await row(g,'Saved columns').locator('.record-open').click();await g.locator('#read-content').waitFor({state:'visible'});
  const saved=await g.evaluate(()=>{const body=document.getElementById('read-body');return {head:[...body.querySelectorAll('th')].map(th=>th.textContent).join(','),texts:[...body.querySelectorAll('.md-text')].map(t=>t.textContent)};});
  assert(saved.head==='名称,端口'&&JSON.stringify(saved.texts)==='["说明在前","说明在后"]','Saved tab-separated text is not shown as a table: '+JSON.stringify(saved));
  await g.keyboard.press('Escape');
  // Headings, code blocks with colours, rules; a lone * or other text stays as written.
  const markdown='## 小标题\n**粗体** 和 `code`\n```json\n{"a": 1}\n```\n---\n普通 *星号* 5*3';
  await addRecord(g,'Markdown',async()=>{await g.locator('#body').fill(markdown);});
  await row(g,'Markdown').locator('.record-open').click();await g.locator('#read-content').waitFor({state:'visible'});
  const md=await g.evaluate(()=>{const body=document.getElementById('read-body');return {h:body.querySelector('.md-h2')?.textContent,strong:body.querySelector('strong')?.textContent,code:body.querySelector('.md-code')?.textContent,key:body.querySelector('pre.md-pre .tk-key')?.textContent,hr:body.querySelectorAll('hr.md-hr').length,last:[...body.querySelectorAll('.md-text')].pop()?.textContent};});
  assert(md.h==='小标题'&&md.strong==='粗体'&&md.code==='code'&&md.key==='"a"'&&md.hr===1&&md.last==='普通 *星号* 5*3','Markdown is not shown: '+JSON.stringify(md));
  await g.keyboard.press('Escape');await row(g,'Markdown').getByRole('button',{name:'复制内容',exact:true}).click();
  assert(await g.evaluate(()=>window.qaClipboard)===markdown,'Copy does not give the Markdown text');
  // Codex: a selection inside a table arrives as rows without their <table>, and links to files as Markdown text. It
  // still becomes a table; the file links show their names, with the path when the pointer rests on them.
  await g.locator('[data-quick-filter="todo"]').click();await g.locator('#todo-title-quick').fill('Codex table');
  const codex='<html><body><!--StartFragment--><thead><tr><th><span>类名（方法）</span></th><th><span>位置</span></th></tr></thead><tbody><tr><td><code dir="ltr">Demo.save()</code></td><td><span data-prompt-link-label="Demo.kt (line 3)" data-prompt-link-href="E:/code/Demo.kt:3">[Demo.kt (line 3)](E:/code/Demo.kt:3)</span></td></tr></tbody><!--EndFragment--></body></html>';
  await paste('#todo-add-quick',codex,'类名（方法）\t位置\nDemo.save()\t[Demo.kt (line 3)](E:/code/Demo.kt:3)');
  const codexPasted=await g.locator('#todo-add-quick').inputValue();
  assert(codexPasted==='| 类名（方法） | 位置 |\n| --- | --- |\n| `Demo.save()` | [Demo.kt (line 3)](E:/code/Demo.kt:3) |','A table copied from inside Codex was not kept: '+JSON.stringify(codexPasted));
  await g.locator('#todo-add-quick').press('Enter');await row(g,'Codex table').locator('.record-open').click();await g.locator('#read-content').waitFor({state:'visible'});
  const codexView=await g.evaluate(()=>{const body=document.getElementById('read-body'),file=body.querySelector('.md-file');return {cols:body.querySelectorAll('thead th').length,file:file?.textContent,path:file?.title,raw:body.textContent.includes('](')};});
  assert(codexView.cols===2&&codexView.file==='Demo.kt (line 3)'&&codexView.path==='E:/code/Demo.kt:3'&&!codexView.raw,'The Codex table is not shown right: '+JSON.stringify(codexView));
  await g.keyboard.press('Escape');
  // A config's code is pasted exactly as copied.
  await g.locator('[data-quick-filter="config"]').click();await g.keyboard.press('Control+n');await g.locator('#body').waitFor({state:'visible'});
  await paste('#body','<pre><code>a: 1</code></pre><table><tr><td>x</td></tr></table>','a: 1\nx\ty\nz\tw');
  assert(await g.locator('#body').inputValue()==='','The paste into a config was changed instead of left to the browser');
  await g.locator('#cancel-edit').click();
  await g.context().close();
  // Every record opened from the quick list shows in a larger window grown from the toolbar side (right and bottom edges
  // kept), as wide as its longest line (no line wraps) and as tall as the record; back in the list the window goes back
  // above the T button. The library opened from such a window, and a reload while it is large, go back there as well.
  const home={x:1450,y:156,w:470,h:810},t=await simulate(home,portG);
  const anchored=frame=>frame.x+frame.w===home.x+home.w&&frame.y+frame.h===home.y+home.h;
  const openTable=async()=>{await t.locator('[data-quick-filter="todo"]').click();await row(t,'TODO 总结').locator('.record-open').click();await t.locator('#read-content').waitFor({state:'visible'});};
  await openTable();
  const big=await frameOf(t);
  assert(big.w>=560&&big.w<=1872&&big.h>=360&&big.h<=992&&anchored(big),'The table did not open in a large window grown from the toolbar side: '+JSON.stringify(big));
  await t.locator('#back-to-list').click();sameFrame(await frameOf(t),home,'The window did not go back after the table');
  // A note with lines longer than the quick window: the window is widened until each line fits on one line (checked
  // with the page drawn at the window's new size), and the list shows each line of its preview on one line.
  await t.locator('[data-quick-filter="note"]').click();
  const longLines='先在服务器上执行 git pull origin main，然后运行 npm ci --omit=dev 安装依赖，最后用 pm2 restart t-notes 重启服务\n短的一行';
  await addRecord(t,'Long lines',async()=>{await t.locator('#body').fill(longLines);});
  const preview=await row(t,'Long lines').locator('.record-preview span').evaluateAll(spans=>spans.map(span=>({one:span.getBoundingClientRect().height<30,cut:span.scrollWidth>span.clientWidth})));
  assert(preview.length===2&&preview.every(span=>span.one)&&preview[0].cut,'The preview does not keep each line on one line: '+JSON.stringify(preview));
  await row(t,'Long lines').locator('.record-open').click();await t.locator('#read-content').waitFor({state:'visible'});
  const note=await frameOf(t);
  assert(anchored(note)&&note.w>800&&note.w<=1872,'A note with long lines did not open wide from the toolbar side: '+JSON.stringify(note));
  await t.setViewportSize({width:note.w,height:note.h});
  const wrapped=await t.evaluate(()=>{const block=document.querySelector('#read-body>.md-text'),scroller=document.querySelector('.editor-body');return {lines:Math.round(block.getBoundingClientRect().height/parseFloat(getComputedStyle(block).lineHeight)),overflow:scroller.scrollHeight-scroller.clientHeight};});
  assert(wrapped.lines===2&&wrapped.overflow<=1,'The long lines wrapped or the window is too short: '+JSON.stringify(wrapped));
  await t.setViewportSize({width:470,height:810});
  await t.locator('#back-to-list').click();sameFrame(await frameOf(t),home,'The window did not go back after a note');
  await openTable();
  await t.locator('#view').click();sameFrame(await frameOf(t),libraryFrame,'The library did not open from where the quick window was');
  await t.locator('#view').click();sameFrame(await frameOf(t),home,'The window did not come back from the library');
  await row(t,'TODO 总结').locator('.record-open').click();await t.locator('#read-content').waitFor({state:'visible'});
  const large=await frameOf(t);await t.reload();await signIn(t);await t.locator('#read-content').waitFor({state:'visible',timeout:20000});
  sameFrame(await frameOf(t),large,'A reload changed the large window');
  await t.locator('#back-to-list').click();sameFrame(await frameOf(t),home,'After a reload the window did not go back');
  await t.context().close();

  // Staying logged in: a remembered login opens the vault again without the password, also when the backend fails
  // for a moment at startup, and the window comes back where the user left off. Only an explicit logout asks for
  // the password again. The record's buttons sit at the bottom with labels, and reading text is larger.
  const portD=await freePort(),dataD=path.join(work,'d');
  await startBackend(portD,dataD);
  const d=await open(portD);
  await d.locator('#auth-mode').click();
  await d.locator('#username').fill('qa-place');await d.locator('#master').fill(master);await d.locator('#master-confirm').fill(master);
  assert(await d.locator('#remember').isChecked(),'Remembering the login is not on by default');
  await d.locator('#auth-submit').click();await d.locator('#workspace').waitFor({state:'visible',timeout:20000});
  await addRecord(d,'First',async()=>{await d.locator('#body').fill('第一条记录');});
  for(let index=1;index<=14;index++)await addRecord(d,'Place '+index,async()=>{await d.locator('#body').fill('placeholder '+index);});
  await d.locator('[data-quick-filter="all"]').click();
  await row(d,'First').locator('.record-open').click();await d.locator('#read-content').waitFor({state:'visible'});
  const panel=await d.evaluate(()=>{
   const bar=document.querySelector('.editor-actions'),footer=document.querySelector('footer').getBoundingClientRect(),box=bar.getBoundingClientRect();
   return {inBar:['edit','pin','copy','delete'].every(id=>bar.contains(document.getElementById(id))),labels:[...bar.querySelectorAll('button:not([hidden]) span')].map(s=>s.textContent).join(','),
    atBottom:footer.top-box.bottom>=0&&footer.top-box.bottom<=24,tall:box.height>=44,body:getComputedStyle(document.getElementById('read-body')).fontSize,title:getComputedStyle(document.getElementById('read-title')).fontSize};
  });
  assert(panel.inBar&&panel.labels==='编辑,置顶,复制,删除'&&panel.atBottom&&panel.tall,'Record buttons are not in the bottom bar: '+JSON.stringify(panel));
  assert(panel.body==='16px'&&panel.title==='22px','Reading text is not larger: '+JSON.stringify(panel));
  // Reopening with a record open: no password, same record open.
  await d.reload();await d.locator('#workspace').waitFor({state:'visible',timeout:20000});
  assert(await d.locator('#auth-screen').isHidden(),'A remembered login asked for the password');
  assert(!await d.locator('body').evaluate(e=>e.classList.contains('quick-list'))&&await d.locator('#read-title').textContent()==='First','The open record was not reopened');
  // Reopening from the list: same category, list scrolled where it was.
  await d.keyboard.press('Escape');await d.locator('[data-quick-filter="note"]').click();
  await d.evaluate(()=>{const list=document.getElementById('recent-list');list.scrollTop=list.scrollHeight;});
  const scrolled=await d.evaluate(()=>document.getElementById('recent-list').scrollTop);await d.waitForTimeout(600);
  await d.reload();await d.locator('#workspace').waitFor({state:'visible',timeout:20000});await d.waitForTimeout(300);
  const place=await d.evaluate(()=>({list:document.body.classList.contains('quick-list'),filter:document.querySelector('[data-quick-filter].active')?.dataset.quickFilter,scroll:document.getElementById('recent-list').scrollTop}));
  assert(scrolled>0&&place.list&&place.filter==='note'&&Math.abs(place.scroll-scrolled)<=2,'The list position was not restored: '+JSON.stringify({scrolled,...place}));
  // The backend failing for a moment at startup is retried instead of showing the login screen.
  let sessionCalls=0;
  await d.route('**/api/session',route=>{sessionCalls++;if(sessionCalls<=2)return route.fulfill({status:503,contentType:'application/json',body:'{"error":"busy"}'});return route.continue();});
  await d.reload();await d.locator('#workspace').waitFor({state:'visible',timeout:20000});
  assert(sessionCalls>=3&&await d.locator('#auth-screen').isHidden(),'A temporary backend failure fell back to the login screen ('+sessionCalls+' calls)');
  await d.unroute('**/api/session');
  // After an explicit logout the password is needed again.
  await d.locator('#lock').click();await d.locator('#auth-screen').waitFor({state:'visible'});
  await d.reload();await d.waitForFunction(()=>!document.querySelector('#auth-submit').disabled);
  assert(await d.locator('#auth-screen').isVisible()&&await d.locator('#workspace').isHidden(),'The vault opened again after logging out');
  await d.context().close();

  assert(errors.length===0,errors.join('\n'));
  console.log(JSON.stringify({error_log:'passed',table_window:'passed',rich_paste:'passed',config_records:'passed',todo_list:'passed',stay_logged_in_and_place:'passed',bottom_action_bar:'passed',web_links:'passed',browser_password_saving_off:'passed',fixed_layout:'passed',messages:'passed',shortcuts:'passed',search_tag_site:'passed',trash_restore:'passed',prompt_variables:'passed',backup_folder_retention:'passed',automatic_backup:'passed',layout_toggle_placement:'passed',import_merge:'passed',restore_empty_computer:'passed'}));
 }finally{
  await browser.close();
 }
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>{
 for(const child of children)child.kill();
 setTimeout(()=>{try{fs.rmSync(work,{recursive:true,force:true});}catch{}},500);
});

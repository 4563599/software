// Local-only UI test: no sync server, throwaway data directories, fictional records.
// Covers layout, messages, shortcuts, search, trash, prompt variables, daily backup, import and restore.
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
async function startBackend(port,dataDir){
 fs.mkdirSync(dataDir,{recursive:true});
 // A config path that does not exist keeps the test away from any real sync server.
 const child=spawn(process.execPath,[path.join(root,'client','desktop.cjs')],{env:{...process.env,TNOTES_PORT:String(port),TNOTES_DATA:dataDir,TNOTES_CONFIG:path.join(dataDir,'no-server.json')},stdio:'ignore',windowsHide:true});
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

  // The backend writes the daily file by itself after a restart.
  for(const name of backups(chosenDir))fs.unlinkSync(path.join(chosenDir,name));
  backendA.kill();await new Promise(resolve=>backendA.once('exit',resolve));backendA=await startBackend(portA,dataA);
  const deadline=Date.now()+15000;while(!fs.existsSync(chosen)){if(Date.now()>deadline)throw Error('Automatic daily backup was not written');await new Promise(resolve=>setTimeout(resolve,250));}
  assert(JSON.parse(fs.readFileSync(chosen,'utf8')).data.items.length===19,'Automatic backup is incomplete');

  assert(errors.length===0,errors.join('\n'));
  console.log(JSON.stringify({browser_password_saving_off:'passed',fixed_layout:'passed',messages:'passed',shortcuts:'passed',search_tag_site:'passed',trash_restore:'passed',prompt_variables:'passed',backup_folder_retention:'passed',automatic_backup:'passed',import_merge:'passed',restore_empty_computer:'passed'}));
 }finally{
  await browser.close();
 }
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>{
 for(const child of children)child.kill();
 setTimeout(()=>{try{fs.rmSync(work,{recursive:true,force:true});}catch{}},500);
});

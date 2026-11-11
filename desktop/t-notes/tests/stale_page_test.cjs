const {chromium}=require('playwright');
const fs=require('node:fs');
const path=require('node:path');
const [port,work]=process.argv.slice(2);
(async()=>{
 const browser=await chromium.launch({headless:true,channel:'chrome'});
 try {
  const page=await browser.newPage();
  await page.goto('http://127.0.0.1:'+port);
  await page.waitForFunction(()=>!document.querySelector('#auth-submit').disabled);
  await page.locator('#username').fill('qa-vault');
  await page.locator('#master').fill('QA-passphrase-only-2026');
  await page.locator('#remember').uncheck();
  fs.writeFileSync(path.join(work,'page-ready'),'ready');
  const deadline=Date.now()+20000;
  while(!fs.existsSync(path.join(work,'agent-restarted'))){if(Date.now()>deadline)throw Error('Agent restart did not complete');await new Promise(resolve=>setTimeout(resolve,100));}
  await page.locator('#auth-submit').click();
  try{await page.locator('#workspace').waitFor({state:'visible',timeout:12000});}
  catch{throw Error('Login after local restart failed: '+await page.locator('#auth-error').innerText());}
  if(await page.locator('#edit-fields').isVisible())throw Error('Restart recovery did not retain view-first mode');
  await page.locator('#recent-list .record').first().locator('.record-open').click();await page.locator('#edit').click();
  await page.locator('#body').fill('QA draft survives a local backend outage');
  fs.writeFileSync(path.join(work,'draft-ready'),'ready');
  const waitMarker=async name=>{const until=Date.now()+20000;while(!fs.existsSync(path.join(work,name))){if(Date.now()>until)throw Error('Missing fixture marker: '+name);await new Promise(resolve=>setTimeout(resolve,100));}};
  await waitMarker('backend-down');await page.locator('#save').click();
  await page.waitForFunction(()=>document.querySelector('#notice').textContent.length>0);
  if(!await page.locator('#edit-fields').isVisible()||await page.locator('#body').inputValue()!=='QA draft survives a local backend outage')throw Error('Failed save discarded the draft');
  fs.writeFileSync(path.join(work,'failed-save-confirmed'),'ready');
  await waitMarker('backend-recovered');await page.locator('#save').click();
  await page.waitForFunction(()=>document.body.classList.contains('quick-list')&&document.querySelector('#sync-label').textContent.startsWith('已同步'),null,{timeout:30000});
  if(await page.locator('#body').inputValue()!=='QA draft survives a local backend outage')throw Error('Draft was not saved after backend recovery');
  await page.locator('#lock').click();
  await page.locator('#auth-screen').waitFor({state:'visible'});
  console.log(JSON.stringify({stale_page_login_after_restart:'passed',save_after_backend_outage_without_refresh:'passed'}));
 }finally{await browser.close();}
})().catch(error=>{console.error(error.message);process.exitCode=1;});

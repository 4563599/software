const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const {spawn} = require('node:child_process');
const {createAiSync, recordsRoot} = require('./ai-sync.cjs');

const port = Number(process.env.TNOTES_PORT || 47321);
const origin = `http://127.0.0.1:${port}`;
const dataDir = process.env.TNOTES_DATA || path.join(process.env.LOCALAPPDATA || process.env.HOME, 'TNotes');
fs.mkdirSync(dataDir, {recursive:true});
const csrf = crypto.randomBytes(32).toString('hex');
const cachePath = path.join(dataDir, 'encrypted-cache.json');
const privateConfig = path.join(dataDir, 'server.json');
const configPath = process.env.TNOTES_CONFIG || (fs.existsSync(privateConfig) ? privateConfig : path.join(__dirname, 'server.json'));
const enrollmentPath = path.join(dataDir, 'enrollment.once');
const sessionPath = path.join(dataDir, 'remembered-session.dpapi');
function validSession(value) {
  return value?.version===1 && value.vaultId===cached.data?.profile?.id &&
    typeof value.encryptionKey==='string' && /^[A-Za-z0-9+/]{43}=$/.test(value.encryptionKey) &&
    typeof value.auth==='string' && /^[a-f0-9]{64}$/.test(value.auth);
}
function protectSession(action,input) {
  if(process.platform!=='win32')return Promise.reject(Error('Windows login protection is unavailable'));
  return new Promise((resolve,reject)=>{
    const executable=path.join(process.env.WINDIR||'C:\\Windows','System32/WindowsPowerShell/v1.0/powershell.exe');
    const child=spawn(executable,['-NoProfile','-NonInteractive','-WindowStyle','Hidden','-File',path.join(__dirname,'session-protection.ps1'),'-Action',action],{windowsHide:true,stdio:['pipe','pipe','pipe']});
    let output='',failed=false;
    const timer=setTimeout(()=>{failed=true;child.kill();reject(Error('Windows login protection timed out'));},15000);
    child.stdout.on('data',chunk=>{output+=chunk;if(output.length>16384){failed=true;child.kill();reject(Error('Invalid protected session'));}});
    child.stderr.resume();
    child.stdin.on('error',()=>{});
    child.on('error',()=>{clearTimeout(timer);failed=true;reject(Error('Windows login protection failed'));});
    child.on('close',code=>{clearTimeout(timer);if(!failed){if(code===0)resolve(output.trim());else reject(Error('Windows login protection failed'));}});
    child.stdin.end(input);
  });
}
// Links in notes open in the user's default browser, not in the notes window's own browser profile.
// Only web addresses are accepted, so a note can never start a program or open a local file.
function openableUrl(value) {
  if(typeof value!=='string'||value.length>2048||/[\s\u0000-\u001f\u007f]/.test(value))return null;
  let target;
  try { target=new URL(value); } catch { return null; }
  if(!['http:','https:'].includes(target.protocol)||!target.hostname||target.username||target.password)return null;
  return target.href;
}
function openInBrowser(target) {
  // Tests set TNOTES_OPEN_LOG to record the request instead of opening a real browser window.
  if(process.env.TNOTES_OPEN_LOG){fs.appendFileSync(process.env.TNOTES_OPEN_LOG,target+'\n');return;}
  // On Windows a small helper opens it, so the browser may come to the front (see open-url.ps1).
  const [command,args]=process.platform==='win32'
    ? [path.join(process.env.WINDIR||'C:\\Windows','System32/WindowsPowerShell/v1.0/powershell.exe'),['-NoProfile','-NonInteractive','-ExecutionPolicy','RemoteSigned','-WindowStyle','Hidden','-File',path.join(__dirname,'open-url.ps1'),'-Url',target]]
    : [process.platform==='darwin'?'open':'xdg-open',[target]];
  // Not detached: started detached without a console, Windows PowerShell exits without running the script.
  const child=spawn(command,args,{stdio:'ignore',windowsHide:true});
  child.on('error',()=>{});
  child.unref();
}
const config = fs.existsSync(configPath) ? JSON.parse(fs.readFileSync(configPath,'utf8')) : {};
const remote = config.url ? new URL(config.url) : null;
if (remote && (remote.protocol !== 'https:' || remote.username || remote.password || remote.pathname !== '/')) throw Error('Only HTTPS origin is supported');
const ca = remote ? fs.readFileSync(path.join(path.dirname(configPath),'server-ca.pem')) : null;
const staticFiles = new Map([['/','index.html'],['/app.js','app.js'],['/crypto.js','crypto.js'],['/style.css','style.css'],['/lucide.js','lucide.js'],['/icon.svg','icon.svg']]);
let cached = fs.existsSync(cachePath) ? JSON.parse(fs.readFileSync(cachePath,'utf8')) : {version:0,data:null};
// Daily encrypted backups. The file holds the same ciphertext as the cache, so it is safe in an ordinary folder.
// The normal vault backs up to Documents, away from the data folder it protects. Any other data
// directory (tests, a second vault) keeps its backups beside its own data so the two never mix.
const settingsPath = path.join(dataDir, 'settings.json');
const standardDataDir = path.join(process.env.LOCALAPPDATA || os.homedir(), 'TNotes');
const defaultBackupDir = path.resolve(dataDir).toLowerCase() === path.resolve(standardDataDir).toLowerCase()
  ? path.join(os.homedir(),'Documents','TNotes-Backups') : path.join(dataDir,'backups');
const backupKeep = 30;
const backupFile = /^tnotes-backup-\d{4}-\d{2}-\d{2}\.json$/;
let settings = {};
try { settings = JSON.parse(fs.readFileSync(settingsPath,'utf8')); } catch {}
let backedUpVersion = -1, backupError = null;
function backupDir() {
  return typeof settings.backupDir==='string'&&path.isAbsolute(settings.backupDir)?settings.backupDir:defaultBackupDir;
}
function backupFiles(dir) {
  try{return fs.readdirSync(dir).filter(name=>backupFile.test(name)).sort();}catch{return [];}
}
function writeBackup(force) {
  if(!cached.data)return;
  const now=new Date(),day=[now.getFullYear(),now.getMonth()+1,now.getDate()].map(n=>String(n).padStart(2,'0')).join('-');
  const dir=backupDir(),file=path.join(dir,'tnotes-backup-'+day+'.json');
  // One file per day, rewritten when the vault changes, so each file ends up as that day's last state.
  if(!force&&backedUpVersion===cached.version&&fs.existsSync(file))return;
  fs.mkdirSync(dir,{recursive:true});
  fs.writeFileSync(file+'.tmp',JSON.stringify({format:'tnotes-encrypted-backup-v1',created:now.toISOString(),data:cached.data}));
  fs.renameSync(file+'.tmp',file);
  backedUpVersion=cached.version;backupError=null;
  // Only files this function names are ever removed from the folder.
  for(const old of backupFiles(dir).slice(0,-backupKeep))fs.unlinkSync(path.join(dir,old));
}
function tryBackup(force) {
  try{writeBackup(force);return true;}
  catch(e){backupError='无法写入备份文件夹（'+(/^[A-Z0-9_]{1,32}$/.test(e.code||'')?e.code:'WRITE_FAILED')+'）';return false;}
}
function backupInfo() {
  const dir=backupDir(),files=backupFiles(dir);let latest=null;
  if(files.length){const name=files[files.length-1];try{latest={name,time:fs.statSync(path.join(dir,name)).mtime.toISOString()};}catch{}}
  return {dir,count:files.length,keep:backupKeep,latest,error:backupError};
}
function reply(res,code,data) {
  res.writeHead(code, {'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
  res.end(JSON.stringify(data));
}
async function body(req) {
  let bytes=0,parts=[];
  for await(const part of req) {bytes+=part.length;if(bytes>24*1024*1024)throw Error('Body too large');parts.push(part);}
  return JSON.parse(Buffer.concat(parts).toString('utf8'));
}
function relay(req,res,url,raw) {
  const headers={'Content-Type':'application/json'};
  const payload=raw?JSON.stringify(raw):null;
  if(payload)headers['Content-Length']=Buffer.byteLength(payload);
  if(req.headers.authorization)headers.Authorization=req.headers.authorization;
  if(url.pathname==='/v1/register'&&fs.existsSync(enrollmentPath))headers['X-Enrollment']=fs.readFileSync(enrollmentPath,'utf8').trim();
  const transient=new Set(['ECONNRESET','ECONNREFUSED','ETIMEDOUT','EHOSTUNREACH','ENETUNREACH','EPIPE','ERR_SOCKET_CLOSED','ERR_STREAM_PREMATURE_CLOSE']);
  const certificates=new Set(['CERT_HAS_EXPIRED','CERT_NOT_YET_VALID','DEPTH_ZERO_SELF_SIGNED_CERT','SELF_SIGNED_CERT_IN_CHAIN','UNABLE_TO_VERIFY_LEAF_SIGNATURE','UNABLE_TO_GET_ISSUER_CERT_LOCALLY','ERR_TLS_CERT_ALTNAME_INVALID']);
  // Record writes use the same ciphertext on retry; the server treats them idempotently.
  const retryable=req.method==='GET'||(req.method==='PUT'&&url.pathname==='/v1/records')||(req.method==='POST'&&url.pathname==='/v1/login');
  let attempt=0,active=null,timer=null,cancelled=false;
  res.once('close',()=>{cancelled=true;clearTimeout(timer);if(active)active.destroy();});
  function recordFailure(code) {
    try{
      const file=path.join(dataDir,'network-errors.log');
      if(!fs.existsSync(file)||fs.statSync(file).size<1024*1024)fs.appendFileSync(file,JSON.stringify({time:new Date().toISOString(),event:'sync_connection_failed',code,attempts:attempt})+'\n',{mode:0o600});
    }catch{}
  }
  function send() {
    if(cancelled||res.destroyed)return;
    attempt++;let completed=false;
    const fail=error=>{
      if(completed||cancelled)return;completed=true;
      const code=/^[A-Z0-9_]{1,64}$/.test(error.code||'')?error.code:'CONNECTION_FAILED';
      if(retryable&&transient.has(code)&&attempt<3){timer=setTimeout(send,attempt*400);return;}
      recordFailure(code);
      if(!res.headersSent&&!res.destroyed)reply(res,502,{error:(certificates.has(code)?'同步服务器证书校验失败，已停止连接':'同步服务器暂时无法连接，本机已保存的内容会继续保留')+' ('+code+')',code});
    };
    const upstream=https.request(new URL(url.pathname+url.search,remote),{method:req.method,ca,rejectUnauthorized:true,headers,timeout:10000},up=>{
      let length=0,chunks=[];
      up.on('data',chunk=>{length+=chunk.length;if(length>24*1024*1024)up.destroy(Object.assign(Error('Response too large'),{code:'RESPONSE_TOO_LARGE'}));else chunks.push(chunk);});
      up.on('error',fail);
      up.on('end',()=>{
        if(completed||cancelled||res.destroyed)return;completed=true;
        if(url.pathname==='/v1/register'&&up.statusCode===200&&fs.existsSync(enrollmentPath)){try{fs.unlinkSync(enrollmentPath);}catch{recordFailure('ENROLLMENT_CLEANUP_FAILED');}}
        if(res.headersSent)return;
        res.writeHead(up.statusCode,{'Content-Type':'application/json','Cache-Control':'no-store'});
        res.end(Buffer.concat(chunks));
      });
    });
    active=upstream;
    upstream.on('timeout',()=>upstream.destroy(Object.assign(Error('Timeout'),{code:'ETIMEDOUT'})));
    upstream.on('error',fail);
    if(payload)upstream.write(payload);upstream.end();
  }
  send();
}
const server=http.createServer(async(req,res)=>{
  try {
    if(req.headers.host!==`127.0.0.1:${port}`)return reply(res,403,{error:'Invalid host'});
    const url=new URL(req.url,origin);
    if(url.pathname==='/health')return reply(res,200,{app:'TNotes',version:3});
    if(staticFiles.has(url.pathname)&&req.method==='GET') {
      const name=staticFiles.get(url.pathname);
      const mime=name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'application/javascript';
      let content=fs.readFileSync(path.join(__dirname,'web',name));
      if(name==='index.html')content=Buffer.from(content.toString().replace('__CSRF__',csrf));
      res.writeHead(200,{'Content-Type':mime+'; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",'Referrer-Policy':'no-referrer'});return res.end(content);
    }
    if(url.pathname==='/api/bootstrap'&&req.method==='GET') {
      if((req.headers.origin&&req.headers.origin!==origin)||
        (req.headers['sec-fetch-site']&&!['same-origin','none'].includes(req.headers['sec-fetch-site']))) {
        return reply(res,403,{error:'不允许其他网站访问本机登录状态'});
      }
      return reply(res,200,{csrf,version:3});
    }
    if(req.headers.origin&&req.headers.origin!==origin)return reply(res,403,{error:'本机页面地址不一致，请从 T 按钮重新打开',code:'LOCAL_ORIGIN_MISMATCH'});
    if(req.headers['x-tnotes-csrf']!==csrf)return reply(res,403,{error:'本地服务已重启，页面校验已失效，请刷新后重试',code:'LOCAL_SESSION_STALE'});
    if(url.pathname==='/api/config'&&req.method==='GET')return reply(res,200,{remote:remote?.origin||null,enrollment:fs.existsSync(enrollmentPath),rememberSupported:process.platform==='win32'});
    if(url.pathname==='/api/session') {
      if(req.method==='GET') {
        if(!fs.existsSync(sessionPath))return reply(res,200,{session:null});
        const raw=await protectSession('Unprotect',fs.readFileSync(sessionPath,'utf8'));
        const value=JSON.parse(Buffer.from(raw,'base64').toString('utf8'));
        if(!validSession(value))return reply(res,409,{error:'本机登录记忆与资料库不匹配，请重新登录'});
        return reply(res,200,{session:value});
      }
      if(req.method==='PUT') {
        const value=await body(req);
        if(!validSession(value))return reply(res,400,{error:'无效的本机登录记忆'});
        const encoded=Buffer.from(JSON.stringify(value)).toString('base64');
        const protectedValue=await protectSession('Protect',encoded);
        fs.writeFileSync(sessionPath+'.tmp',protectedValue,{mode:0o600});
        fs.renameSync(sessionPath+'.tmp',sessionPath);
        return reply(res,200,{remembered:true});
      }
      if(req.method==='DELETE') {
        for(const file of [sessionPath,sessionPath+'.tmp'])if(fs.existsSync(file))fs.unlinkSync(file);
        return reply(res,200,{remembered:false});
      }
      return reply(res,405,{error:'Method not allowed'});
    }
    if(url.pathname==='/api/cache') {
      if(req.method==='GET')return reply(res,200,cached);
      if(req.method==='PUT') {
        const input=await body(req);
        if(input.version!==cached.version)return reply(res,409,{error:'另一窗口已更新资料库，请先重新打开资料库以合并更改'});
        if(!input.data||!Array.isArray(input.data.items))return reply(res,400,{error:'Invalid cache'});
        const updated={version:cached.version+1,data:input.data};
        const temp=cachePath+'.tmp';
        fs.writeFileSync(temp,JSON.stringify(updated),{mode:0o600});
        if(fs.existsSync(cachePath))fs.copyFileSync(cachePath,cachePath+'.bak');
        fs.renameSync(temp,cachePath);cached=updated;return reply(res,200,{version:cached.version});
      }
    }
    if(url.pathname==='/api/open-url') {
      if(req.method!=='POST')return reply(res,405,{error:'Method not allowed'});
      const target=openableUrl((await body(req))?.url);
      if(!target)return reply(res,400,{error:'只能用浏览器打开 http 或 https 开头的网页地址'});
      openInBrowser(target);
      return reply(res,200,{opened:target});
    }
    if(url.pathname==='/api/backup') {
      if(req.method==='PUT') {
        const input=await body(req),dir=typeof input.dir==='string'?input.dir.trim():'';
        if(dir.length>240||dir.includes('\0')||!/^(?:[a-zA-Z]:[\\/]|\\\\[^\\/]+[\\/])/.test(dir))return reply(res,400,{error:'备份文件夹需要填写完整路径，例如 D:\\Backups\\TNotes'});
        const target=path.resolve(dir),probe=path.join(target,'.tnotes-write-test-'+process.pid);
        try{fs.mkdirSync(target,{recursive:true});fs.writeFileSync(probe,'');fs.unlinkSync(probe);}
        catch{return reply(res,400,{error:'无法写入这个文件夹，请换一个位置'});}
        settings={...settings,backupDir:target};
        fs.writeFileSync(settingsPath+'.tmp',JSON.stringify(settings),{mode:0o600});fs.renameSync(settingsPath+'.tmp',settingsPath);
        tryBackup(true);
      } else if(req.method==='POST') {
        if(!cached.data)return reply(res,409,{error:'还没有资料库，创建或登录后才能备份'});
        if(!tryBackup(true))return reply(res,500,{error:'备份失败，请检查备份文件夹是否可以写入'});
      } else if(req.method!=='GET')return reply(res,405,{error:'Method not allowed'});
      return reply(res,200,backupInfo());
    }
    if(['/v1/profile','/v1/register','/v1/login','/v1/records'].includes(url.pathname)) {
      if(!remote)return reply(res,503,{error:'服务器尚未配置'});
      if(!['GET','POST','PUT'].includes(req.method))return reply(res,405,{error:'Method not allowed'});
      return relay(req,res,url,req.method==='GET'?null:await body(req));
    }
    reply(res,404,{error:'Not found'});
  }catch(e){reply(res,500,{error:'本地操作失败，请检查磁盘空间和文件权限'});}
});
server.requestTimeout=15000;
server.listen(port,'127.0.0.1');
// The backend runs all day, so the daily backup needs no scheduled task of its own.
setTimeout(()=>tryBackup(false),5000);
setInterval(()=>tryBackup(false),10*60*1000);

// AI conversation records (see ai-sync.cjs) go to the same server, encrypted with the remembered vault key.
// Only the normal vault syncs them; a test or second data folder never touches the real records folder.
function remoteRequest(method,pathname,payload,token) {
  return new Promise((resolve,reject)=>{
    const raw=payload?JSON.stringify(payload):null,headers={'Content-Type':'application/json'};
    if(raw)headers['Content-Length']=Buffer.byteLength(raw);
    if(token)headers.Authorization='Bearer '+token;
    const upstream=https.request(new URL(pathname,remote),{method,ca,rejectUnauthorized:true,headers,timeout:20000},up=>{
      let length=0;const chunks=[];
      up.on('data',chunk=>{length+=chunk.length;if(length>8*1024*1024)up.destroy(Error('Response too large'));else chunks.push(chunk);});
      up.on('error',reject);
      up.on('end',()=>{let data={};try{data=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{}resolve({status:up.statusCode,data});});
    });
    upstream.on('timeout',()=>upstream.destroy(Object.assign(Error('Timeout'),{code:'ETIMEDOUT'})));
    upstream.on('error',reject);
    if(raw)upstream.write(raw);upstream.end();
  });
}
const aiRecordsEnabled=!!process.env.TNOTES_AI_RECORDS||path.resolve(dataDir).toLowerCase()===path.resolve(standardDataDir).toLowerCase();
// Started once this process owns the port, so a second backend started by mistake never syncs alongside.
if(aiRecordsEnabled&&!process.env.TNOTES_NO_AI_SYNC)server.once('listening',()=>{
  createAiSync({
    root:recordsRoot(),
    request:remoteRequest,
    unavailable:()=>!remote?'未配置同步服务器，AI 记录只保存在本机':
      !cached.data?.profile?'随手记还没有登录过，暂不同步':
      !fs.existsSync(sessionPath)?'随手记没有记住登录，暂不同步（登录随手记时勾选“记住这台电脑”即可）':null,
    credentials:async()=>{
      const raw=await protectSession('Unprotect',fs.readFileSync(sessionPath,'utf8'));
      const value=JSON.parse(Buffer.from(raw,'base64').toString('utf8'));
      if(!validSession(value))return null;
      return {key:Buffer.from(value.encryptionKey,'base64'),auth:value.auth,vault:value.vaultId,name:cached.data.profile.name};
    },
    archiver:path.join(__dirname,'..','..','dev-tools','ai-records.ps1'),
  }).start();
});
server.on('error',e=>{console.error(e.code==='EADDRINUSE'?'TNotes port already in use':'TNotes startup failed');process.exitCode=1;});

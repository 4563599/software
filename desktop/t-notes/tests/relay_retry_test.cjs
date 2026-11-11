const https=require('node:https'),net=require('node:net'),fs=require('node:fs'),path=require('node:path');
const {spawn}=require('node:child_process');
const [work]=process.argv.slice(2);
const freePort=()=>new Promise(resolve=>{const s=net.createServer();s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p));});});
(async()=>{
 let agent,server;
 try{
  const counts={},bodies=[],directory=path.join(work,'retry-fixture');let connections=0;fs.mkdirSync(directory);
  server=https.createServer({key:fs.readFileSync(path.join(work,'key.pem')),cert:fs.readFileSync(path.join(work,'server-ca.pem'))},(req,res)=>{
   const route=req.url;counts[route]=(counts[route]||0)+1;
   const chunks=[];req.on('data',c=>chunks.push(c));req.on('end',()=>{
    if(route==='/v1/records'&&req.method==='PUT')bodies.push(Buffer.concat(chunks).toString());
    if(counts[route]===1){req.socket.destroy();return;}
    res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({items:[],rev:1}));
   });
  });
  server.on('connection',()=>connections++);
  await new Promise(resolve=>server.listen(0,resolve));
  fs.copyFileSync(path.join(work,'server-ca.pem'),path.join(directory,'server-ca.pem'));
  fs.writeFileSync(path.join(directory,'server.json'),JSON.stringify({url:'https://127.0.0.1:'+server.address().port+'/'}));
  const port=await freePort(),base='http://127.0.0.1:'+port;
  agent=spawn(process.execPath,[path.join(__dirname,'../client/desktop.cjs')],{env:{...process.env,TNOTES_PORT:String(port),TNOTES_DATA:directory,TNOTES_CONFIG:path.join(directory,'server.json')},windowsHide:true,stdio:'ignore'});
  let boot;
  for(let i=0;i<80;i++){try{boot=await(await fetch(base+'/api/bootstrap')).json();break;}catch{await new Promise(r=>setTimeout(r,50));}}
  if(!boot)throw Error('Retry fixture backend did not start');
  const headers={'X-TNotes-CSRF':boot.csrf,'Content-Type':'application/json'};
  const get=await fetch(base+'/v1/profile?name=retry-fixture',{headers});
  if(get.status!==200||counts['/v1/profile?name=retry-fixture']!==2)throw Error('Transient GET failure was not recovered');
  const put=await fetch(base+'/v1/records',{method:'PUT',headers,body:JSON.stringify({id:'fixture',base:0,envelope:{iv:'fake',data:'same-ciphertext'}})});
  if(put.status!==200||counts['/v1/records']!==2||bodies.length!==2||bodies[0]!==bodies[1])throw Error('PUT retry did not preserve the identical write');
  const register=await fetch(base+'/v1/register',{method:'POST',headers,body:'{}'});
  if(register.status!==502||counts['/v1/register']!==1)throw Error('Registration was retried unsafely');
  agent.kill();await new Promise(resolve=>agent.once('exit',resolve));
  fs.writeFileSync(path.join(directory,'server.json'),JSON.stringify({url:'https://localhost:'+server.address().port+'/'}));
  const before=connections;
  agent=spawn(process.execPath,[path.join(__dirname,'../client/desktop.cjs')],{env:{...process.env,TNOTES_PORT:String(port),TNOTES_DATA:directory,TNOTES_CONFIG:path.join(directory,'server.json')},windowsHide:true,stdio:'ignore'});
  boot=null;
  for(let i=0;i<80;i++){try{boot=await(await fetch(base+'/api/bootstrap')).json();break;}catch{await new Promise(r=>setTimeout(r,50));}}
  if(!boot)throw Error('Certificate fixture backend did not restart');
  const bad=await fetch(base+'/v1/records',{headers:{'X-TNotes-CSRF':boot.csrf}}),error=await bad.json();
  if(bad.status!==502||error.code!=='ERR_TLS_CERT_ALTNAME_INVALID'||connections-before!==1)throw Error('Certificate mismatch was not rejected immediately');
  console.log(JSON.stringify({transient_get_retry:'passed',identical_record_write_retry:'passed',registration_not_retried:'passed',certificate_validation_not_bypassed:'passed'}));
 }finally{
  if(agent){agent.kill();await new Promise(resolve=>agent.once('exit',resolve));}
  if(server)await new Promise(resolve=>server.close(resolve));
 }
})().catch(error=>{console.error(error.message);process.exitCode=1;});

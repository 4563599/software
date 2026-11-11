const encode = new TextEncoder();
const decode = new TextDecoder();
export const b64 = bytes => btoa(Array.from(new Uint8Array(bytes),b=>String.fromCharCode(b)).join(''));
export const unb64 = text => Uint8Array.from(atob(text),c=>c.charCodeAt(0));
export const randomSalt = () => b64(crypto.getRandomValues(new Uint8Array(16)));
export async function derive(master,salt,remember=false) {
  const password=await crypto.subtle.importKey('raw',encode.encode(master),'PBKDF2',false,['deriveBits']);
  const bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt:unb64(salt),iterations:600000},password,256);
  const root=await crypto.subtle.importKey('raw',bits,'HKDF',false,['deriveKey','deriveBits']);
  new Uint8Array(bits).fill(0);
  const params=label=>({name:'HKDF',hash:'SHA-256',salt:unb64(salt),info:encode.encode('tnotes-v1:'+label)});
  const keyBytes=await crypto.subtle.deriveBits(params('encryption'),root,256);
  const key=await crypto.subtle.importKey('raw',keyBytes,{name:'AES-GCM'},false,['encrypt','decrypt']);
  const material=remember?b64(keyBytes):null;
  new Uint8Array(keyBytes).fill(0);
  const authBytes=await crypto.subtle.deriveBits(params('authentication'),root,256);
  const auth=Array.from(new Uint8Array(authBytes),b=>b.toString(16).padStart(2,'0')).join('');
  new Uint8Array(authBytes).fill(0);
  return {key,auth,material};
}
export async function restore(session) {
  const bytes=unb64(session.encryptionKey);
  try {
    if(bytes.length!==32||!/^[a-f0-9]{64}$/.test(session.auth))throw Error('Invalid remembered login');
    const key=await crypto.subtle.importKey('raw',bytes,{name:'AES-GCM'},false,['encrypt','decrypt']);
    return {key,auth:session.auth};
  } finally {bytes.fill(0);}
}
export async function encrypt(key,vault,id,value) {
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const data=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encode.encode('tnotes-v1:'+vault+':'+id)},key,encode.encode(JSON.stringify(value)));
  return {iv:b64(iv),data:b64(data)};
}
export async function decrypt(key,vault,id,envelope) {
  const data=await crypto.subtle.decrypt({name:'AES-GCM',iv:unb64(envelope.iv),additionalData:encode.encode('tnotes-v1:'+vault+':'+id)},key,unb64(envelope.data));
  return JSON.parse(decode.decode(data));
}

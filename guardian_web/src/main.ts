import './style.css';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import {
  initializeApp,
} from 'firebase/app';
import {
  getAuth, onAuthStateChanged, setPersistence, browserLocalPersistence,
  signInAnonymously, type User,
} from 'firebase/auth';
import {
  getFirestore, doc, getDoc, setDoc, addDoc, collection, query, orderBy,
  limit, onSnapshot, updateDoc, serverTimestamp, Timestamp,
} from 'firebase/firestore';

type Msg = {
  id: string; fromUid: string; type: string; text?: string;
  imageBase64?: string; audioBase64?: string; durationSeconds?: number;
  createdAt?: Timestamp | Date | null;
};
type Stopper = () => void;

const env = import.meta.env;
const app = initializeApp({
  apiKey: env.VITE_FIREBASE_API_KEY,
  appId: env.VITE_FIREBASE_APP_ID,
  authDomain: env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: env.VITE_FIREBASE_PROJECT_ID,
  storageBucket: env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: env.VITE_FIREBASE_MESSAGING_SENDER_ID,
});
const auth = getAuth(app);
const db = getFirestore(app);
const root = document.querySelector<HTMLDivElement>('#app')!;
let currentUser: User | null = null;
let pairedUid: string | null = null;
let stopProfile: Stopper | undefined;
let stopCode: Stopper | undefined;
let stopMessages: Stopper | undefined;
let stopAlerts: Stopper | undefined;
let stopLocation: Stopper | undefined;
let currentCode = '';
let messageCache: Msg[] = [];
let alertsCache: Array<{id:string; type:string; resolved:boolean; createdAt?:Timestamp}> = [];
let lastLocation: {lat:number;lng:number;updatedAt?:Timestamp;batteryPercent?:number} | null = null;
let leafletMap: L.Map | null = null;
let locationMarker: L.Marker | null = null;

function esc(input: unknown): string {
  return String(input ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
}
function toast(message: string) {
  document.querySelector('.toast')?.remove();
  const node = document.createElement('div'); node.className = 'toast'; node.textContent = message;
  document.body.append(node); window.setTimeout(() => node.remove(), 2800);
}
function timeLabel(value?: Timestamp | Date | null): string {
  if (!value) return 'Just now';
  const date = value instanceof Timestamp ? value.toDate() : value;
  return date.toLocaleString([], {month:'short', day:'numeric', hour:'numeric', minute:'2-digit'});
}
function showError(error: unknown) {
  const message = error instanceof Error ? error.message : 'Something went wrong. Please try again.';
  const target = document.querySelector<HTMLElement>('#error');
  if (target) target.textContent = message;
  else toast(message);
  console.error('Guardian Hub:', message);
}

function renderPairing(code = '') {
  root.innerHTML = `<main class="login">
    <div class="brand"><div class="brand-mark">ANT</div><div><div class="brand-name">Guardian Hub</div><div class="brand-sub">Caretaker web companion</div></div></div>
    <h1>Connect to your user</h1>
    <p>This browser can pair with the ANT app using the same one-time code shown in caretaker onboarding. Keep this tab open while the user enters the code.</p>
    <div class="code-box"><div class="eyebrow">${code ? 'PAIRING CODE · EXPIRES IN 15 MINUTES' : 'READY TO PAIR'}</div>
      ${code ? `<div class="code" aria-label="Pairing code">${esc(code)}</div><button class="link-btn" id="copy-code">Copy code</button>` : `<button class="primary" id="make-code">Generate pairing code</button>`}
      <div class="muted" id="pairing-state">${code ? 'Waiting for the ANT user to enter this code…' : 'The code can be used once.'}</div>
    </div>
    <div class="notice">Pairing creates the caretaker account on this browser and links it to the user’s existing account. Use a browser profile you can return to; the pairing is stored in this browser.</div>
    <div id="error" class="error"></div>
  </main>`;
  document.querySelector('#make-code')?.addEventListener('click', () => void generatePairCode());
  document.querySelector('#copy-code')?.addEventListener('click', async () => {
    await navigator.clipboard.writeText(currentCode); toast('Pairing code copied');
  });
}

function renderDashboard() {
  root.innerHTML = `<div class="shell">
    <header class="topbar"><div class="brand"><div class="brand-mark">ANT</div><div><div class="brand-name">Guardian Hub</div><div class="brand-sub">Caretaker overview</div></div></div><div class="status"><span class="dot"></span><span id="connection-state">Connected</span></div></header>
    <main class="layout">
      <section class="left">
        <article class="card"><div class="card-head"><div><div class="card-title">Live location</div><div class="eyebrow">Last shared position from the ANT app</div></div><span class="pill" id="location-time">Waiting for location</span></div><div id="map" class="map"><div class="map-placeholder"><strong>No location shared yet</strong><span>Location appears while the user’s app is sharing it.</span></div></div><div class="person-row"><div class="avatar" id="person-initial">U</div><div><div class="person-name" id="person-name">Paired ANT user</div><div class="muted" id="person-detail">Location and alerts are private to this pair</div></div></div></article>
        <article class="card"><div class="card-head"><div><div class="card-title">Alerts</div><div class="eyebrow">Safety and check-in events</div></div><span class="pill" id="alert-count">0 open</span></div><div class="alerts" id="alerts-list"><div class="empty">No alerts yet.</div></div></article>
      </section>
      <section class="right"><article class="card chat"><div class="card-head chat-head"><div><div class="card-title">Messages</div><div class="eyebrow">Private conversation with the paired ANT user</div></div><span class="pill">Caretaker chat</span></div><div class="messages" id="messages"><div class="empty">Messages and shared snapshots will appear here.</div></div>
        <form class="composer" id="composer"><div class="compose-row"><textarea class="compose-text" id="message-text" rows="1" placeholder="Write a message…" aria-label="Write a message"></textarea><button class="send-btn" type="submit">Send</button></div><div class="action-row"><button class="action-btn" id="snapshot-request" type="button">▧ Request snapshot</button><button class="action-btn" id="pick-image" type="button">＋ Send image</button><button class="action-btn" id="voice-record" type="button">◉ Voice memo</button><input class="hidden" id="image-file" type="file" accept="image/*" /></div><div class="hint" id="record-hint">Voice memos are short recordings; use the controls in chat to replay them.</div></form>
      </article></section>
    </main><div class="toast hidden"></div>
  </div>`;
  document.querySelector<HTMLFormElement>('#composer')!.addEventListener('submit', (e) => { e.preventDefault(); void sendText(); });
  document.querySelector('#snapshot-request')!.addEventListener('click', () => void sendSnapshotRequest());
  document.querySelector('#pick-image')!.addEventListener('click', () => document.querySelector<HTMLInputElement>('#image-file')!.click());
  document.querySelector<HTMLInputElement>('#image-file')!.addEventListener('change', (e) => {
    const file = (e.currentTarget as HTMLInputElement).files?.[0]; if (file) void sendPhoto(file);
  });
  document.querySelector('#voice-record')!.addEventListener('click', () => void recordVoiceMemo());
  const input = document.querySelector<HTMLTextAreaElement>('#message-text')!;
  input.addEventListener('input', () => { input.style.height = 'auto'; input.style.height = `${Math.min(input.scrollHeight, 120)}px`; });
  bootMap();
  renderMessages(); renderAlerts(); updateLocation();
}

async function ensureCaretakerProfile(user: User) {
  const userRef = doc(db, 'users', user.uid);
  const snap = await getDoc(userRef);
  if (!snap.exists()) {
    await setDoc(userRef, {uid:user.uid, role:'caretaker', language:'english', pairedUserId:null, onboardingComplete:true});
    return null;
  }
  const profile = snap.data();
  if (profile.role !== 'caretaker') throw new Error('This browser is already linked to a different ANT role. Please open a separate browser profile for the caretaker hub.');
  return typeof profile.pairedUserId === 'string' ? profile.pairedUserId : null;
}

async function generatePairCode() {
  if (!currentUser) return;
  try {
    const status = document.querySelector<HTMLElement>('#pairing-state'); if (status) status.textContent = 'Creating a code…';
    let code = '';
    for (let tries=0; tries<8; tries++) {
      const bytes = crypto.getRandomValues(new Uint32Array(1));
      code = String(bytes[0] % 1_000_000).padStart(6, '0');
      const existing = await getDoc(doc(db, 'pairingCodes', code));
      if (!existing.exists()) break;
      code = '';
    }
    if (!code) throw new Error('Could not reserve a pairing code. Try again.');
    await setDoc(doc(db, 'pairingCodes', code), {caretakerUid:currentUser.uid, disabledUserUid:null, createdAt:serverTimestamp(), expiresAt:Timestamp.fromDate(new Date(Date.now()+15*60_000))});
    currentCode = code; renderPairing(code); watchPairCode(code);
  } catch (e) { showError(e); }
}

function watchPairCode(code: string) {
  stopCode?.(); stopCode = onSnapshot(doc(db, 'pairingCodes', code), (snap) => {
    const disabledUid = snap.data()?.disabledUserUid as string | null | undefined;
    if (disabledUid) { pairedUid = disabledUid; stopCode?.(); renderDashboard(); subscribePairedData(disabledUid); }
  }, showError);
}

function subscribePairedData(uid: string) {
  stopMessages?.(); stopAlerts?.(); stopLocation?.();
  stopMessages = onSnapshot(query(collection(db, 'communications', uid, 'messages'), orderBy('createdAt','desc'), limit(50)), (snap) => {
    messageCache = snap.docs.map(d => ({id:d.id, ...d.data()} as Msg)).reverse(); renderMessages();
  }, showError);
  stopAlerts = onSnapshot(query(collection(db, 'alerts', uid, 'items'), orderBy('createdAt','desc'), limit(30)), (snap) => {
    alertsCache = snap.docs.map(d => ({id:d.id, ...d.data()} as typeof alertsCache[number])); renderAlerts();
  }, showError);
  stopLocation = onSnapshot(doc(db, 'liveLocations', uid), (snap) => {
    lastLocation = snap.exists() ? snap.data() as typeof lastLocation : null; updateLocation();
  }, showError);
  void getDoc(doc(db,'users',uid)).then(s => {
    const name = s.data()?.name ?? s.data()?.displayName ?? 'Paired ANT user';
    const nameNode = document.querySelector<HTMLElement>('#person-name'); if (nameNode) nameNode.textContent = String(name);
    const initial = document.querySelector<HTMLElement>('#person-initial'); if (initial) initial.textContent = String(name).slice(0,1).toUpperCase();
  }).catch(showError);
}

function bootMap() {
  const mapNode = document.querySelector<HTMLElement>('#map'); if (!mapNode) return;
  leafletMap?.remove(); leafletMap = null;
  mapNode.innerHTML = '';
  leafletMap = L.map(mapNode, {zoomControl:true}).setView([23.8103,90.4125], 12);
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {maxZoom:19, attribution:'&copy; OpenStreetMap contributors'}).addTo(leafletMap);
  locationMarker = L.marker([23.8103,90.4125]).addTo(leafletMap);
  window.setTimeout(() => leafletMap?.invalidateSize(), 150);
}

function updateLocation() {
  const time = document.querySelector<HTMLElement>('#location-time'); if (!time) return;
  if (!lastLocation || typeof lastLocation.lat !== 'number' || typeof lastLocation.lng !== 'number') { time.textContent='Waiting for location'; return; }
  if (!leafletMap) bootMap();
  const point: L.LatLngExpression = [lastLocation.lat,lastLocation.lng];
  locationMarker?.setLatLng(point); leafletMap?.setView(point, Math.max(leafletMap.getZoom(),15));
  time.textContent = lastLocation.updatedAt ? timeLabel(lastLocation.updatedAt) : 'Recently shared';
  const detail = document.querySelector<HTMLElement>('#person-detail'); if (detail) detail.textContent = lastLocation.batteryPercent != null ? `Battery ${lastLocation.batteryPercent}% · ${time.textContent}` : `Latest position · ${time.textContent}`;
}

function renderMessages() {
  const list = document.querySelector<HTMLElement>('#messages'); if (!list) return;
  if (!messageCache.length) { list.innerHTML='<div class="empty">Messages and shared snapshots will appear here.</div>'; return; }
  list.innerHTML = messageCache.map(m => {
    const mine = m.fromUid === currentUser?.uid;
    const text = m.text ? `<div>${esc(m.text)}</div>` : '';
    const image = m.imageBase64 ? `<img src="data:image/jpeg;base64,${esc(m.imageBase64)}" alt="Shared image" loading="lazy">` : '';
    const audio = m.audioBase64 ? `<audio controls preload="none" src="data:audio/wav;base64,${esc(m.audioBase64)}"></audio>` : '';
    const label = m.type === 'snapshotRequest' ? 'Snapshot requested' : m.type === 'voiceMemo' ? `Voice memo${m.durationSeconds ? ` · ${m.durationSeconds}s` : ''}` : m.type === 'snapshotReply' ? 'Snapshot reply' : m.type === 'photo' ? 'Image' : '';
    return `<div class="bubble ${mine?'mine':'theirs'}">${label ? `<div class="muted">${esc(label)}</div>`:''}${text}${image}${audio}<div class="bubble-meta">${mine?'You':'ANT user'} · ${esc(timeLabel(m.createdAt))}</div></div>`;
  }).join('');
  list.scrollTop = list.scrollHeight;
}

function renderAlerts() {
  const list = document.querySelector<HTMLElement>('#alerts-list'); if (!list) return;
  const open = alertsCache.filter(a=>!a.resolved);
  const count = document.querySelector<HTMLElement>('#alert-count'); if (count) count.textContent=`${open.length} open`;
  if (!alertsCache.length) { list.innerHTML='<div class="empty">No alerts yet.</div>'; return; }
  list.innerHTML=alertsCache.map(a=>{
    const title = a.type==='magicButton'?'Magic Button pressed':a.type==='userRequested'?'Asked you to check in':'No movement detected';
    return `<div class="alert"><div class="alert-icon">${a.type==='magicButton'?'!':'•'}</div><div class="alert-info"><div class="alert-name">${esc(title)}${a.resolved?' · Resolved':''}</div><div class="muted">${esc(timeLabel(a.createdAt))}</div></div>${a.resolved?'':`<button class="resolve" data-alert="${esc(a.id)}">Resolve</button>`}</div>`;
  }).join('');
  list.querySelectorAll<HTMLButtonElement>('[data-alert]').forEach(button=>button.addEventListener('click',()=>void resolveAlert(button.dataset.alert!)));
}

async function sendMessage(data: {type:string;text:string;imageBase64?:string;audioBase64?:string;durationSeconds?:number}) {
  if (!currentUser || !pairedUid) return;
  await addDoc(collection(db,'communications',pairedUid,'messages'), {fromUid:currentUser.uid,toUid:pairedUid,...data,createdAt:serverTimestamp()});
}
async function sendText() {
  const input=document.querySelector<HTMLTextAreaElement>('#message-text'); if (!input) return;
  const text=input.value.trim(); if (!text) return;
  try { await sendMessage({type:'memo',text}); input.value=''; input.style.height='44px'; input.focus(); }
  catch(e){showError(e);}
}
async function sendSnapshotRequest() {
  try { await sendMessage({type:'snapshotRequest',text:'Snapshot requested.'}); toast('Snapshot requested'); }
  catch(e){showError(e);}
}

function fileToDataUrl(file: Blob): Promise<string> { return new Promise((resolve,reject)=>{const r=new FileReader();r.onerror=()=>reject(new Error('Could not read this file.'));r.onload=()=>resolve(String(r.result));r.readAsDataURL(file);}); }
async function compressImage(file: File): Promise<string> {
  const url=await fileToDataUrl(file); const image=new Image(); image.src=url;
  await new Promise<void>((resolve,reject)=>{image.onload=()=>resolve();image.onerror=()=>reject(new Error('Could not open that image.'));});
  const scale=Math.min(1,1280/Math.max(image.width,image.height)); const canvas=document.createElement('canvas');canvas.width=Math.round(image.width*scale);canvas.height=Math.round(image.height*scale);
  const ctx=canvas.getContext('2d');if(!ctx)throw new Error('Image processing is not available in this browser.');ctx.drawImage(image,0,0,canvas.width,canvas.height);
  let quality=.82;let data=canvas.toDataURL('image/jpeg',quality);
  while(data.length>850_000&&quality>.48){quality-=.08;data=canvas.toDataURL('image/jpeg',quality);}
  if(data.length>950_000)throw new Error('That image is too large to send safely. Choose a smaller image.');
  return data.split(',')[1];
}
async function sendPhoto(file: File) {
  if (!file.type.startsWith('image/')) { toast('Choose an image file'); return; }
  try { const imageBase64=await compressImage(file); await sendMessage({type:'photo',text:'',imageBase64});toast('Image sent'); }
  catch(e){showError(e);}
  const input=document.querySelector<HTMLInputElement>('#image-file');if(input)input.value='';
}

function encodeWav(audio: AudioBuffer): Blob {
  const targetRate=16000, samples=Math.max(1,Math.floor(audio.duration*targetRate));
  const channels=audio.numberOfChannels;const source=Array.from({length:channels},(_,c)=>audio.getChannelData(c));
  const bytes=new ArrayBuffer(44+samples*2),view=new DataView(bytes);
  const write=(offset:number,value:string)=>{for(let i=0;i<value.length;i++)view.setUint8(offset+i,value.charCodeAt(i));};
  write(0,'RIFF');view.setUint32(4,36+samples*2,true);write(8,'WAVE');write(12,'fmt ');view.setUint32(16,16,true);view.setUint16(20,1,true);view.setUint16(22,1,true);view.setUint32(24,targetRate,true);view.setUint32(28,targetRate*2,true);view.setUint16(32,2,true);view.setUint16(34,16,true);write(36,'data');view.setUint32(40,samples*2,true);
  for(let i=0;i<samples;i++){const sourceIndex=Math.min(Math.floor(i*audio.sampleRate/targetRate),audio.length-1);let value=0;for(let c=0;c<channels;c++)value+=source[c][sourceIndex]??0;value/=channels;value=Math.max(-1,Math.min(1,value));view.setInt16(44+i*2,value<0?value*0x8000:value*0x7fff,true);}
  return new Blob([bytes],{type:'audio/wav'});
}
async function recordVoiceMemo() {
  const button=document.querySelector<HTMLButtonElement>('#voice-record');const hint=document.querySelector<HTMLElement>('#record-hint');
  if(!navigator.mediaDevices?.getUserMedia||!window.MediaRecorder){toast('Voice recording needs a supported browser and microphone access');return;}
  try{
    const stream=await navigator.mediaDevices.getUserMedia({audio:true});const recorder=new MediaRecorder(stream);const chunks:BlobPart[]=[];
    let seconds=0;button!.textContent='■ Stop recording';hint!.textContent='Recording… maximum 20 seconds';
    const timer=window.setInterval(()=>{seconds++;if(seconds>=20&&recorder.state==='recording')recorder.stop();},1000);
    const stopped=new Promise<Blob>((resolve,reject)=>{recorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data);};recorder.onerror=()=>reject(new Error('Recording failed.'));recorder.onstop=()=>resolve(new Blob(chunks,{type:recorder.mimeType||'audio/webm'}));});
    recorder.start();
    button!.addEventListener('click',()=>{if(recorder.state==='recording')recorder.stop();},{once:true});
    const clip=await stopped;window.clearInterval(timer);stream.getTracks().forEach(t=>t.stop());
    const AudioContextClass=window.AudioContext;const context=new AudioContextClass();const decoded=await context.decodeAudioData(await clip.arrayBuffer());const wav=encodeWav(decoded);await context.close();
    const bytes=new Uint8Array(await wav.arrayBuffer());let binary='';for(let i=0;i<bytes.length;i+=0x8000)binary+=String.fromCharCode(...bytes.subarray(i,i+0x8000));
    await sendMessage({type:'voiceMemo',text:'',audioBase64:btoa(binary),durationSeconds:Math.min(20,Math.max(1,Math.round(decoded.duration)))});
    toast('Voice memo sent');
  }catch(e){showError(e);}
  finally{if(button)button.textContent='◉ Voice memo';if(hint)hint.textContent='Voice memos are short recordings; use the controls in chat to replay them.';}
}

async function resolveAlert(id:string){
  if(!pairedUid)return;
  try{await updateDoc(doc(db,'alerts',pairedUid,'items',id),{resolved:true,resolvedAt:serverTimestamp()});toast('Alert marked resolved');}
  catch(e){showError(e);}
}

async function start(user: User) {
  currentUser=user;
  try {
    pairedUid=await ensureCaretakerProfile(user);
    if(pairedUid){renderDashboard();subscribePairedData(pairedUid);}
    else {renderPairing(currentCode);if(currentCode)watchPairCode(currentCode);}
    stopProfile?.();stopProfile=onSnapshot(doc(db,'users',user.uid),(snap)=>{
      const linked=snap.data()?.pairedUserId;
      if(typeof linked==='string'&&linked!==pairedUid){pairedUid=linked;stopCode?.();renderDashboard();subscribePairedData(linked);}
    },showError);
  }catch(e){renderPairing();showError(e);}
}

renderPairing();
setPersistence(auth,browserLocalPersistence).then(()=>onAuthStateChanged(auth,(user)=>{
  if(user)void start(user);else void signInAnonymously(auth).catch(showError);
})).catch(showError);

window.addEventListener('beforeunload',()=>{stopProfile?.();stopCode?.();stopMessages?.();stopAlerts?.();stopLocation?.();leafletMap?.remove();});

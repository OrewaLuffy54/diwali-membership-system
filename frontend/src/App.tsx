import { useEffect, useState } from 'react';
import { createClient, Session } from '@supabase/supabase-js';
import { ShieldCheck, Gamepad2, Monitor, Smartphone, Wallet, Clock3, LogIn, LogOut, Send, CheckCircle2, Sparkles, Shield, ArrowUpRight, Check, AlertCircle } from 'lucide-react';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string;
const supabaseAnon = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
const apiBase = (import.meta.env.VITE_API_BASE as string || '').replace(/\/$/, '');
const supabase = supabaseUrl && supabaseAnon ? createClient(supabaseUrl, supabaseAnon, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } }) : null;

export default function App() {
  const [session,setSession] = useState<Session|null>(null);
  const [authReady,setAuthReady] = useState(false);
  const [mc,setMc] = useState('');
  const [edition,setEdition] = useState<'java'|'bedrock'>('java');
  const [utr,setUtr] = useState('');
  const [plans,setPlans] = useState<any[]>([]);
  const [planId,setPlanId] = useState('monthly');
  const [coupon,setCoupon] = useState('');
  const [redeemCode,setRedeemCode] = useState('');
  const [redeemMc,setRedeemMc] = useState('');
  const [redeemEdition,setRedeemEdition] = useState<'java'|'bedrock'>('java');
  const [codeDays,setCodeDays] = useState('30');
  const [codeQty,setCodeQty] = useState('1');
  const [generated,setGenerated] = useState<any[]>([]);
  const [couponName,setCouponName] = useState('');
  const [couponValue,setCouponValue] = useState('10');
  const [couponExpiry,setCouponExpiry] = useState('');
  const [couponMaxUses,setCouponMaxUses] = useState('100');
  const [couponUnlimited,setCouponUnlimited] = useState(false);
  const [coupons,setCoupons] = useState<any[]>([]);
  const [editingCoupon,setEditingCoupon] = useState<string|null>(null);
  const [couponQuote,setCouponQuote] = useState<any>(null);
  const [status,setStatus] = useState('');
  const [busy,setBusy] = useState(false);
  const [adminMe,setAdminMe] = useState<any>(null);
  const [admins,setAdmins] = useState<any[]>([]);
  const [members,setMembers] = useState<any[]>([]);
  const [extendTarget,setExtendTarget] = useState<string|null>(null);
  const [extendDays,setExtendDays] = useState('30');
  const [extendDateTime,setExtendDateTime] = useState('');
  const [extendMode,setExtendMode] = useState<'days'|'date'>('days');
  const [editablePlans,setEditablePlans] = useState<any[]>([]);
  const [adminDiscordId,setAdminDiscordId] = useState('');
  const [adminRole,setAdminRole] = useState('custom');
  const [editingAdmin,setEditingAdmin] = useState<string|null>(null);
  const [adminPermissions,setAdminPermissions] = useState<string[]>([]);
  const [auditLogs,setAuditLogs] = useState<any[]>([]);
  const [pending,setPending] = useState<any[]>([]);
  const [message,setMessage] = useState('');
  const [copiedItem,setCopiedItem] = useState<string|null>(null);
  async function copyServerValue(value:string, item:'java-ip'|'bedrock-ip'|'bedrock-port') {
    try {
      if (navigator.clipboard?.writeText && window.isSecureContext) {
        await navigator.clipboard.writeText(value);
      } else {
        const field = document.createElement('textarea');
        field.value = value;
        field.setAttribute('readonly', '');
        field.style.position = 'fixed';
        field.style.opacity = '0';
        document.body.appendChild(field);
        field.select();
        const copied = document.execCommand('copy');
        document.body.removeChild(field);
        if (!copied) throw new Error('Copy was blocked by the browser');
      }
      setCopiedItem(item);
      window.setTimeout(() => setCopiedItem(current => current === item ? null : current), 1800);
    } catch {
      setMessage('Could not copy automatically. Please select and copy the server details manually.');
    }
  }
  useEffect(()=>{ if(apiBase) fetch(apiBase+'/api/plans').then(r=>r.json()).then(j=>{if(j.items?.length){setPlans(j.items);setPlanId(j.items[0].id);}}).catch(()=>{}); if(!supabase) return; supabase.auth.getSession().then(({data,error})=>{setSession(data.session);setAuthReady(true);if(error)setMessage(error.message);}); const {data:{subscription}}=supabase.auth.onAuthStateChange((_e,s)=>{setSession(s);setAuthReady(true);}); return ()=>subscription.unsubscribe(); },[]);
  useEffect(()=>{ if(session) loadAdminMe(); else {setAdminMe(null);setAdmins([]);setPending([]);} },[session]);
  useEffect(()=>{setCouponQuote(null);},[planId]);
  useEffect(()=>{if(adminMe?.active&&(adminMe.is_owner||adminMe.permissions?.includes('manage_coupons')))loadCoupons();},[adminMe]);
  const permissionList=[['view_members','View members'],['view_payments','View payments'],['approve_payments','Approve payments'],['reject_payments','Reject payments'],['manage_memberships','Manage memberships'],['create_gift_codes','Create gift codes'],['manage_coupons','Manage coupons'],['manage_plans','Manage plans'],['view_audit_logs','View audit logs']];
  const presets:Record<string,string[]>={admin:permissionList.map(x=>x[0]).filter(x=>x!=='manage_admins'),moderator:['view_members','view_payments'],support:['view_members'],payment_manager:['view_payments','approve_payments','reject_payments'],membership_manager:['view_members','manage_memberships'],coupon_manager:['manage_coupons','create_gift_codes'],custom:[]};
  async function adminRequest(path:string,init:RequestInit={}){if(!session)throw new Error('Sign in with Discord first');const r=await fetch(apiBase+path,{...init,headers:{'content-type':'application/json','authorization':`Bearer ${session.access_token}`,...(init.headers||{})}});const j=await r.json();if(!r.ok)throw new Error(j.error||'Admin request failed');return j;}
  async function loadAdminMe(){try{const r=await fetch(apiBase+'/api/admin/me',{headers:{authorization:`Bearer ${session?.access_token}`}});const j=await r.json();setAdminMe(r.ok?j:null);}catch{setAdminMe(null);}}
  async function loadAdmins(){try{const j=await adminRequest('/api/admin/admins');setAdmins(j.items||[]);}catch(e:any){setMessage(e.message);}}
  async function addAdmin(){try{if(editingAdmin){await updateAdmin(editingAdmin,{role:adminRole,permissions:adminPermissions});setEditingAdmin(null);}else{await adminRequest('/api/admin/admins',{method:'POST',body:JSON.stringify({discord_id:adminDiscordId.trim(),role:adminRole,permissions:adminPermissions})});setMessage('Admin added successfully.');}setAdminDiscordId('');setAdminPermissions([]);await loadAdmins();}catch(e:any){setMessage(e.message);}}
  async function updateAdmin(id:string,patch:any){try{await adminRequest('/api/admin/admins/'+id,{method:'PATCH',body:JSON.stringify(patch)});setMessage('Admin permissions updated.');await loadAdmins();}catch(e:any){setMessage(e.message);}}
  async function removeAdmin(id:string){if(!window.confirm('Remove this admin access?'))return;try{await adminRequest('/api/admin/admins/'+id,{method:'DELETE'});setMessage('Admin access removed.');await loadAdmins();}catch(e:any){setMessage(e.message);}}
  async function loadPlans(){try{const j=await adminRequest('/api/admin/plans');setEditablePlans(j.items||[]);}catch(e:any){setMessage(e.message);}}
  async function savePlan(p:any){try{await adminRequest('/api/admin/plans',{method:'PATCH',body:JSON.stringify({...p,price_paise:Math.round(Number(p.price_rupees)*100)})});setMessage('Subscription plan updated.');await loadPlans();}catch(e:any){setMessage(e.message);}}
  async function loadMembers(){try{const j=await adminRequest('/api/admin/members');setMembers(j.items||[]);}catch(e:any){setMessage(e.message);}}
  async function setMembership(id:string,status:string){try{await adminRequest('/api/admin/members/'+id,{method:'PATCH',body:JSON.stringify({status})});setMessage('Membership updated.');await loadMembers();}catch(e:any){setMessage(e.message);}}
  function istDateTimeToIso(value:string){if(!value)return '';return new Date(value+':00+05:30').toISOString();}
  async function extendMembership(member:any,membership:any){
    try{
      const currentExpiry=new Date(membership?.expires_at||Date.now());
      let expiry:Date;
      if(extendMode==='days'){
        const base=currentExpiry.getTime()>Date.now()?currentExpiry:new Date();
        const days=Math.floor(Number(extendDays));
        if(!Number.isInteger(days)||days<1||days>3650)throw new Error('Enter days between 1 and 3650.');
        expiry=new Date(base.getTime()+days*86400000);
      }else{
        const iso=istDateTimeToIso(extendDateTime);
        if(!iso)throw new Error('Select a new expiry date and time.');
        expiry=new Date(iso);
        if(expiry.getTime()<=Date.now())throw new Error('New expiry must be in the future.');
      }
      await adminRequest('/api/admin/members/'+membership.id,{method:'PATCH',body:JSON.stringify({expires_at:expiry.toISOString(),status:'active'})});
      setMessage(`${member.minecraft_username} membership extended until ${expiry.toLocaleString('en-IN',{timeZone:'Asia/Kolkata'})} IST.`);
      setExtendTarget(null);setExtendDateTime('');await loadMembers();
    }catch(e:any){setMessage(e.message);}
  }
  async function deleteMember(member:any){
    const ok=window.confirm(`Delete ${member.minecraft_username}'s membership? Access will be revoked and the account archived. Payment and audit history will be retained.`);
    if(!ok)return;
    try{
      await adminRequest('/api/admin/members/'+member.id,{method:'DELETE'});
      setMessage(`${member.minecraft_username} membership revoked and account archived.`);
      setMembers(old=>old.filter(x=>x.id!==member.id));
    }catch(e:any){setMessage(e.message);}
  }

  async function loadAudit(){try{const j=await adminRequest('/api/admin/audit');setAuditLogs(j.items||[]);}catch(e:any){setMessage(e.message);}}
  async function loadCoupons(){try{const j=await adminRequest('/api/admin/coupons');setCoupons(j.items||[]);}catch(e:any){setMessage(e.message);}}
  async function validateCoupon(){if(!coupon.trim()){setCouponQuote(null);return;}setBusy(true);try{const r=await fetch(apiBase+'/api/coupons/validate',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({coupon_code:coupon.trim(),plan_id:planId})});const j=await r.json();if(!r.ok)throw new Error(j.error||'Coupon validation failed');setCouponQuote(j);setMessage(`${j.code} applied: ₹${(j.discount_paise/100).toFixed(2)} discount.`);}catch(e:any){setCouponQuote(null);setMessage(e.message);}finally{setBusy(false);}}

  const discordId = session?.user?.identities?.find(i=>i.provider==='discord')?.identity_data?.provider_id || session?.user?.user_metadata?.provider_id || '';
  async function login(){ if(!supabase){setMessage('Configure Supabase URL and anon key first.');return;} const {error}=await supabase.auth.signInWithOAuth({provider:'discord',options:{redirectTo:window.location.origin,scopes:'identify email'}}); if(error)setMessage(error.message); }
  async function logout(){await supabase?.auth.signOut();setSession(null);}
  async function submit(){ if(!session||!apiBase){setMessage('Please sign in and configure the API.');return;} if(!mc.trim()||!utr.trim()){setMessage('Enter Minecraft username and UTR.');return;} setBusy(true); try {const r=await fetch(apiBase+'/api/payment-submissions',{method:'POST',headers:{'content-type':'application/json','authorization':`Bearer ${session.access_token}`},body:JSON.stringify({minecraft_username:mc.trim(),edition,utr:utr.trim(),plan_id:planId,coupon_code:coupon.trim()})}); const j=await r.json(); setMessage(r.ok?`Payment request submitted for ₹${(j.amount_paise/100).toFixed(2)} (${j.duration_days} days). Admin verification is pending.`:(j.error||'Submission failed'));}catch{setMessage('Could not contact membership API.');}finally{setBusy(false);} }
  async function loadPending(){setBusy(true);try{const j=await adminRequest('/api/admin/pending');setPending(j.items||[]);setMessage('Pending submissions loaded.');}catch(e:any){setMessage(e.message);}finally{setBusy(false);}}
  async function decide(id:string,action:'approve'|'reject'){setBusy(true);try{await adminRequest(`/api/admin/${action}/${id}`,{method:'POST'});setMessage(`${action==='approve'?'Approved':'Rejected'} successfully.`);await loadPending();}catch(e:any){setMessage(e.message);}finally{setBusy(false);}}
  async function redeem(){if(!session||!apiBase){setMessage('Sign in with Discord first.');return;}setBusy(true);try{const r=await fetch(apiBase+'/api/redeem',{method:'POST',headers:{'content-type':'application/json','authorization':`Bearer ${session.access_token}`},body:JSON.stringify({code:redeemCode.trim(),minecraft_username:redeemMc.trim(),edition:redeemEdition})});const j=await r.json();setMessage(r.ok?`Gift redeemed! ${j.duration_days} days added to your membership.`:(j.error||'Redeem failed'));}catch{setMessage('Could not contact membership API.');}finally{setBusy(false);}}
  function resetCouponForm(){setCouponName('');setCouponValue('10');setCouponExpiry('');setCouponMaxUses('100');setCouponUnlimited(false);setEditingCoupon(null);}
  async function createCoupon(){setBusy(true);try{const body={code:couponName,discount_type:'percent',discount_value:Number(couponValue),max_uses:Number(couponMaxUses),unlimited:couponUnlimited,expires_at:couponExpiry?new Date(couponExpiry).toISOString():null};if(editingCoupon){await adminRequest('/api/admin/coupons/'+editingCoupon,{method:'PATCH',body:JSON.stringify(body)});setMessage('Coupon updated.');}else{await adminRequest('/api/admin/coupons',{method:'POST',body:JSON.stringify(body)});setMessage('Promotional coupon created.');}resetCouponForm();await loadCoupons();}catch(e:any){setMessage(e.message);}finally{setBusy(false);}}
  async function couponAction(id:string,patch:any,success:string){setBusy(true);try{await adminRequest('/api/admin/coupons/'+id,{method:'PATCH',body:JSON.stringify(patch)});setMessage(success);await loadCoupons();}catch(e:any){setMessage(e.message);}finally{setBusy(false);}}
  async function deleteCoupon(id:string){if(!window.confirm('Delete this unused coupon? This is only allowed when it has no payment references.'))return;setBusy(true);try{await adminRequest('/api/admin/coupons/'+id,{method:'DELETE'});setMessage('Coupon deleted.');await loadCoupons();}catch(e:any){setMessage(e.message);}finally{setBusy(false);}}
  function beginCouponEdit(c:any){setEditingCoupon(c.id);setCouponName(c.code);setCouponValue(String(c.discount_value));setCouponExpiry(c.expires_at?new Date(c.expires_at).toISOString().slice(0,16):'');setCouponUnlimited(c.max_uses===null);setCouponMaxUses(c.max_uses===null?'':String(c.max_uses));}
  function couponStatus(c:any){if(!c.active)return 'Disabled';if(c.expires_at&&new Date(c.expires_at)<=new Date())return 'Expired';if(c.max_uses!==null&&c.uses>=c.max_uses)return 'Exhausted';return 'Active';}
  async function generateCodes(){setBusy(true);try{const j=await adminRequest('/api/admin/codes',{method:'POST',body:JSON.stringify({duration_days:Number(codeDays),quantity:Number(codeQty),code_type:'gift'})});setGenerated(j.items||[]);setMessage('Gift codes generated.');}catch(e:any){setMessage(e.message);}finally{setBusy(false);}}
  return <main>
    <nav><div className="brand"><span className="mark">DN</span><span>DIWALI <b>NETWORK</b></span></div><div className="navright"><span className="online"><i/> NETWORK ONLINE</span>{adminMe?.authenticated&&adminMe?.active&&<a className="admin-nav-link" href="#admin-portal"><ShieldCheck size={14}/> ADMIN PORTAL</a>}{!authReady?<span className="authloading">Checking session…</span>:session?<div className="userchip">{session.user.user_metadata?.avatar_url?<img src={session.user.user_metadata.avatar_url} alt=""/>:<span className="avatarfallback">{(session.user.user_metadata?.full_name||session.user.email||'D').slice(0,1).toUpperCase()}</span>}<span>{session.user.user_metadata?.global_name||session.user.user_metadata?.full_name||session.user.user_metadata?.name||'Discord member'}</span><button className="iconbtn" onClick={logout} title="Sign out"><LogOut size={15}/></button></div>:<button className="discordbtn" onClick={login}><span className="discordicon"><LogIn size={16}/></span><span>Continue with Discord</span><ArrowUpRight size={15}/></button>}</div></nav>
    <section className="hero"><div className="eyebrow"><span/> SURVIVAL ACCESS <i className="eyebrow-divider"/> SMP 2.0 <span className="live-pill"><Sparkles size={11}/> NOW OPEN</span></div><h1>Your next<br/><em>adventure</em> starts here.</h1><p>Join the Diwali Network survival community. One simple membership keeps your adventure alive.</p><div className="heroactions"><a className="primary" href="#join">Get Membership <span>↗</span></a><a className="secondary" href="https://discord.gg/Pdz2yCdvSQ" target="_blank">Join Discord</a></div><div className="server-connect" aria-label="Minecraft server connection details">
        <div className="server-line"><Gamepad2 size={17}/><span className="server-edition">JAVA</span><strong>diwali-net.hostrium.pro</strong><button type="button" className={copiedItem==='java-ip'?'is-copied':''} onClick={()=>copyServerValue('diwali-net.hostrium.pro','java-ip')}>{copiedItem==='java-ip'?<><Check size={13}/> COPIED!</>:'COPY IP'}</button></div>
        <div className="server-divider"/>
        <div className="server-line"><Gamepad2 size={17}/><span className="server-edition bedrock">BEDROCK</span><strong>diwali-net.hostrium.pro</strong><span className="server-port">PORT <b>25626</b></span><button type="button" className={copiedItem==='bedrock-ip'?'is-copied':''} onClick={()=>copyServerValue('diwali-net.hostrium.pro','bedrock-ip')}>{copiedItem==='bedrock-ip'?<><Check size={13}/> COPIED!</>:'COPY IP'}</button><button type="button" className={`port-copy ${copiedItem==='bedrock-port'?'is-copied':''}`} onClick={()=>copyServerValue('25626','bedrock-port')}>{copiedItem==='bedrock-port'?<><Check size={13}/> COPIED!</>:'COPY PORT'}</button></div>
      </div></section>
    <section className="content" id="join"><div className="sectionhead"><div><div className="eyebrow">SIMPLE. FAIR. READY.</div><h2>Membership access</h2></div><span className="tag">MANUAL PAYMENT VERIFICATION</span></div>
      <div className="plan-picker"><div className="eyebrow">SELECT YOUR PASS</div><div className="plan-options">{plans.map(p=><button type="button" key={p.id} className={`plan-option ${planId===p.id?'selected':''}`} onClick={()=>setPlanId(p.id)}><b>{p.name}</b><strong>₹{(p.price_paise/100).toFixed(0)}</strong><small>{p.duration_days} days</small></button>)}</div></div>
      <div className="grid"><article className="price card"><div className="cardlabel"><ShieldCheck size={17}/> NETWORK PASS</div><div className="amount">₹{((plans.find(p=>p.id===planId)?.price_paise??5000)/100).toFixed(0)}<span>/ {plans.find(p=>p.id===planId)?.duration_days??30} days</span></div><p>Full access to Diwali Network while your membership is active.</p><ul><li><CheckCircle2/> Minecraft whitelist access</li><li><CheckCircle2/> Discord expiry reminders</li><li><CheckCircle2/> Easy renewal</li></ul><div className="note">Membership starts when your payment is approved.</div></article>
      <article className="pay card"><div className="cardlabel"><Wallet size={17}/> MEMBERSHIP CHECKOUT <span className="secure-label"><ShieldCheck size={12}/> SECURE</span></div>{session?<div className="linkedprofile"><span className="connecteddot">✓</span><span>Discord connected: <b>{session.user.user_metadata?.global_name||session.user.user_metadata?.full_name||session.user.email||'Account linked'}</b></span></div>:<div className="discord-login-wrap"><button className="discordwide" onClick={login}><span className="discordicon"><LogIn size={17}/></span><span><b>Continue with Discord</b><small>Secure sign-in · one click to connect</small></span><ArrowUpRight size={16}/></button><div className="securehint"><Shield size={13}/> Your Discord account is only used to link your membership.</div></div>}<img className="qr" src="/gpay-qr.png" alt="Diwali Network GPay QR"/><strong>Scan & pay with any UPI app</strong><p className="payment-copy">Pay <b>₹{(((couponQuote?.amount_paise)??(plans.find(p=>p.id===planId)?.price_paise??5000))/100).toFixed(2)}</b> to Diwali Network. Apply an available coupon before submitting your UTR.</p>{couponQuote&&<div className="coupon-summary"><span>Plan price <b>₹{(couponQuote.original_amount_paise/100).toFixed(2)}</b></span><span>Promo discount <b>−₹{(couponQuote.discount_paise/100).toFixed(2)}</b></span><strong>Final payable <b>₹{(couponQuote.amount_paise/100).toFixed(2)}</b></strong></div>}<div className="field"><label>MINECRAFT EDITION</label><div className="edition-picker" role="group" aria-label="Minecraft edition"><button type="button" className={`edition-option java-option ${edition==='java'?'selected':''}`} onClick={()=>setEdition('java')}><Monitor size={18}/><span className="edition-option-copy"><strong>Java Edition</strong><small>PC</small></span></button><button type="button" className={`edition-option bedrock-option ${edition==='bedrock'?'selected':''}`} onClick={()=>setEdition('bedrock')}><span className="bedrock-device-icons"><Smartphone size={17}/><Gamepad2 size={17}/></span><span className="edition-option-copy"><strong>Bedrock Edition</strong><small>Mobile · Console · Windows</small></span></button></div></div><div className="field"><label>MINECRAFT USERNAME</label><input value={mc} onChange={e=>setMc(e.target.value)} placeholder="Your exact in-game name" maxLength={16}/></div><div className="field"><label>PROMO CODE (OPTIONAL)</label><div className="coupon-input"><input value={coupon} onChange={e=>{setCoupon(e.target.value.toUpperCase());setCouponQuote(null);}} placeholder="e.g. DIWALI10" maxLength={24}/><button type="button" className="secondary" disabled={busy||!coupon} onClick={validateCoupon}>Apply</button></div></div><div className="field"><label>UPI UTR / TRANSACTION ID</label><input value={utr} onChange={e=>setUtr(e.target.value)} placeholder="12-digit reference / UTR" maxLength={40}/></div><button className="primary full submitbtn" disabled={!session||busy} onClick={submit}>{busy?<span className="spinner"/>:<Send size={16}/>} {busy?"Submitting your request…":"Submit payment for verification"}</button>{!session&&<small className="form-footnote"><Shield size={13}/> Sign in with Discord to securely submit your payment reference.</small>}</article></div>
      <article className="redeem-card card"><div className="cardlabel"><Sparkles size={16}/> HAVE A GIFT CODE?</div><h3>Redeem your membership</h3><p>Got a Diwali Network gift code? Sign in, enter your Minecraft username and redeem it here.</p><div className="redeem-edition"><label>MINECRAFT EDITION</label><div className="edition-picker" role="group" aria-label="Gift redemption Minecraft edition"><button type="button" className={`edition-option java-option ${redeemEdition==='java'?'selected':''}`} onClick={()=>setRedeemEdition('java')}><Monitor size={18}/><span className="edition-option-copy"><strong>Java Edition</strong><small>PC</small></span></button><button type="button" className={`edition-option bedrock-option ${redeemEdition==='bedrock'?'selected':''}`} onClick={()=>setRedeemEdition('bedrock')}><span className="bedrock-device-icons"><Smartphone size={17}/><Gamepad2 size={17}/></span><span className="edition-option-copy"><strong>Bedrock Edition</strong><small>Mobile · Console · Windows</small></span></button></div></div><div className="redeem-fields"><input value={redeemCode} onChange={e=>setRedeemCode(e.target.value.toUpperCase())} placeholder="DN-XXXXXXXXXXXX"/><input value={redeemMc} onChange={e=>setRedeemMc(e.target.value)} placeholder="Minecraft username" maxLength={16}/><button className="primary" disabled={!session||busy||!redeemCode||!redeemMc} onClick={redeem}>Redeem code <ArrowUpRight size={15}/></button></div>{!session&&<small className="form-footnote">Connect Discord before redeeming.</small>}</article>
      <div className="steps"><div><b>01</b><span>Connect Discord</span></div><div><b>02</b><span>Pay & submit UTR</span></div><div><b>03</b><span>Admin verifies payment</span></div><div><b>04</b><span>Whitelist activated</span></div></div>
      {message&&<div className="message" role="status"><span className="message-icon"><AlertCircle size={17}/></span><span>{message}</span></div>}
    </section>
    {adminMe?.authenticated&&adminMe?.active&&<section className="admin" id="admin-portal"><details open><summary>Diwali Network Admin Dashboard · {adminMe.is_owner?'Owner':adminMe.role}</summary><p>Discord verified admin session. Every action is checked by the Worker using your Discord account permissions.</p>
      {(adminMe.is_owner||adminMe.permissions?.includes('manage_admins'))&&<details className="admin-tools admin-accordion"><summary>Admin access management</summary><div className="admin-tools-body"><div className="admin-row"><label>Discord User ID<input value={adminDiscordId} onChange={e=>setAdminDiscordId(e.target.value)} placeholder="17–20 digit Discord User ID" inputMode="numeric" disabled={!!editingAdmin}/></label><label>Role preset<select value={adminRole} onChange={e=>{setAdminRole(e.target.value);setAdminPermissions(presets[e.target.value]||[]);}}><option value="custom">Custom permissions</option><option value="admin">Admin</option><option value="moderator">Moderator</option><option value="support">Support</option><option value="payment_manager">Payment Manager</option><option value="membership_manager">Membership Manager</option><option value="coupon_manager">Coupon Manager</option></select></label><button className="primary" onClick={addAdmin} disabled={busy||(!editingAdmin&&!/^\d{17,20}$/.test(adminDiscordId))}>{editingAdmin?'Save permissions':'Add admin'}</button>{editingAdmin&&<button className="secondary" onClick={()=>{setEditingAdmin(null);setAdminDiscordId('');setAdminPermissions([]);}}>Cancel edit</button>}</div><div className="permission-grid">{permissionList.map(([key,label])=><label className="permission-item" key={key}><input type="checkbox" checked={adminPermissions.includes(key)} onChange={e=>setAdminPermissions(old=>e.target.checked?[...old,key]:old.filter(x=>x!==key))}/><span>{label}</span></label>)}</div><button className="secondary" onClick={loadAdmins}>Refresh admin list</button>{admins.map(a=><div className="pending admin-member" key={a.discord_id}><div><b>{a.discord_id}</b><small>{a.role} · {a.active?'Active':'Disabled'} · {(a.permissions||[]).length} permissions</small></div><button className="secondary" onClick={()=>{setEditingAdmin(a.discord_id);setAdminDiscordId(a.discord_id);setAdminRole(a.role);setAdminPermissions(a.permissions||[]);}}>Edit permissions</button><button className="secondary" onClick={()=>updateAdmin(a.discord_id,{active:!a.active})}>{a.active?'Disable':'Enable'}</button><button className="reject" onClick={()=>removeAdmin(a.discord_id)}>Remove</button></div>)}</div></details>}
      {(adminMe.is_owner||adminMe.permissions?.includes('view_members'))&&<details className="admin-tools admin-accordion"><summary>Member management</summary><div className="admin-tools-body"><button className="secondary" onClick={loadMembers}>Load members</button>{members.map(m=>{
        const eligibleMemberships=(m.memberships||[]).filter((x:any)=>x.status==='active'||x.status==='expired');
        const selectedMembership=eligibleMemberships.find((x:any)=>x.id===extendTarget);
        const panelOpen=!!selectedMembership;
        return <div className="pending member-card" key={m.id}>
          <div className="member-main">
            <b>{m.minecraft_username} <span className={`member-edition-tag ${String(m.edition||'java').toLowerCase()==='bedrock'?'bedrock':''}`}>{String(m.edition||'java').toUpperCase()}</span></b>
            <small>Discord {m.discord_id} · {(m.memberships||[]).map((x:any)=>`${x.status} until ${new Date(x.expires_at).toLocaleString('en-IN',{timeZone:'Asia/Kolkata'})} IST`).join(' · ')||'No membership'}</small>
          </div>
          {(adminMe.is_owner||adminMe.permissions?.includes('manage_memberships'))&&<>
            <div className="member-actions">
              {eligibleMemberships.length>0&&<button type="button" className="member-extend-btn" onClick={()=>{
                setExtendTarget(panelOpen?null:eligibleMemberships[0].id);
                setExtendMode('days');setExtendDays('30');setExtendDateTime('');
              }}><span className="add-days-plus">+</span> Add days</button>}
              {eligibleMemberships.filter((x:any)=>x.status==='active').map((x:any)=><button type="button" className="reject" key={x.id} onClick={()=>setMembership(x.id,'expired')}>Expire</button>)}
              <button type="button" className="member-delete-btn" onClick={()=>deleteMember(m)}>Delete</button>
            </div>
            {panelOpen&&<div className="member-extend-panel">
              <div className="extend-tabs"><button type="button" className={extendMode==='days'?'active':''} onClick={()=>setExtendMode('days')}>Add days</button><button type="button" className={extendMode==='date'?'active':''} onClick={()=>setExtendMode('date')}>Set expiry</button></div>
              {extendMode==='days'?<label>Days to add<input type="number" min="1" max="3650" value={extendDays} onChange={e=>setExtendDays(e.target.value)}/></label>:<label>New expiry (IST)<input type="datetime-local" value={extendDateTime} onChange={e=>setExtendDateTime(e.target.value)}/></label>}
              <div className="extend-actions"><button type="button" className="member-extend-btn" onClick={()=>extendMembership(m,selectedMembership)} disabled={busy||!selectedMembership}>Save extension</button><button type="button" className="secondary" onClick={()=>setExtendTarget(null)}>Cancel</button></div>
            </div>}
          </>}
        </div>;
      })}</div></details>}
      {(adminMe.is_owner||adminMe.permissions?.includes('view_payments'))&&<details className="admin-tools admin-accordion"><summary>Payment review</summary><div className="admin-tools-body"><button className="secondary" onClick={loadPending} disabled={busy}>Load pending payments</button>{pending.map(p=><div className="pending" key={p.id}><div><b>{p.minecraft_username} <span className="edition-tag">{String(p.edition||'java').toUpperCase()}</span></b><small>UTR: {p.utr} · Discord: {p.discord_id} · ₹{(p.amount_paise/100).toFixed(2)}</small></div>{(adminMe.is_owner||adminMe.permissions?.includes('approve_payments'))&&<button onClick={()=>decide(p.id,'approve')}>Approve</button>}{(adminMe.is_owner||adminMe.permissions?.includes('reject_payments'))&&<button className="reject" onClick={()=>decide(p.id,'reject')}>Reject</button>}</div>)}</div></details>}
      {(adminMe.is_owner||adminMe.permissions?.includes('manage_coupons'))&&<details className="admin-tools admin-accordion"><summary>{editingCoupon?'Edit promotional coupon':'Create promotional coupon'}</summary><div className="admin-tools-body"><div className="admin-row"><label>Coupon code<input value={couponName} onChange={e=>setCouponName(e.target.value.toUpperCase())} placeholder="FRIEND20"/></label><label>Discount %<input type="number" min="1" max="100" value={couponValue} onChange={e=>setCouponValue(e.target.value)}/></label><label>Expiry date & time<input type="datetime-local" value={couponExpiry} onChange={e=>setCouponExpiry(e.target.value)}/></label><label>Maximum uses<input type="number" min="1" value={couponMaxUses} disabled={couponUnlimited} onChange={e=>setCouponMaxUses(e.target.value)}/></label><label className="check-label"><input type="checkbox" checked={couponUnlimited} onChange={e=>setCouponUnlimited(e.target.checked)}/> Unlimited usage</label><button className="secondary" onClick={createCoupon} disabled={busy||!couponName||(!couponUnlimited&&!couponMaxUses)}>{editingCoupon?'Save coupon':'Create coupon'}</button>{editingCoupon&&<button className="secondary" onClick={resetCouponForm}>Cancel</button>}</div><div className="coupon-toolbar"><h3>Coupon management</h3><button className="secondary" onClick={loadCoupons} disabled={busy}>Refresh coupon list</button></div>{coupons.map(c=><div className="coupon-row" key={c.id}><div><b>{c.code}</b><small>{c.discount_type==='percent'?`${c.discount_value}% off`:`₹${(c.discount_value/100).toFixed(2)} off`} · Created {new Date(c.created_at).toLocaleString()} · Expires {c.expires_at?new Date(c.expires_at).toLocaleString():'Never'} · Limit {c.max_uses===null?'Unlimited':c.max_uses} · Successful uses {c.uses}</small></div><span className={`coupon-status ${couponStatus(c).toLowerCase()}`}>{couponStatus(c)}</span><button className="secondary" onClick={()=>beginCouponEdit(c)}>Edit</button><button className="secondary" onClick={()=>couponAction(c.id,{active:!c.active},c.active?'Coupon disabled.':'Coupon enabled.')} disabled={busy}>{c.active?'Disable':'Enable'}</button><button className="secondary" onClick={()=>couponAction(c.id,{expires_now:true},'Coupon expired immediately.')} disabled={busy}>Expire now</button><button className="reject" onClick={()=>deleteCoupon(c.id)} disabled={busy||c.uses>0}>Delete</button></div>)}</div></details>}
      {(adminMe.is_owner||adminMe.permissions?.includes('create_gift_codes'))&&<details className="admin-tools admin-accordion"><summary>Generate free gift codes</summary><div className="admin-tools-body"><div className="admin-row"><label>Duration (days)<input type="number" min="1" max="3650" value={codeDays} onChange={e=>setCodeDays(e.target.value)}/></label><label>Quantity<input type="number" min="1" max="100" value={codeQty} onChange={e=>setCodeQty(e.target.value)}/></label><button className="primary" onClick={generateCodes} disabled={busy}>Generate codes</button></div>{generated.map(c=><div className="generated-code" key={c.id}><code>{c.code}</code><span>{c.duration_days} days</span><button onClick={()=>navigator.clipboard.writeText(c.code)}>Copy</button></div>)}</div></details>}
      {(adminMe.is_owner||adminMe.permissions?.includes('manage_plans'))&&<details className="admin-tools admin-accordion"><summary>Subscription plan settings</summary><div className="admin-tools-body"><button className="secondary" onClick={loadPlans}>Load plans</button>{editablePlans.map((p,i)=><div className="admin-row plan-admin-row" key={p.id}><label>{p.name}<input value={p.name} onChange={e=>setEditablePlans(old=>old.map((x,j)=>j===i?{...x,name:e.target.value}:x))}/></label><label>Duration days<input type="number" min="1" max="3650" value={p.duration_days} onChange={e=>setEditablePlans(old=>old.map((x,j)=>j===i?{...x,duration_days:Number(e.target.value)}:x))}/></label><label>Price ₹<input type="number" min="0" value={p.price_paise/100} onChange={e=>setEditablePlans(old=>old.map((x,j)=>j===i?{...x,price_rupees:e.target.value}:x))}/></label><button className="secondary" onClick={()=>savePlan({...p,price_rupees:p.price_rupees??p.price_paise/100})}>Save</button></div>)}</div></details>}
      {(adminMe.is_owner||adminMe.permissions?.includes('view_audit_logs'))&&<details className="admin-tools admin-accordion"><summary>Admin activity log</summary><div className="admin-tools-body"><button className="secondary" onClick={loadAudit}>Load audit logs</button>{auditLogs.map(log=><div className="pending" key={log.id}><div><b>{log.action}</b><small>By {log.actor_discord_id} · Target {log.target_discord_id||'—'} · {new Date(log.created_at).toLocaleString()}</small></div></div>)}</div></details>}
    </details></section>}
    <footer><span>© {new Date().getFullYear()} DIWALI NETWORK</span><span><Clock3 size={14}/> Flexible memberships · Gift codes</span></footer>
  </main>
}

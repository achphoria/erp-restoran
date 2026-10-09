import { useEffect, useRef, useState, type CSSProperties, type MouseEvent } from 'react';
import { MessageCircle, Sparkles, X } from 'lucide-react';
import { useAuth } from '../../context/AuthContext';
import SemarChat from './SemarChat';
import MiniAvatar from './MiniAvatar';
import WindowShow from './WindowShow';
import { CoffeeTable, DeskFronts, LOOKS, Mascot, OfficeBack, skyAt } from './art';
import { useOfficeSim, type Actor, type Status } from './useOfficeSim';
import { AGENTS, AREAS, H, W, type AgentId } from './world';
import './pendopo.css';

const DEF = Object.fromEntries(AGENTS.map((a) => [a.id, a])) as Record<AgentId, (typeof AGENTS)[number]>;
const STATUS: Record<Status, [string, string]> = {
  kerja: ['Kerja', 'ok'], siaga: ['Siaga', 'meet'], nongkrong: ['Nongkrong', 'rest'], nobar: ['Nobar', 'rest'],
  iseng: ['Iseng', 'rest'], istirahat: ['Istirahat', 'rest'], tidur: ['Tidur', 'sleep'], takut: ['Takut', 'off'],
};
// skala karakter sesuai kedalaman (makin ke depan makin besar)
const depth = (y: number) => 0.95 + 0.32 * Math.min(1, Math.max(0, (y - 400) / 300));
const pct = (v: number, of: number) => `${(v / of) * 100}%`;
const ZOOM = 1.9;

// Pendopo: kantor virtual para agent SEMAR. Yang bekerja hanya agent yang sedang diajak ngobrol.
export default function PendopoOffice() {
  const wrap = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(true);
  const [tabHidden, setTabHidden] = useState(document.hidden);
  const { sim, actors, t, clock } = useOfficeSim(!visible || tabHidden);
  const [selected, setSelected] = useState<AgentId | null>(null);
  const [chat, setChat] = useState(false);
  const { profile, hasModule } = useAuth();
  const owner = !!profile?.permissions.includes('*');
  const aiOn = hasModule('ai');
  const isOwner = owner && aiOn;
  const [area, setArea] = useState<{ label: string; desc: string; x: number; y: number } | null>(null);

  // semua menyapa saat Dashboard dibuka
  useEffect(() => {
    const id = window.setTimeout(() => sim.greet(), 900);
    // khusus mode pengembangan: window.__pendopo.chat('executed') untuk uji reaksi
    if (import.meta.env.DEV) (window as unknown as { __pendopo: unknown }).__pendopo = sim;
    return () => window.clearTimeout(id);
  }, [sim]);

  // jeda animasi saat tidak terlihat (hemat baterai)
  useEffect(() => {
    const el = wrap.current;
    if (!el || !('IntersectionObserver' in window)) return;
    const io = new IntersectionObserver(([e]) => setVisible(e.isIntersecting), { threshold: 0.05 });
    io.observe(el);
    const onVis = () => setTabHidden(document.hidden);
    document.addEventListener('visibilitychange', onVis);
    return () => { io.disconnect(); document.removeEventListener('visibilitychange', onVis); };
  }, []);

  // klik karakter: pilih + "colek"
  const pick = (id: AgentId) => { sim.poke(id); setSelected(id); };

  const sky = skyAt(clock.h);
  const shown = actors.slice().sort((p, q) => p.y - q.y);
  const sel = selected ? actors.find((a) => a.id === selected) ?? null : null;
  const semar = actors.find((a) => a.id === 'semar')!;

  // kamera ala The Sims: saat ngobrol, zoom mengikuti Semar (tidak sampai keluar tepi ruangan)
  const camera = (() => {
    if (!chat) return 'translate(0, 0) scale(1)';
    const fx = semar.x / W, fy = (semar.y - 70) / H;
    const lim = (ZOOM - 1) / 2;
    const tx = Math.max(-lim, Math.min(lim, ZOOM * (0.5 - fx))) * 100;
    const ty = Math.max(-lim, Math.min(lim, ZOOM * (0.5 - fy))) * 100;
    return `translate(${tx}%, ${ty}%) scale(${ZOOM})`;
  })();

  const onMove = (e: MouseEvent<HTMLDivElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    const x = ((e.clientX - r.left) / r.width) * W, y = ((e.clientY - r.top) / r.height) * H;
    const hit = AREAS.find((a) => x >= a.x0 && x <= a.x1 && y >= a.y0 && y <= a.y1);
    const box = wrap.current!.getBoundingClientRect();
    setArea(hit ? { label: hit.label, desc: hit.desc, x: e.clientX - box.left, y: e.clientY - box.top } : null);
  };

  const layer = (from: number, to: number) => shown.filter((a) => a.y > from && a.y <= to)
    .map((a) => <ActorSprite key={a.id} a={a} t={t} selected={a.id === selected} onPick={() => pick(a.id)} />);

  const working = actors.filter((a) => a.status === 'kerja').length;

  return (
    <section className="pd card">
      <div className="pd-head">
        <div>
          <div className="pd-title">Pendopo <span className="pd-sub">· kantor virtual agent SEMAR</span></div>
          <div className="muted small">Semar sudah aktif dan siap diajak ngobrol. Agent lain menunggu giliran sambil nongkrong.</div>
        </div>
        <div className="pd-meta">
          <span className="pd-clock">{String(clock.hour).padStart(2, '0')}.{String(clock.minute).padStart(2, '0')} <small>WIB</small></span>
          {isOwner
            ? <button type="button" className={`btn-sm ${chat ? '' : 'btn-primary'}`} onClick={() => setChat((c) => !c)}><MessageCircle size={14} /> {chat ? 'Tutup obrolan' : 'Tanya Semar'}</button>
            : <span className="pd-soon"><Sparkles size={13} /> {owner ? 'Semar AI belum diaktifkan (Pengaturan → Modul)' : 'Semar khusus owner'}</span>}
        </div>
      </div>

      <div className={`pd-body ${chat ? 'with-chat' : ''}`}>
        <div className="pd-main">
          <div ref={wrap} className={`pd-scene ${sky.night ? 'night' : ''} ${chat ? 'zoomed' : ''}`}>
            <div className="pd-zoom" style={{ transform: camera }} onMouseMove={onMove} onMouseLeave={() => setArea(null)}>
              <svg viewBox={`0 0 ${W} ${H}`} className="pd-svg" role="img" aria-label="Ilustrasi kantor Pendopo dengan lima agent">
                <OfficeBack hour={clock.hour} minute={clock.minute} />
                <WindowShow show={sim.show} t={t} />
                {/* urutan kedalaman: di belakang meja, meja, di depan meja, meja gaple, paling depan */}
                {layer(0, 540)}
                <DeskFronts />
                {layer(540, 690)}
                <CoffeeTable />
                {layer(690, 9999)}
                {/* gelap malam & cahaya lampu */}
                <rect x="0" y="0" width={W} height={H} fill="#0b1533" opacity={sky.dark} pointerEvents="none" />
                {sky.lamps && (
                  <g pointerEvents="none">
                    <defs>
                      <radialGradient id="pd-lamp"><stop offset="0" stopColor="#ffd77a" stopOpacity="0.55" /><stop offset="1" stopColor="#ffd77a" stopOpacity="0" /></radialGradient>
                      <radialGradient id="pd-teal"><stop offset="0" stopColor="#4ABDAC" stopOpacity="0.5" /><stop offset="1" stopColor="#4ABDAC" stopOpacity="0" /></radialGradient>
                    </defs>
                    {[[330, 120, 260], [980, 120, 260], [1180, 440, 150], [960, 640, 90], [700, 620, 160]].map(([x, y, r]) => <circle key={`${x}${y}`} cx={x} cy={y} r={r} fill="url(#pd-lamp)" />)}
                    {[[160, 420], [430, 420], [852, 420], [812, 428]].map(([x, y]) => <circle key={`${x}${y}`} cx={x} cy={y} r={70} fill="url(#pd-teal)" />)}
                  </g>
                )}
              </svg>

              {/* label nama, aktivitas & ucapan (HTML supaya tetap terbaca) */}
              {shown.map((a) => {
                const s = depth(a.y), lie = a.pose === 'lie';
                const head = (lie ? 50 : LOOKS[a.id].h + 18) * s;
                const lx = lie ? a.x - a.face * LOOKS[a.id].h * 0.75 * s : a.x;
                const speaking = !!a.speech && t < a.speechUntil;
                const showEmoji = !speaking && a.emoji && t < a.emojiUntil;
                return (
                  <div key={a.id} className={`pd-label ${a.id === selected ? 'on' : ''}`} style={{ left: pct(lx, W), top: pct(a.y - head, H), opacity: a.opacity }}
                    onClick={() => pick(a.id)}>
                    {speaking && <span key={a.speech} className="pd-say">{a.speech}</span>}
                    {showEmoji && <span className="pd-bubble">{a.emoji}</span>}
                    <span className="pd-name"><i className={`pd-dot ${STATUS[a.status][1]}`} />{DEF[a.id].name}</span>
                    <span className="pd-act">{a.label}</span>
                    {a.id === 'semar' && isOwner && !chat && (
                      <button type="button" className="pd-chat-btn" onClick={(e) => { e.stopPropagation(); setChat(true); }}><MessageCircle size={12} /> Tanya</button>
                    )}
                  </div>
                );
              })}

              {/* confetti saat usulan disetujui */}
              {t - sim.confettiAt < 2.2 && (
                <div className="pd-confetti" style={{ left: pct(semar.x, W), top: pct(semar.y - 175, H) }}>
                  {Array.from({ length: 44 }, (_, i) => (
                    <i key={`${sim.confettiAt}-${i}`} style={{
                      '--dx': `${Math.cos(i * 2.4) * (70 + (i % 6) * 34)}px`, '--dy': `${-90 - (i % 7) * 24}px`, '--rot': `${i * 47}deg`,
                      background: ['#F7B733', '#FC4A1A', '#4ABDAC', '#1F7F72', '#fff'][i % 5], animationDelay: `${(i % 4) * 0.04}s`,
                    } as CSSProperties} />
                  ))}
                </div>
              )}
            </div>

            {chat && <div className="pd-focus-tag">🎥 Fokus: Semar di meja kerja</div>}
            {area && !sel && <div className="pd-tip" style={{ left: area.x, top: area.y }}><b>{area.label}</b><span>{area.desc}</span></div>}

            {sel && (
              <div className="pd-card" role="dialog" aria-label={`Profil ${DEF[sel.id].name}`}>
                <button className="pd-close" onClick={() => setSelected(null)} aria-label="Tutup"><X size={16} /></button>
                <MiniAvatar id={sel.id} size={64} />
                <div>
                  <div className="pd-card-name" style={{ color: DEF[sel.id].tone }}>{DEF[sel.id].name}</div>
                  <div className="pd-card-role">{DEF[sel.id].role}</div>
                  <div className="muted small">“{DEF[sel.id].watak}”</div>
                  <div className="pd-card-now"><i className={`pd-dot ${STATUS[sel.status][1]}`} /> {STATUS[sel.status][0]} · {sel.label}</div>
                  {DEF[sel.id].ai
                    ? <button className="btn-sm btn-primary" disabled={!isOwner || chat} title={isOwner ? undefined : 'Khusus owner'} onClick={() => { setChat(true); setSelected(null); }}>
                        <MessageCircle size={14} /> {isOwner ? 'Ajak ngobrol' : 'Khusus owner'}</button>
                    : <button className="btn-sm" disabled title="Agent ini belum terhubung ke AI"><Sparkles size={14} /> AI segera hadir</button>}
                </div>
              </div>
            )}
          </div>

          {/* daftar tim */}
          <div className="pd-team-head">
            <b>Tim</b><span className="muted small">1/5 agent aktif AI · {working ? 'Semar sedang bekerja' : 'semua nongkrong dulu'}</span>
          </div>
          <div className="pd-team">
            {actors.map((a) => (
              <button key={a.id} type="button" className={`pd-member ${a.id === selected ? 'on' : ''}`} onClick={() => pick(a.id)}>
                <MiniAvatar id={a.id} size={44} />
                <span className="pd-member-text">
                  <b>{DEF[a.id].name} <span className={`pd-chip ${STATUS[a.status][1]}`}>{STATUS[a.status][0]}</span></b>
                  <small>{DEF[a.id].role} · {DEF[a.id].ai ? <span className="pd-ai on">AI aktif</span> : <span className="pd-ai">AI segera</span>}</small>
                  <small className="muted">{a.label}</small>
                </span>
              </button>
            ))}
          </div>
        </div>
        {chat && <SemarChat onClose={() => setChat(false)} onEvent={(e) => sim.chat(e)} />}
      </div>
    </section>
  );
}

function ActorSprite({ a, t, selected, onPick }: { a: Actor; t: number; selected: boolean; onPick: () => void }) {
  const s = depth(a.y);
  const waving = t < a.wave;
  const h = LOOKS[a.id].h;
  // gerakan sesaat
  const an = a.anim && t >= a.anim.start ? a.anim : null;
  const p = an ? Math.min(1, (t - an.start) / an.dur) : 0;
  let dx = 0, dy = 0, rot = 0, sx = 1, sy = 1;
  let arms: 'up' | 'chin' | null = null;
  switch (an?.type) {
    case 'jump': dy = -Math.sin(Math.PI * p) * 34; sy = 1 + 0.08 * Math.sin(Math.PI * p); break;
    case 'cheer': dy = -Math.abs(Math.sin(p * Math.PI * 3)) * 28; arms = 'up'; break;
    case 'spin': rot = 360 * p; dy = -Math.sin(Math.PI * p) * 18; break;
    case 'stretch': arms = 'up'; sy = 1 + 0.07 * Math.sin(Math.PI * p); break;
    case 'dance': rot = Math.sin(t * 9) * 10; dy = -Math.abs(Math.sin(t * 9)) * 8; break;
    case 'look': rot = Math.sin(p * Math.PI * 2) * 6; break;
    case 'nod': rot = Math.sin(p * Math.PI * 4) * 5; dy = Math.abs(Math.sin(p * Math.PI * 4)) * 2; break;
    case 'think': arms = 'chin'; rot = 4 + Math.sin(t * 2) * 2; break;
    case 'flex': arms = 'up'; sx = 1 + 0.06 * Math.abs(Math.sin(t * 10)); break;
    case 'yawn': sy = 1 + 0.06 * Math.sin(Math.PI * p); arms = p > 0.2 && p < 0.8 ? 'up' : null; break;
    case 'eat': dy = Math.abs(Math.sin(t * 14)) * 2; break;
    case 'scared': dx = Math.sin(t * 60) * 4; arms = 'up'; sy = 0.94; dy = -Math.abs(Math.sin(p * Math.PI * 2)) * 10; break;
    case 'slam': dy = Math.sin(Math.PI * p) * 6; rot = Math.sin(Math.PI * p) * 8; break;
  }
  const talking = !!a.speech && t < a.speechUntil;
  return (
    <g transform={`translate(${a.x + dx} ${a.y}) scale(${s * a.face} ${s})`} opacity={a.opacity} onClick={onPick} className="pd-actor">
      <ellipse cx="0" cy="2" rx={LOOKS[a.id].w * (a.pose === 'lie' ? 0.9 : 0.42)} ry="7" fill="rgba(40,20,5,0.25)" />
      {selected && <ellipse cx="0" cy="2" rx={LOOKS[a.id].w * 0.55} ry="10" fill="none" stroke="#F7B733" strokeWidth="4" />}
      <g transform={`translate(0 ${dy}) rotate(${rot} 0 ${-h * 0.45}) scale(${sx} ${sy})`}>
        <Mascot id={a.id} pose={a.pose} face={1} t={t + a.x * 0.01} walk={a.path.length ? a.walk || 0.01 : 0}
          typing={a.typing && !an} blink={t < a.blinkUntil || a.status === 'tidur'} wave={waving} holding={a.holding}
          arms={arms} talking={talking} />
        {an?.type === 'eat' && <text x={LOOKS[a.id].w * 0.32} y={-h * 0.5} fontSize="20">🍌</text>}
        {an?.type === 'spin' && <text x={-14} y={-h - 18} fontSize="20">😵</text>}
        {an?.type === 'slam' && <rect x={LOOKS[a.id].w * 0.3} y={-h * 0.42} width="12" height="16" rx="2" fill="#fff" stroke="#c0392b" strokeWidth="1.5" />}
        {an?.type === 'scared' && <text x={-12} y={-h - 16} fontSize="22">😱</text>}
      </g>
    </g>
  );
}

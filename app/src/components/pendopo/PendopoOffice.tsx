import { useEffect, useRef, useState, type MouseEvent } from 'react';
import { MessageCircle, Sparkles, X } from 'lucide-react';
import { CoffeeTable, DeskFronts, LOOKS, Mascot, OfficeBack, skyAt } from './art';
import { useOfficeSim, type Actor, type Status } from './useOfficeSim';
import { AGENTS, AREAS, H, W, type AgentId } from './world';
import './pendopo.css';

const DEF = Object.fromEntries(AGENTS.map((a) => [a.id, a])) as Record<AgentId, (typeof AGENTS)[number]>;
const STATUS: Record<Status, [string, string]> = {
  kerja: ['Kerja', 'ok'], rapat: ['Rapat', 'meet'], istirahat: ['Istirahat', 'rest'], santai: ['Santai', 'rest'],
  tidur: ['Tidur', 'sleep'], ronda: ['Ronda', 'meet'], pulang: ['Pulang', 'off'], lembur: ['Lembur', 'ok'],
};
// skala karakter sesuai kedalaman (makin ke depan makin besar)
const depth = (y: number) => 0.95 + 0.32 * Math.min(1, Math.max(0, (y - 400) / 300));
const pct = (v: number, of: number) => `${(v / of) * 100}%`;

// Pendopo: kantor virtual para agent SEMAR (tampilan dulu, belum terhubung ke AI)
export default function PendopoOffice() {
  const wrap = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(true);
  const [tabHidden, setTabHidden] = useState(document.hidden);
  const { actors, t, clock } = useOfficeSim(!visible || tabHidden);
  const [selected, setSelected] = useState<AgentId | null>(null);
  const [area, setArea] = useState<{ label: string; desc: string; x: number; y: number } | null>(null);

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

  const sky = skyAt(clock.h);
  const shown = actors.filter((a) => !a.gone).slice().sort((p, q) => p.y - q.y);
  const sel = selected ? actors.find((a) => a.id === selected) ?? null : null;

  const onMove = (e: MouseEvent<HTMLDivElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    const x = ((e.clientX - r.left) / r.width) * W, y = ((e.clientY - r.top) / r.height) * H;
    const hit = AREAS.find((a) => x >= a.x0 && x <= a.x1 && y >= a.y0 && y <= a.y1);
    setArea(hit ? { label: hit.label, desc: hit.desc, x: e.clientX - r.left, y: e.clientY - r.top } : null);
  };

  const layer = (from: number, to: number) => shown.filter((a) => a.y > from && a.y <= to)
    .map((a) => <ActorSprite key={a.id} a={a} t={t} selected={a.id === selected} onPick={() => setSelected(a.id === selected ? null : a.id)} />);

  const working = actors.filter((a) => ['kerja', 'rapat', 'lembur', 'ronda'].includes(a.status)).length;
  const present = actors.filter((a) => !a.gone).length;

  return (
    <section className="pd card">
      <div className="pd-head">
        <div>
          <div className="pd-title">Pendopo <span className="pd-sub">· kantor virtual agent SEMAR</span></div>
          <div className="muted small">Lima abdi bekerja untuk usaha Anda. Klik karakter untuk melihat perannya.</div>
        </div>
        <div className="pd-meta">
          <span className="pd-clock">{String(clock.hour).padStart(2, '0')}.{String(clock.minute).padStart(2, '0')} <small>WIB</small></span>
          <span className="pd-soon"><Sparkles size={13} /> AI segera hadir</span>
        </div>
      </div>

      <div ref={wrap} className={`pd-scene ${sky.night ? 'night' : ''}`} onMouseMove={onMove} onMouseLeave={() => setArea(null)}>
        <svg viewBox={`0 0 ${W} ${H}`} className="pd-svg" role="img" aria-label="Ilustrasi kantor Pendopo dengan lima agent">
          <OfficeBack hour={clock.hour} minute={clock.minute} />
          {/* urutan kedalaman: di belakang meja, meja, di depan meja, meja kopi, paling depan */}
          {layer(0, 540)}
          <DeskFronts />
          {layer(540, 690)}
          <CoffeeTable />
          {layer(690, 9999)}
          {/* gelap malam & cahaya lampu */}
          <rect x="0" y="0" width={W} height={H} fill="#0b1533" opacity={sky.dark} pointerEvents="none" />
          {sky.lamps && (
            <g pointerEvents="none" className="pd-lights">
              <defs>
                <radialGradient id="pd-lamp"><stop offset="0" stopColor="#ffd77a" stopOpacity="0.55" /><stop offset="1" stopColor="#ffd77a" stopOpacity="0" /></radialGradient>
                <radialGradient id="pd-teal"><stop offset="0" stopColor="#4ABDAC" stopOpacity="0.5" /><stop offset="1" stopColor="#4ABDAC" stopOpacity="0" /></radialGradient>
              </defs>
              {[[330, 120, 260], [980, 120, 260], [1180, 440, 150], [960, 640, 90]].map(([x, y, r]) => <circle key={`${x}${y}`} cx={x} cy={y} r={r} fill="url(#pd-lamp)" />)}
              {[[160, 420], [430, 420], [852, 420], [812, 428]].map(([x, y]) => <circle key={`${x}${y}`} cx={x} cy={y} r={70} fill="url(#pd-teal)" />)}
            </g>
          )}
        </svg>

        {/* label nama & aktivitas (HTML supaya tetap terbaca di HP) */}
        {shown.map((a) => {
          const s = depth(a.y), lie = a.pose === 'lie';
          const head = (lie ? 50 : LOOKS[a.id].h + 18) * s;
          // berbaring: kepala ada di sisi berlawanan arah hadap
          const lx = lie ? a.x - a.face * LOOKS[a.id].h * 0.75 * s : a.x;
          const showEmoji = a.emoji && t < a.emojiUntil;
          return (
            <div key={a.id} className={`pd-label ${a.id === selected ? 'on' : ''}`} style={{ left: pct(lx, W), top: pct(a.y - head, H), opacity: a.opacity }}
              onClick={() => setSelected(a.id === selected ? null : a.id)}>
              {showEmoji && <span className="pd-bubble">{a.emoji}</span>}
              <span className="pd-name"><i className={`pd-dot ${STATUS[a.status][1]}`} />{DEF[a.id].name}</span>
              <span className="pd-act">{a.label}</span>
            </div>
          );
        })}

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
              <button className="btn-sm" disabled title="Agent AI belum aktif"><MessageCircle size={14} /> Ajak ngobrol (segera hadir)</button>
            </div>
          </div>
        )}
      </div>

      {/* daftar tim */}
      <div className="pd-team-head">
        <b>Tim</b><span className="muted small">{present}/5 di kantor · {working} sedang bekerja</span>
      </div>
      <div className="pd-team">
        {actors.map((a) => (
          <button key={a.id} type="button" className={`pd-member ${a.id === selected ? 'on' : ''}`} onClick={() => setSelected(a.id === selected ? null : a.id)}>
            <MiniAvatar id={a.id} size={44} />
            <span className="pd-member-text">
              <b>{DEF[a.id].name} <span className={`pd-chip ${STATUS[a.status][1]}`}>{STATUS[a.status][0]}</span></b>
              <small>{DEF[a.id].role}</small>
              <small className="muted">{a.label}</small>
            </span>
          </button>
        ))}
      </div>
    </section>
  );
}

function ActorSprite({ a, t, selected, onPick }: { a: Actor; t: number; selected: boolean; onPick: () => void }) {
  const s = depth(a.y);
  const waving = t < a.wave;
  return (
    <g transform={`translate(${a.x} ${a.y}) scale(${s * a.face} ${s})`} opacity={a.opacity} onClick={onPick} className="pd-actor">
      <ellipse cx="0" cy="2" rx={LOOKS[a.id].w * (a.pose === 'lie' ? 0.9 : 0.42)} ry="7" fill="rgba(40,20,5,0.25)" />
      {selected && <ellipse cx="0" cy="2" rx={LOOKS[a.id].w * 0.55} ry="10" fill="none" stroke="#F7B733" strokeWidth="4" />}
      {/* wajah tetap menghadap kanan di dalam sprite; arah diatur oleh scale(face) */}
      <Mascot id={a.id} pose={a.pose} face={1} t={t + a.x * 0.01} walk={a.path.length ? a.walk || 0.01 : 0}
        typing={a.typing} blink={t < a.blinkUntil || a.status === 'tidur'} wave={waving} holding={a.holding} />
    </g>
  );
}

// avatar kecil: kepala & badan karakter
export function MiniAvatar({ id, size }: { id: AgentId; size: number }) {
  const L = LOOKS[id];
  const top = -L.h - 34;
  return (
    <svg width={size} height={size} viewBox={`${-L.w * 0.7} ${top} ${L.w * 1.4} ${L.w * 1.4}`} className="pd-avatar" style={{ background: `${DEF[id].tone}1a` }}>
      <Mascot id={id} pose="stand" face={1} t={0} walk={0} />
    </svg>
  );
}

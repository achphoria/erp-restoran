import type { Show } from './useOfficeSim';

// Tontonan di jendela krepyak (area kaca x 56-220, y 82-250).
// Siang: Ultraman vs Godzilla berantem di kejauhan. Malam: pocong mengintip sambil melompat.
const CLIP = 'pd-window-clip';
const fade = (p: number, edge = 0.06) => Math.min(1, p / edge, (1 - p) / edge);

export default function WindowShow({ show, t }: { show: Show | null; t: number }) {
  if (!show) return null;
  const p = Math.min(1, Math.max(0, (t - show.start) / show.dur));
  if (p >= 1) return null;
  return (
    <g pointerEvents="none">
      <defs><clipPath id={CLIP}><rect x="56" y="82" width="164" height="168" /></clipPath></defs>
      <g clipPath={`url(#${CLIP})`} opacity={fade(p)}>
        {show.kind === 'kaiju' ? <Kaiju p={p} t={t - show.start} /> : <Pocong p={p} t={t - show.start} />}
      </g>
      {/* kusen jendela tetap di depan */}
      <path d="M138 82V250M56 166H220" stroke="#4e2f17" strokeWidth="6" />
    </g>
  );
}

function Kaiju({ p, t }: { p: number; t: number }) {
  const cyc = t % 6;
  const ultraBeam = cyc > 1.2 && cyc < 2.1;      // sinar spesium
  const godBeam = cyc > 3.6 && cyc < 4.4;        // napas atom
  const hitGod = ultraBeam && cyc > 1.5, hitUltra = godBeam && cyc > 3.9;
  const rise = Math.min(1, t / 1.2);             // Godzilla muncul dari bawah, Ultraman terbang masuk
  const gx = 96 + Math.sin(t * 2.3) * 3 + (cyc > 4.6 && cyc < 5.4 ? 10 : 0);
  const ux = 184 + Math.sin(t * 2.9 + 1) * 3 - (cyc > 0.2 && cyc < 0.9 ? 12 : 0);
  const uy = 232 - (1 - rise) * 120;
  const timerRed = p > 0.65 && Math.floor(t * 4) % 2 === 0;
  const collapse = Math.max(0, Math.min(1, (p - 0.45) * 4));
  return (
    <g>
      {/* kota di kejauhan */}
      <g fill="#9aa7b8" opacity="0.85">
        <rect x="60" y="200" width="16" height="32" /><rect x="80" y="190" width="12" height="42" />
        <rect x="200" y="196" width="18" height="36" />
        <rect x="150" y="206" width="14" height="26" transform={`rotate(${collapse * 38} 164 232)`} />
      </g>
      <g fill="#c9d3df">{[[64, 206], [70, 216], [84, 198], [84, 210], [206, 204], [212, 216]].map(([x, y]) => <rect key={`${x}${y}`} x={x} y={y} width="3" height="4" />)}</g>
      {/* Godzilla */}
      <g transform={`translate(${gx} ${232 + (1 - rise) * 70})`}>
        <path d="M-14 -4Q-34 -2 -42 4Q-26 0 -12 0Z" fill="#2f4f3a" />
        <path d="M-16 0Q-20 -30 -6 -44Q2 -50 10 -44Q16 -30 12 0Z" fill="#2f4f3a" />
        <path d="M-12 -30L-18 -36L-10 -36L-14 -44L-6 -41L-6 -50L0 -45" fill="#4b6f53" />
        <ellipse cx="13" cy="-47" rx="9" ry="6" fill="#2f4f3a" />
        <circle cx="17" cy="-49" r="1.6" fill="#ff5a3c" />
        <path d="M8 -30L18 -24" stroke="#2f4f3a" strokeWidth="4" strokeLinecap="round" />
        <rect x="-10" y="-4" width="7" height="6" fill="#2f4f3a" /><rect x="3" y="-4" width="7" height="6" fill="#2f4f3a" />
        {godBeam && <line x1="22" y1="-46" x2={ux - gx - 6} y2={uy - 232 - 30} stroke="#7fd3ff" strokeWidth="4" strokeLinecap="round" opacity="0.95" />}
        {godBeam && <line x1="22" y1="-46" x2={ux - gx - 6} y2={uy - 232 - 30} stroke="#e8f8ff" strokeWidth="1.5" strokeLinecap="round" />}
      </g>
      {/* Ultraman */}
      <g transform={`translate(${ux} ${uy})`}>
        <rect x="-5" y="-14" width="4" height="14" rx="2" fill="#d8dde3" /><rect x="1" y="-14" width="4" height="14" rx="2" fill="#d8dde3" />
        <path d="M-8 -36Q-9 -18 -5 -12H5Q9 -18 8 -36Q0 -40 -8 -36Z" fill="#d8dde3" />
        <path d="M-8 -30Q-2 -24 -5 -12H-1Q-2 -22 -6 -32ZM8 -30Q2 -24 5 -12H1Q2 -22 6 -32Z" fill="#c0392b" />
        <circle cx="0" cy="-29" r="2.6" fill={timerRed ? '#ff3b3b' : '#5fc8ff'} />
        <ellipse cx="0" cy="-42" rx="5.5" ry="6.5" fill="#d8dde3" />
        <path d="M0 -49V-36" stroke="#c0392b" strokeWidth="1.6" />
        <ellipse cx="-2.2" cy="-43" rx="1.6" ry="1" fill="#ffe680" /><ellipse cx="2.2" cy="-43" rx="1.6" ry="1" fill="#ffe680" />
        {ultraBeam
          ? <g><path d="M-14 -38L-4 -28M-14 -28L-4 -38" stroke="#d8dde3" strokeWidth="3" strokeLinecap="round" />
              <line x1="-9" y1="-33" x2={gx - ux + 16} y2="-40" stroke="#fff6b0" strokeWidth="3.5" strokeLinecap="round" />
              <line x1="-9" y1="-33" x2={gx - ux + 16} y2="-40" stroke="#ffffff" strokeWidth="1.2" /></g>
          : <path d="M-8 -34L-14 -26M8 -34L14 -40" stroke="#d8dde3" strokeWidth="3" strokeLinecap="round" />}
      </g>
      {/* ledakan saat kena */}
      {hitGod && <Boom x={gx + 8} y={192} t={t} />}
      {hitUltra && <Boom x={ux} y={uy - 32} t={t} />}
      {/* debu saat bergulat */}
      {cyc > 4.6 && cyc < 5.6 && <g fill="#c9b79a" opacity="0.7">{[0, 1, 2].map((i) => <circle key={i} cx={130 + i * 14} cy={230 - ((t * 20 + i * 5) % 12)} r={5 + i} />)}</g>}
    </g>
  );
}

function Boom({ x, y, t }: { x: number; y: number; t: number }) {
  const k = 1 + Math.sin(t * 30) * 0.15;
  return (
    <g transform={`translate(${x} ${y}) scale(${k})`}>
      <circle r="10" fill="#FC4A1A" opacity="0.8" /><circle r="6" fill="#F7B733" /><circle r="2.5" fill="#fff" />
    </g>
  );
}

function Pocong({ p, t }: { p: number; t: number }) {
  // masuk dari kanan, melompat-lompat di jendela, lalu keluar lagi
  const enter = Math.min(1, Math.max(0, (p - 0.04) / 0.18));
  const exit = Math.min(1, Math.max(0, (p - 0.78) / 0.18));
  const x = 236 - enter * 62 + exit * 62 + Math.sin(t * 1.3) * 6;
  const hop = Math.abs(Math.sin(t * 7)) * 7;
  const tilt = Math.sin(t * 7) * 4;
  return (
    <g>
      <rect x="56" y="82" width="164" height="168" fill="#0d2a1f" opacity={0.25 + Math.sin(t * 9) * 0.05} />
      <g transform={`translate(${x} ${246 - hop}) rotate(${tilt})`}>
        <path d="M-14 0Q-17 -40 -11 -60Q0 -70 11 -60Q17 -40 14 0Z" fill="#f2efe6" stroke="#cfc8b5" strokeWidth="1.5" />
        <path d="M-3 -66L0 -74L3 -66M-12 -52Q0 -48 12 -52M-13 -12Q0 -8 13 -12" stroke="#b8b09a" strokeWidth="1.6" fill="none" />
        <path d="M-2 2L0 10L2 2" stroke="#b8b09a" strokeWidth="1.6" fill="none" />
        <ellipse cx="0" cy="-42" rx="7.5" ry="8.5" fill="#c8d6b4" />
        <circle cx="-3" cy="-44" r="2.4" fill="#111" /><circle cx="3" cy="-44" r="2.4" fill="#111" />
        <circle cx="-3" cy="-44" r="0.8" fill="#ff3b3b" /><circle cx="3" cy="-44" r="0.8" fill="#ff3b3b" />
        <ellipse cx="0" cy="-37" rx="2" ry="1.4" fill="#3a2a2a" />
      </g>
    </g>
  );
}

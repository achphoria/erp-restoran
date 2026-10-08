import { memo, type ReactElement } from 'react';
import type { AgentId, Pose } from './world';

// ---------------------------------------------------------------------------------------------
// Langit & cahaya mengikuti jam WIB
// ---------------------------------------------------------------------------------------------
const hex = (c: string) => [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
const mix = (a: string, b: string, t: number) => {
  const [x, y] = [hex(a), hex(b)];
  return `rgb(${x.map((v, i) => Math.round(v + (y[i] - v) * t)).join(',')})`;
};
const KEYS: [number, string, string, number][] = [   // jam, langit atas, langit bawah, gelap ruangan
  [0, '#0b1533', '#1d2b55', 0.5], [4.5, '#0b1533', '#1d2b55', 0.5], [5.8, '#f4a76b', '#ffd9a0', 0.22],
  [7, '#7ec4ef', '#cfeaf8', 0], [16.3, '#7ec4ef', '#cfeaf8', 0], [17.6, '#f08a5d', '#ffcf8a', 0.14],
  [18.8, '#1a2350', '#3b3570', 0.42], [24, '#0b1533', '#1d2b55', 0.5],
];
export function skyAt(h: number) {
  const i = KEYS.findIndex((k, n) => n < KEYS.length - 1 && h >= k[0] && h < KEYS[n + 1][0]);
  const [h0, t0, b0, d0] = KEYS[i];
  const [h1, t1, b1, d1] = KEYS[i + 1];
  const t = (h - h0) / (h1 - h0);
  return { top: mix(t0, t1, t), bottom: mix(b0, b1, t), dark: d0 + (d1 - d0) * t, night: h < 5.6 || h >= 18.4, lamps: h < 6.6 || h >= 17.4 };
}

// ---------------------------------------------------------------------------------------------
// Latar kantor (statis; animasi kecil lewat CSS)
// ---------------------------------------------------------------------------------------------
const WOOD = '#6b4423', WOOD_D = '#4e2f17', WOOD_L = '#8a5a30';

export const OfficeBack = memo(function OfficeBack({ hour, minute }: { hour: number; minute: number }) {
  const h = hour + minute / 60;
  const sky = skyAt(h);
  const sunT = (h - 6) / 12;
  const hourDeg = (hour % 12) * 30 + minute * 0.5, minDeg = minute * 6;
  return (
    <g>
      <defs>
        {/* anyaman bilik bambu */}
        <pattern id="pd-bilik" width="28" height="28" patternUnits="userSpaceOnUse">
          <rect width="28" height="28" fill="#d9b77e" />
          <rect x="0" y="0" width="14" height="14" fill="#cfa96c" />
          <rect x="14" y="14" width="14" height="14" fill="#cfa96c" />
          <path d="M0 3.5H14M0 7H14M0 10.5H14M14 17.5H28M14 21H28M14 24.5H28" stroke="#c09659" strokeWidth="1" />
          <path d="M17.5 0V14M21 0V14M24.5 0V14M3.5 14V28M7 14V28M10.5 14V28" stroke="#e3c48e" strokeWidth="1" />
        </pattern>
        <pattern id="pd-tikar" width="16" height="16" patternUnits="userSpaceOnUse">
          <rect width="16" height="16" fill="#d8c08a" />
          <path d="M0 8H16M8 0V16" stroke="#c4a76c" strokeWidth="2" />
          <rect x="0" y="0" width="8" height="8" fill="#ccb47c" />
        </pattern>
        <pattern id="pd-lurik-sarung" width="10" height="10" patternUnits="userSpaceOnUse">
          <rect width="10" height="10" fill="#7d5a3a" /><rect width="3" height="10" fill="#9b7550" />
        </pattern>
        <linearGradient id="pd-sky" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={sky.top} /><stop offset="1" stopColor={sky.bottom} />
        </linearGradient>
        <linearGradient id="pd-floor" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#8f6236" /><stop offset="1" stopColor="#b5834e" />
        </linearGradient>
        <linearGradient id="pd-wallshade" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="rgba(60,30,10,0.35)" /><stop offset="0.25" stopColor="rgba(60,30,10,0)" />
          <stop offset="0.85" stopColor="rgba(60,30,10,0)" /><stop offset="1" stopColor="rgba(60,30,10,0.3)" />
        </linearGradient>
        <radialGradient id="pd-fire" cx="0.5" cy="0.8" r="0.6">
          <stop offset="0" stopColor="#fff2a8" /><stop offset="0.5" stopColor="#F7B733" /><stop offset="1" stopColor="#FC4A1A" stopOpacity="0" />
        </radialGradient>
      </defs>

      {/* dinding bilik & lantai papan */}
      <rect x="0" y="0" width="1280" height="392" fill="url(#pd-bilik)" />
      <rect x="0" y="0" width="1280" height="392" fill="url(#pd-wallshade)" />
      <rect x="0" y="390" width="1280" height="330" fill="url(#pd-floor)" />
      {[404, 422, 444, 470, 500, 534, 572, 614, 660, 710].map((y, i) => (
        <line key={y} x1="0" x2="1280" y1={y} y2={y} stroke="#7a522c" strokeWidth={1 + i * 0.25} opacity="0.55" />
      ))}
      {[[180, 404, 422], [610, 422, 444], [980, 444, 470], [320, 470, 500], [760, 500, 534], [1120, 534, 572], [90, 572, 614], [520, 614, 660], [900, 660, 710]].map(([x, a, b]) => (
        <line key={`${x}-${a}`} x1={x} x2={x} y1={a} y2={b} stroke="#7a522c" strokeWidth="1.5" opacity="0.5" />
      ))}
      <rect x="0" y="384" width="1280" height="12" fill={WOOD_D} />

      {/* balok atap & tiang saka */}
      <rect x="0" y="0" width="1280" height="34" fill={WOOD_D} />
      {Array.from({ length: 11 }, (_, i) => <rect key={i} x={i * 128 + 50} y="0" width="16" height="40" fill={WOOD} />)}
      <rect x="0" y="34" width="1280" height="8" fill={WOOD} />
      {[14, 1240].map((x) => <g key={x}><rect x={x} y="34" width="28" height="358" fill={WOOD} /><rect x={x + 4} y="34" width="6" height="358" fill={WOOD_L} opacity="0.6" /></g>)}

      {/* jendela krepyak dengan pemandangan langit */}
      <g>
        <rect x="44" y="70" width="188" height="192" rx="4" fill={WOOD_D} />
        <rect x="56" y="82" width="164" height="168" fill="url(#pd-sky)" />
        {!sky.night && sunT > 0 && sunT < 1 && <circle cx={64 + sunT * 148} cy={210 - Math.sin(sunT * Math.PI) * 108} r="14" fill="#ffe08a" />}
        {sky.night && <>
          <circle cx="180" cy="112" r="11" fill="#f3efd8" /><circle cx="186" cy="108" r="10" fill={sky.top} />
          {[[78, 100], [110, 128], [150, 96], [96, 160], [200, 150], [132, 180]].map(([x, y], i) => (
            <circle key={i} className="pd-twinkle" style={{ animationDelay: `${i * 0.7}s` }} cx={x} cy={y} r="1.6" fill="#fff" />
          ))}
        </>}
        <g className="pd-cloud" opacity={sky.night ? 0.25 : 0.9}>
          <ellipse cx="100" cy="128" rx="22" ry="8" fill="#fff" /><ellipse cx="116" cy="122" rx="14" ry="9" fill="#fff" />
        </g>
        {/* siluet pohon kelapa */}
        <path d="M196 250C196 220 192 196 186 172" stroke="#3d5a3a" strokeWidth="5" fill="none" />
        <path d="M186 172C170 166 158 170 150 178M186 172C198 160 212 160 220 166M186 172C178 156 168 150 158 150M186 172C196 158 206 150 216 150" stroke="#3d5a3a" strokeWidth="5" fill="none" strokeLinecap="round" />
        <rect x="56" y="232" width="164" height="18" fill="#5e8c4f" opacity="0.8" />
        <path d="M138 82V250M56 166H220" stroke={WOOD_D} strokeWidth="6" />
        {/* daun krepyak terbuka */}
        {[22, 232].map((x) => (
          <g key={x}>
            <rect x={x} y="74" width="22" height="184" fill={WOOD_L} stroke={WOOD_D} strokeWidth="2" />
            {Array.from({ length: 14 }, (_, i) => <line key={i} x1={x + 3} x2={x + 19} y1={84 + i * 12.5} y2={86 + i * 12.5} stroke={WOOD_D} strokeWidth="2" />)}
          </g>
        ))}
        <rect x="38" y="258" width="200" height="10" rx="3" fill={WOOD} />
      </g>

      {/* papan tulis kapur */}
      <g>
        <rect x="262" y="96" width="160" height="114" rx="4" fill={WOOD} />
        <rect x="270" y="104" width="144" height="98" fill="#2f4a3b" />
        <g stroke="#e8efe6" strokeWidth="1.6" fill="none" strokeLinecap="round" opacity="0.85">
          <path d="M280 118H332M280 132H318" />
          <path d="M282 186L300 170L316 178L338 152L356 160L376 134" />
          <path d="M370 132L377 133L375 140" />
          <path d="M360 118H402M360 126H392" opacity="0.6" />
          <circle cx="392" cy="176" r="12" /><path d="M392 176V164M392 176L401 183" />
        </g>
        <rect x="268" y="206" width="148" height="6" rx="2" fill={WOOD_D} />
        <rect x="300" y="203" width="12" height="4" fill="#f4f4f4" /><rect x="320" y="203" width="8" height="4" fill="#f7c9c9" />
      </g>

      {/* wayang gunungan hiasan dinding */}
      <g transform="translate(446 70)">
        <rect x="36" y="118" width="6" height="28" fill={WOOD_D} />
        <path d="M39 2C47 14 64 28 72 46C78 60 77 78 69 92H9C1 78 0 60 6 46C14 28 31 14 39 2Z" fill="#8b5a2b" stroke="#d9a441" strokeWidth="2" />
        <path d="M39 86V30M39 64C31 57 24 57 18 61M39 64C47 57 54 57 60 61M39 48C33 42 28 42 24 44M39 48C45 42 50 42 54 44" stroke="#f0c75e" strokeWidth="2.2" fill="none" strokeLinecap="round" />
        <path d="M31 92V80a8 8 0 0 1 16 0V92Z" fill="#d9a441" />
        <circle cx="39" cy="20" r="4" fill="#F7B733" />
        <rect x="14" y="92" width="50" height="6" rx="3" fill="#d9a441" />
      </g>

      {/* jam dinding bandul (jarum mengikuti jam asli) */}
      <g>
        <rect x="546" y="52" width="60" height="206" rx="10" fill={WOOD} />
        <path d="M546 66Q576 38 606 66" fill={WOOD_L} />
        <circle cx="576" cy="98" r="24" fill="#f6efdc" stroke="#d9a441" strokeWidth="3" />
        {Array.from({ length: 12 }, (_, i) => (
          <line key={i} x1="576" y1="78" x2="576" y2={i % 3 ? 81 : 83} stroke="#4e2f17" strokeWidth={i % 3 ? 1 : 2} transform={`rotate(${i * 30} 576 98)`} />
        ))}
        <line x1="576" y1="98" x2="576" y2="86" stroke="#2b1a0d" strokeWidth="3" strokeLinecap="round" transform={`rotate(${hourDeg} 576 98)`} />
        <line x1="576" y1="98" x2="576" y2="80" stroke="#2b1a0d" strokeWidth="2" strokeLinecap="round" transform={`rotate(${minDeg} 576 98)`} />
        <circle cx="576" cy="98" r="2.5" fill="#FC4A1A" />
        <rect x="556" y="132" width="40" height="112" rx="6" fill="#3a2414" opacity="0.85" />
        <g className="pd-pendulum">
          <line x1="576" y1="134" x2="576" y2="220" stroke="#d9a441" strokeWidth="2" />
          <circle cx="576" cy="224" r="10" fill="#e6b54a" stroke="#a8781f" strokeWidth="2" />
        </g>
      </g>

      {/* lawang gebyok (pintu kayu ukir) + kentongan */}
      <g>
        <rect x="640" y="140" width="122" height="246" fill={WOOD_D} />
        <path d="M640 140H762V170Q701 150 640 170Z" fill={WOOD_L} />
        <path d="M654 168Q701 148 748 168" stroke="#d9a441" strokeWidth="2" fill="none" />
        <rect x="654" y="176" width="46" height="204" fill={WOOD} stroke="#3a2414" strokeWidth="2" />
        <rect x="702" y="176" width="46" height="204" fill={WOOD} stroke="#3a2414" strokeWidth="2" />
        {[662, 710].map((x) => <g key={x}><rect x={x} y="190" width="30" height="70" rx="4" fill="none" stroke={WOOD_L} strokeWidth="3" /><rect x={x} y="276" width="30" height="88" rx="4" fill="none" stroke={WOOD_L} strokeWidth="3" /></g>)}
        <circle cx="696" cy="290" r="3.5" fill="#d9a441" /><circle cx="708" cy="290" r="3.5" fill="#d9a441" />
        <line x1="780" y1="150" x2="780" y2="176" stroke="#4e2f17" strokeWidth="2" />
        <rect x="772" y="176" width="16" height="64" rx="7" fill="#c8a25a" stroke="#8a6a2a" strokeWidth="2" />
        <rect x="777" y="196" width="6" height="22" rx="3" fill="#5a3a12" />
      </g>

      {/* lemari server kayu jati */}
      <g>
        <rect x="798" y="132" width="108" height="252" rx="6" fill={WOOD} />
        <rect x="808" y="144" width="88" height="226" rx="3" fill="#1d2433" />
        {[0, 1, 2, 3, 4].map((r) => (
          <g key={r}>
            <rect x="814" y={152 + r * 42} width="76" height="32" rx="3" fill="#2c3445" stroke="#3d4659" />
            {[0, 1, 2, 3].map((c) => (
              <circle key={c} className="pd-led" style={{ animationDelay: `${(r * 4 + c) * 0.37 % 2.4}s`, animationDuration: `${0.8 + ((r + c) % 3) * 0.5}s` }}
                cx={822 + c * 9} cy={168 + r * 42} r="2.6" fill={c === 3 ? '#F7B733' : '#4ade80'} />
            ))}
            <rect x="862" y={162 + r * 42} width="22" height="3" fill="#4ABDAC" opacity="0.6" />
            <rect x="862" y={169 + r * 42} width="16" height="3" fill="#4ABDAC" opacity="0.35" />
          </g>
        ))}
        <path d="M852 144V370" stroke={WOOD} strokeWidth="4" />
        <rect x="808" y="144" width="88" height="226" rx="3" fill="rgba(180,220,255,0.08)" />
        <circle cx="846" cy="258" r="3" fill="#d9a441" /><circle cx="858" cy="258" r="3" fill="#d9a441" />
      </g>

      {/* rak gudang: toples, kardus, karung beras */}
      <g>
        {[176, 246, 316].map((y) => <rect key={y} x="930" y={y} width="136" height="8" fill={WOOD} />)}
        <rect x="930" y="150" width="8" height="234" fill={WOOD_D} /><rect x="1058" y="150" width="8" height="234" fill={WOOD_D} />
        {[[944, '#f0d9a8'], [976, '#e8b04a'], [1008, '#d9e7c8'], [1036, '#f3c9a0']].map(([x, c]) => (
          <g key={x as number}><rect x={x as number} y="146" width="22" height="30" rx="5" fill={c as string} opacity="0.9" /><rect x={x as number} y="140" width="22" height="7" rx="2" fill="#b0453a" /></g>
        ))}
        <rect x="942" y="210" width="50" height="36" fill="#c99a62" stroke="#9c7140" strokeWidth="2" /><path d="M942 222H992" stroke="#9c7140" />
        <rect x="998" y="216" width="54" height="30" fill="#d3a873" stroke="#9c7140" strokeWidth="2" />
        <text x="1025" y="236" fontSize="10" textAnchor="middle" fill="#6b4423" fontWeight="700">MIE</text>
        <rect x="946" y="282" width="42" height="34" fill="#c99a62" stroke="#9c7140" strokeWidth="2" />
        <rect x="994" y="286" width="58" height="30" fill="#e2c69a" stroke="#9c7140" strokeWidth="2" />
        <text x="1023" y="305" fontSize="10" textAnchor="middle" fill="#6b4423" fontWeight="700">GULA</text>
        {[[944, 338], [1000, 344]].map(([x, y]) => (
          <g key={x}>
            <path d={`M${x} ${y + 50}V${y + 12}Q${x + 26} ${y - 6} ${x + 52} ${y + 12}V${y + 50}Z`} fill="#efe6cf" stroke="#c9b98f" strokeWidth="2" />
            <text x={x + 26} y={y + 36} fontSize="10" textAnchor="middle" fill="#2f6fb0" fontWeight="800">BERAS</text>
          </g>
        ))}
      </g>

      {/* pawon: rak piring bambu, tampah, tungku tanah liat, kuali, cerek */}
      <g>
        <rect x="1086" y="160" width="140" height="8" fill="#b89150" /><rect x="1086" y="214" width="140" height="8" fill="#b89150" />
        <rect x="1086" y="160" width="6" height="62" fill="#a07a3c" /><rect x="1220" y="160" width="6" height="62" fill="#a07a3c" />
        {[1100, 1122, 1144, 1166].map((x) => <ellipse key={x} cx={x} cy="190" rx="9" ry="22" fill="#f4f1e8" stroke="#2f6fb0" strokeWidth="2" />)}
        <rect x="1180" y="176" width="16" height="36" rx="3" fill="#e7c48c" /><rect x="1200" y="182" width="14" height="30" rx="3" fill="#cf6b4a" />
        <circle cx="1246" cy="118" r="22" fill="#d4b073" stroke="#a8843f" strokeWidth="3" />
        <circle cx="1246" cy="118" r="14" fill="none" stroke="#b8924f" strokeWidth="2" />
        {/* tungku */}
        <path d="M1104 470V392Q1104 372 1124 372H1236Q1256 372 1256 392V470Z" fill="#a8583a" />
        <path d="M1104 470V392Q1104 372 1124 372H1236Q1256 372 1256 392V470Z" fill="none" stroke="#7e3d26" strokeWidth="3" />
        <rect x="1126" y="430" width="40" height="34" rx="16" fill="#3a1a10" /><rect x="1196" y="430" width="40" height="34" rx="16" fill="#3a1a10" />
        <ellipse className="pd-flame" cx="1146" cy="452" rx="14" ry="12" fill="url(#pd-fire)" />
        <ellipse className="pd-flame" style={{ animationDelay: '0.3s' }} cx="1216" cy="452" rx="14" ry="12" fill="url(#pd-fire)" />
        <path d="M1118 372Q1146 400 1174 372Z" fill="#2b2b2b" /><rect x="1112" y="366" width="68" height="8" rx="4" fill="#3a3a3a" />
        <path d="M1194 372V350Q1194 338 1206 338H1226Q1238 338 1238 350V372Z" fill="#c9ccd1" stroke="#8d9198" strokeWidth="2" />
        <path d="M1238 350L1252 340" stroke="#8d9198" strokeWidth="4" strokeLinecap="round" />
        <path d="M1200 338Q1216 326 1232 338" stroke="#8d9198" strokeWidth="3" fill="none" />
        {[0, 1, 2].map((i) => <circle key={i} className="pd-steam" style={{ animationDelay: `${i * 0.9}s` }} cx="1252" cy="334" r="6" fill="#fff" />)}
        {[0, 1].map((i) => <circle key={i} className="pd-steam" style={{ animationDelay: `${i * 1.2 + 0.4}s` }} cx="1146" cy="360" r="7" fill="#fff" />)}
        {/* kendi & toples kerupuk */}
        <path d="M1086 492Q1070 474 1080 460Q1090 450 1098 460Q1108 474 1092 492Z" fill="#b5532f" /><rect x="1084" y="446" width="10" height="10" fill="#b5532f" />
        <rect x="1258" y="430" width="18" height="40" rx="4" fill="rgba(255,255,255,0.55)" stroke="#d9a441" />
        <rect x="1258" y="424" width="18" height="7" rx="2" fill="#2f6fb0" />
        {[[1262, 442], [1270, 452], [1263, 460]].map(([x, y]) => <circle key={`${x}${y}`} cx={x} cy={y} r="4" fill="#f3d9a4" />)}
      </g>

      {/* barang di lantai belakang: kardus dekat rak */}
      <rect x="1068" y="508" width="44" height="34" fill="#c99a62" stroke="#9c7140" strokeWidth="2" />
      <rect x="1074" y="480" width="34" height="28" fill="#d3a873" stroke="#9c7140" strokeWidth="2" />

      {/* tikar pandan + bantal */}
      <g>
        <path d="M40 650H300L314 712H26Z" fill="url(#pd-tikar)" stroke="#b39459" strokeWidth="2" />
        <rect x="52" y="652" width="44" height="18" rx="9" fill="#cf6b4a" /><rect x="58" y="657" width="32" height="2" fill="#f0c75e" />
      </g>

      {/* lincak bambu (tempat rapat & ngopi) */}
      <g>
        <rect x="540" y="640" width="300" height="16" rx="8" fill="#d6b56f" stroke="#a8843f" strokeWidth="2" />
        {[548, 588, 628, 668, 708, 748, 788, 828].map((x) => <line key={x} x1={x} x2={x} y1="642" y2="654" stroke="#b8924f" strokeWidth="2" />)}
        <rect x="540" y="604" width="300" height="10" rx="5" fill="#d6b56f" stroke="#a8843f" strokeWidth="2" />
        {[552, 690, 828].map((x) => <rect key={x} x={x - 5} y="604" width="10" height="40" rx="4" fill="#c9a35d" stroke="#a8843f" />)}
        {[552, 828].map((x) => <rect key={x} x={x - 5} y="654" width="10" height="34" rx="4" fill="#c9a35d" stroke="#a8843f" />)}
      </g>

      {/* dingklik (bangku kecil) di kedua ujung meja nongkrong */}
      {[512, 878].map((x) => (
        <g key={x}>
          <rect x={x - 24} y={680} width={48} height={9} rx="3" fill={WOOD_L} stroke={WOOD_D} strokeWidth="1.5" />
          <rect x={x - 20} y={689} width={7} height={22} fill={WOOD_D} /><rect x={x + 13} y={689} width={7} height={22} fill={WOOD_D} />
        </g>
      ))}

      {/* radio transistor di atas dingklik */}
      <g>
        <rect x="950" y="664" width="80" height="10" rx="3" fill={WOOD} />
        <rect x="956" y="674" width="8" height="30" fill={WOOD_D} /><rect x="1016" y="674" width="8" height="30" fill={WOOD_D} />
        <rect x="954" y="614" width="72" height="50" rx="8" fill="#8c2f2f" stroke="#5f1d1d" strokeWidth="2" />
        <rect x="962" y="622" width="34" height="34" rx="4" fill="#e6d5b0" />
        {[628, 636, 644, 652].map((y) => <line key={y} x1="965" x2="993" y1={y} y2={y} stroke="#b89a64" strokeWidth="2" />)}
        <circle cx="1010" cy="630" r="6" fill="#d9a441" /><circle cx="1010" cy="650" r="5" fill="#e6d5b0" />
        <line x1="1018" y1="614" x2="1040" y2="572" stroke="#9aa0a6" strokeWidth="2" />
        <g className="pd-notes"><text x="1030" y="600" fontSize="16" fill="#1F7F72">♪</text><text x="1044" y="590" fontSize="12" fill="#E2410F">♫</text></g>
      </g>

      {/* tanaman pot tanah liat */}
      <g>
        <path d="M1232 712L1226 672H1270L1264 712Z" fill="#b5532f" />
        {[[-14, -60], [-4, -74], [8, -66], [16, -50]].map(([dx, dy], i) => (
          <path key={i} d={`M1248 672Q${1248 + dx} ${672 + dy / 2} ${1248 + dx} ${672 + dy}Q${1248 + dx + 6} ${672 + dy / 2} 1250 672`} fill="#3f7a4a" />
        ))}
      </g>

      {/* kipas angin gantung & bohlam */}
      <g>
        <line x1="640" y1="0" x2="640" y2="40" stroke="#3a3a3a" strokeWidth="4" />
        <g transform="translate(640 46) scale(1 0.28)">
          <g className="pd-fan">
            {[0, 120, 240].map((a) => <ellipse key={a} cx="0" cy="-38" rx="12" ry="38" fill="#7a5a3a" transform={`rotate(${a})`} />)}
          </g>
        </g>
        <circle cx="640" cy="46" r="9" fill="#4a4a4a" />
        {[330, 980].map((x) => (
          <g key={x}>
            <line x1={x} y1="34" x2={x} y2="74" stroke="#2b2b2b" strokeWidth="2" />
            <rect x={x - 5} y="72" width="10" height="8" fill="#5a5a5a" />
            <circle cx={x} cy="88" r="10" fill={sky.lamps ? '#fff3b0' : '#f2efe6'} stroke="#c9c2a8" strokeWidth="1.5" />
          </g>
        ))}
      </g>
    </g>
  );
});

// Meja-meja kerja: digambar di atas karakter yang duduk di belakangnya, di bawah karakter yang lewat di depan
export const DeskFronts = memo(function DeskFronts() {
  return (
    <g>
      {/* meja Gareng: laptop, kopi, nota */}
      <Desk x={70} w={230} />
      <LaptopBack x={160} y={452} />
      <rect x={244} y={446} width={16} height={16} rx="3" fill="#f4f1e8" stroke="#bbb" /><rect x={246} y={440} width={12} height={6} fill="#5a3a22" />
      <path d="M96 462V438" stroke="#777" strokeWidth="2" /><rect x={88} y={444} width={16} height={12} fill="#fff" stroke="#ccc" />
      {/* meja Bagong: laptop, sempoa, buku besar, lampu meja */}
      <Desk x={334} w={230} />
      <LaptopBack x={430} y={452} />
      <g>
        <rect x={350} y={440} width={56} height={22} rx="2" fill="#7a4a24" />
        {[444, 451, 458].map((y) => <line key={y} x1={352} x2={404} y1={y} y2={y} stroke="#d9c49a" strokeWidth="1" />)}
        {[0, 1, 2, 3, 4, 5].map((i) => <circle key={i} cx={358 + i * 8} cy={444 + (i % 3) * 7} r="2.5" fill={i % 2 ? '#E2410F' : '#F7B733'} />)}
      </g>
      <rect x={508} y={448} width={40} height={14} rx="2" fill="#2f4a3b" /><rect x={510} y={446} width={36} height={3} fill="#e8d9b0" />
      <path d="M540 446V420L556 412" stroke="#3a3a3a" strokeWidth="3" fill="none" /><path d="M550 404L566 414L556 424Z" fill="#1F7F72" />
      {/* meja Bima: TV tabung CCTV + laptop */}
      <Desk x={776} w={160} />
      <LaptopBack x={852} y={452} />
      <g>
        <rect x={786} y={406} width={52} height={48} rx="6" fill="#4a4a4a" />
        <rect x={792} y={412} width={40} height={32} rx="4" fill="#20343a" />
        <g className="pd-screen">
          <rect x={794} y={414} width={18} height={14} fill="#3f6b5f" /><rect x={813} y={414} width={17} height={14} fill="#4a5f6b" />
          <rect x={794} y={429} width={18} height={13} fill="#4a5f6b" /><rect x={813} y={429} width={17} height={13} fill="#3f6b5f" />
        </g>
        <circle cx={828} cy={448} r="2" fill="#ef4444" className="pd-led" />
      </g>
    </g>
  );
});

// Meja gaple di depan lincak (paling depan): kartu, gaple, kopi, pisang goreng
export const CoffeeTable = memo(function CoffeeTable() {
  const tiles = [[618, 672, 0], [636, 670, 1], [656, 673, 0], [676, 670, 1], [728, 672, 0], [748, 669, 1]];
  return (
    <g>
      <rect x={576} y={684} width={232} height={12} rx="5" fill="#8a5a30" />
      <rect x={588} y={696} width={8} height={20} fill="#6b4423" /><rect x={788} y={696} width={8} height={20} fill="#6b4423" />
      {/* kartu gaple (domino) */}
      {tiles.map(([x, y, v], i) => (
        <g key={i} transform={`rotate(${(i % 3) * 8 - 8} ${x + 7} ${y + 4})`}>
          <rect x={x} y={y} width={16} height={9} rx="1.5" fill="#fbf8ef" stroke="#3a2414" strokeWidth="1" />
          <line x1={x + 8} y1={y} x2={x + 8} y2={y + 9} stroke="#3a2414" strokeWidth="0.8" />
          <circle cx={x + 4} cy={y + 4.5} r="1.2" fill="#c0392b" /><circle cx={x + 12} cy={y + 3} r="1" fill="#1d2433" />
          {v ? <circle cx={x + 12} cy={y + 6} r="1" fill="#1d2433" /> : null}
        </g>
      ))}
      {/* kartu remi */}
      {[[690, 668, -12, '#c0392b'], [700, 670, 6, '#1d2433'], [770, 668, 14, '#c0392b']].map(([x, y, r, c], i) => (
        <g key={i} transform={`rotate(${r} ${x} ${y})`}>
          <rect x={x as number} y={y as number} width={11} height={15} rx="1.5" fill="#fff" stroke="#bbb" />
          <text x={(x as number) + 2.5} y={(y as number) + 10} fontSize="8" fill={c as string}>{i === 1 ? '♠' : '♥'}</text>
        </g>
      ))}
      {/* tumpukan kartu & kopi */}
      <rect x={598} y={674} width={14} height={9} rx="1.5" fill="#2f6fb0" stroke="#1d4f80" /><rect x={600} y={672} width={14} height={9} rx="1.5" fill="#2f6fb0" stroke="#1d4f80" />
      <rect x={786} y={666} width={16} height={18} rx="3" fill="#f4f1e8" stroke="#bbb" /><rect x={788} y={661} width={12} height={6} fill="#3a2414" />
      <circle className="pd-steam" cx={794} cy={654} r="4" fill="#fff" />
      <ellipse cx={716} cy={682} rx={18} ry={4} fill="#e8e1cf" /><ellipse cx={710} cy={679} rx={7} ry={3.5} fill="#d99a3c" /><ellipse cx={722} cy={679} rx={7} ry={3.5} fill="#c9862e" />
    </g>
  );
});

const Desk = ({ x, w }: { x: number; w: number }) => (
  <g>
    <rect x={x} y={460} width={w} height={14} rx="3" fill="#8a5a30" />
    <rect x={x + 8} y={474} width={w - 16} height={58} fill="#6b4423" />
    <rect x={x + 16} y={482} width={(w - 40) / 2} height={20} rx="3" fill="none" stroke="#8a5a30" strokeWidth="2" />
    <rect x={x + 24 + (w - 40) / 2} y={482} width={(w - 40) / 2} height={20} rx="3" fill="none" stroke="#8a5a30" strokeWidth="2" />
    <rect x={x + 8} y={532} width="10" height="44" fill="#4e2f17" /><rect x={x + w - 18} y={532} width="10" height="44" fill="#4e2f17" />
  </g>
);

// laptop dilihat dari belakang: tutup dengan logo gunungan menyala
const LaptopBack = ({ x, y }: { x: number; y: number }) => (
  <g>
    <rect x={x - 32} y={y - 40} width={64} height={42} rx="4" fill="#2c3445" />
    <rect x={x - 34} y={y} width={68} height={6} rx="2" fill="#3d4659" />
    <path d={`M${x} ${y - 32}C${x + 4} ${y - 26} ${x + 9} ${y - 22} ${x + 9} ${y - 16}C${x + 9} ${y - 11} ${x + 4} ${y - 9} ${x} ${y - 9}C${x - 4} ${y - 9} ${x - 9} ${y - 11} ${x - 9} ${y - 16}C${x - 9} ${y - 22} ${x - 4} ${y - 26} ${x} ${y - 32}Z`} fill="#4ABDAC" className="pd-glow" />
    <rect x={x - 30} y={y - 42} width={60} height={4} rx="2" fill="rgba(74,189,172,0.35)" className="pd-glow" />
  </g>
);

// ---------------------------------------------------------------------------------------------
// Karakter (gaya maskot bulat) berpakaian Jawa + tato wayang
// ---------------------------------------------------------------------------------------------
interface Look {
  w: number; h: number; skin: string; skinD: string;
  top?: 'kuncung' | 'blangkon' | 'gelung' | 'rambut';
  hat?: string; shirt?: string; shirtStripe?: string; kain: string; kain2: string; kainType: 'poleng' | 'parang' | 'kotak' | 'bintulu';
  nose?: 'long'; mouth: 'smile' | 'grin' | 'kumis'; tattoo?: string; gold?: boolean;
}
export const LOOKS: Record<AgentId, Look> = {
  semar: { w: 104, h: 118, skin: '#5f4334', skinD: '#4a3328', top: 'kuncung', kain: '#f4f1e8', kain2: '#1d2433', kainType: 'poleng', mouth: 'smile', gold: true },
  gareng: { w: 78, h: 106, skin: '#c9926b', skinD: '#a8764f', top: 'blangkon', hat: '#5a3a22', shirt: '#3e6b4f', shirtStripe: '#2c4f39', kain: '#7d5a3a', kain2: '#c9a36a', kainType: 'parang', mouth: 'smile' },
  petruk: { w: 72, h: 142, skin: '#d9a07a', skinD: '#b9805a', top: 'blangkon', hat: '#7a2323', shirt: '#8c2f2f', shirtStripe: '#6b1f1f', kain: '#3a3a5a', kain2: '#d9c49a', kainType: 'kotak', nose: 'long', mouth: 'smile', tattoo: '#2b3a55' },
  bagong: { w: 104, h: 108, skin: '#7a5240', skinD: '#5f3f30', top: 'rambut', kain: '#6b4a2a', kain2: '#e0b871', kainType: 'parang', mouth: 'grin', tattoo: '#2b2b3a', gold: true },
  bima: { w: 94, h: 146, skin: '#3b3b47', skinD: '#2b2b35', top: 'gelung', kain: '#c0392b', kain2: '#f4f1e8', kainType: 'bintulu', mouth: 'kumis', tattoo: '#d9a441', gold: true },
};

const egg = (w: number, h: number) => {
  const r = w / 2, k = 0.56;
  return `M0 ${-h}C${k * r} ${-h} ${r} ${-h * 0.76} ${r} ${-h * 0.44}C${r} ${-h * 0.14} ${r * 0.56} -12 0 -12C${-r * 0.56} -12 ${-r} ${-h * 0.14} ${-r} ${-h * 0.44}C${-r} ${-h * 0.76} ${-k * r} ${-h} 0 ${-h}Z`;
};

export interface MascotProps {
  id: AgentId; pose: Pose; face: 1 | -1; t: number;        // t = detik (untuk napas, kedip, ketik)
  walk: number;                                            // fase langkah 0..1 (0 = diam)
  typing?: boolean; blink?: boolean; wave?: boolean; holding?: 'clipboard' | 'cup' | 'kentongan' | null;
  arms?: 'up' | 'chin' | null;                             // sorak/menggeliat, atau tangan di dagu (berpikir)
  talking?: boolean;                                      // mulut bergerak saat bicara
}

export function Mascot({ id, pose, face, t, walk, typing, blink, wave, holding, arms, talking }: MascotProps) {
  const L = LOOKS[id];
  const { w, h } = L;
  const breathe = 1 + 0.018 * Math.sin(t * 2.2 + w);
  const hop = walk ? -Math.abs(Math.sin(walk * Math.PI)) * 9 : 0;
  const squash = walk ? 1 - 0.05 * Math.abs(Math.cos(walk * Math.PI)) : breathe;
  const eyeY = -h * 0.66, eyeX = w * 0.17, eyeRy = blink ? 1.2 : 11;
  const look = face * 3;
  const sitDrop = pose === 'sit' ? 12 : 0;
  const legLift = walk ? Math.sin(walk * Math.PI * 2) * 5 : 0;
  const armA = typing ? Math.sin(t * 18) * 4 : 0;
  const armB = typing ? Math.sin(t * 18 + 2) * 4 : 0;
  const waveDeg = wave ? -120 + Math.sin(t * 10) * 25 : arms === 'up' ? -150 + Math.sin(t * 12) * 10 : arms === 'chin' ? -118 : 0;
  const leftDeg = arms === 'up' ? 150 - Math.sin(t * 12) * 10 : 0;
  const mouthOpen = talking && Math.sin(t * 22) > -0.2;
  const clip = `pd-clip-${id}`;
  const kainY = -h * 0.42;

  const body = (
    <g transform={`translate(0 ${hop + sitDrop}) scale(1 ${squash})`}>
      {/* kaki */}
      {pose === 'sit' ? (
        <g fill={L.skinD}><ellipse cx={-w * 0.18} cy={-8} rx={11} ry={8} /><ellipse cx={w * 0.18} cy={-8} rx={11} ry={8} /></g>
      ) : (
        <g fill={L.skinD}>
          <rect x={-w * 0.18 - 8} y={-18 - Math.max(0, legLift)} width={16} height={20} rx={8} />
          <rect x={w * 0.18 - 8} y={-18 - Math.max(0, -legLift)} width={16} height={20} rx={8} />
        </g>
      )}
      <defs><clipPath id={clip}><path d={egg(w, h)} /></clipPath></defs>
      <path d={egg(w, h)} fill={L.skin} />
      <g clipPath={`url(#${clip})`}>
        {/* kilau badan */}
        <ellipse cx={-w * 0.2} cy={-h * 0.78} rx={w * 0.18} ry={h * 0.12} fill="#fff" opacity="0.12" />
        {/* baju surjan lurik */}
        {L.shirt && <>
          <rect x={-w} y={-h * 0.56} width={w * 2} height={h * 0.16} fill={L.shirt} />
          {Array.from({ length: 12 }, (_, i) => <rect key={i} x={-w / 2 + i * (w / 11)} y={-h * 0.56} width={2.5} height={h * 0.16} fill={L.shirtStripe} />)}
          <path d={`M${-w * 0.14} ${-h * 0.56}L0 ${-h * 0.47}L${w * 0.14} ${-h * 0.56}`} fill={L.skin} />
        </>}
        {/* kain / sarung */}
        <rect x={-w} y={kainY} width={w * 2} height={h} fill={L.kain} />
        <Kain type={L.kainType} w={w} y={kainY} c1={L.kain} c2={L.kain2} />
        <rect x={-w} y={kainY - 4} width={w * 2} height={6} fill={L.gold ? '#d9a441' : '#3a2414'} />
        {/* tato wayang di perut/samping */}
        {L.tattoo && !L.shirt && <TattooGunungan x={w * 0.22} y={-h * 0.58} s={0.5} c={L.tattoo} />}
      </g>
      {/* lengan */}
      <g fill={L.skin}>
        <ellipse cx={-w / 2 + 2} cy={-h * 0.44 + armA} rx={9} ry={16} transform={leftDeg ? `rotate(${leftDeg} ${-w / 2 + 2} ${-h * 0.54})` : undefined} />
        <g transform={`rotate(${waveDeg} ${w / 2 - 2} ${-h * 0.54})`}>
          <ellipse cx={w / 2 - 2} cy={-h * 0.44 + armB} rx={9} ry={16} />
          {L.tattoo && <TattooGunungan x={w / 2 - 2} y={-h * 0.48 + armB} s={0.32} c={L.tattoo} />}
          {L.gold && <rect x={w / 2 - 11} y={-h * 0.52 + armB} width={18} height={5} rx="2" fill="#d9a441" />}
        </g>
        {L.gold && <rect x={-w / 2 - 7} y={-h * 0.52 + armA} width={18} height={5} rx="2" fill="#d9a441" />}
      </g>
      {/* kepala: kuncung / blangkon / gelung / rambut */}
      <Top look={L} />
      {/* wajah */}
      <g transform={`translate(${look * 0.6} 0)`}>
        {[-eyeX, eyeX].map((x) => (
          <g key={x}>
            <ellipse cx={x} cy={eyeY} rx={9} ry={eyeRy} fill="#fff" />
            {!blink && <><circle cx={x + look} cy={eyeY + 1} r={5.2} fill="#1d1d24" /><circle cx={x + look + 2} cy={eyeY - 2} r={1.7} fill="#fff" /></>}
          </g>
        ))}
        <ellipse cx={-eyeX - 6} cy={eyeY + 15} rx={7} ry={4} fill="#ff8f8f" opacity="0.32" />
        <ellipse cx={eyeX + 6} cy={eyeY + 15} rx={7} ry={4} fill="#ff8f8f" opacity="0.32" />
        {L.nose === 'long'
          ? <path d={`M${face * 2} ${eyeY + 4}Q${face * 30} ${eyeY + 6} ${face * 40} ${eyeY + 15}Q${face * 18} ${eyeY + 18} ${face * 2} ${eyeY + 14}Z`} fill={L.skinD} stroke="#8a5a3a" strokeWidth="1.5" />
          : <ellipse cx={face * 2} cy={eyeY + 10} rx={4} ry={3} fill={L.skinD} />}
        {L.mouth === 'grin' && <path d={`M-14 ${eyeY + 20}Q0 ${eyeY + 36} 14 ${eyeY + 20}Z`} fill="#3a1a14" />}
        {mouthOpen && <ellipse cx={0} cy={eyeY + (L.mouth === 'kumis' ? 24 : 22)} rx={6} ry={4.5} fill="#3a1a14" />}
        {L.mouth === 'smile' && !mouthOpen && <path d={`M-6 ${eyeY + 19}Q0 ${eyeY + 24} 6 ${eyeY + 19}`} stroke="#3a1a14" strokeWidth="2" fill="none" strokeLinecap="round" />}
        {L.mouth === 'kumis' && <>
          <path d={`M-14 ${eyeY + 18}Q-6 ${eyeY + 12} 0 ${eyeY + 17}Q6 ${eyeY + 12} 14 ${eyeY + 18}Q6 ${eyeY + 22} 0 ${eyeY + 19}Q-6 ${eyeY + 22} -14 ${eyeY + 18}Z`} fill="#111" />
        </>}
      </g>
      {/* barang yang dipegang */}
      {holding === 'clipboard' && <g transform={`translate(${w * 0.18} ${-h * 0.42 + armB})`}><rect x="-12" y="-16" width="24" height="30" rx="2" fill="#c99a62" /><rect x="-9" y="-11" width="18" height="22" fill="#fff" /><path d="M-6 -6H6M-6 -1H6M-6 4H3" stroke="#999" strokeWidth="1.5" /></g>}
      {holding === 'cup' && <g transform={`translate(${w * 0.3} ${-h * 0.42})`}><rect x="-7" y="-9" width="14" height="14" rx="3" fill="#f4f1e8" stroke="#bbb" /><rect x="-5" y="-11" width="10" height="4" fill="#3a2414" /></g>}
      {holding === 'kentongan' && <g transform={`translate(${w * 0.36} ${-h * 0.5}) rotate(20)`}><rect x="-6" y="-22" width="12" height="40" rx="6" fill="#c8a25a" stroke="#8a6a2a" strokeWidth="2" /><rect x="-2" y="-10" width="4" height="16" rx="2" fill="#5a3a12" /></g>}
    </g>
  );

  if (pose === 'lie') {
    return <g transform={`rotate(${-82 * face}) translate(${-h * 0.05} 8)`}>{body}</g>;
  }
  return body;
}

function Top({ look: L }: { look: Look }) {
  const { w, h } = L;
  if (L.top === 'kuncung') {
    return <path d={`M${-w * 0.06} ${-h + 4}C${-w * 0.2} ${-h - 22} ${w * 0.18} ${-h - 30} ${w * 0.16} ${-h - 10}C${w * 0.14} ${-h - 2} ${w * 0.02} ${-h - 6} ${w * 0.04} ${-h - 14}`} stroke="#f4f1e8" strokeWidth="7" fill="none" strokeLinecap="round" />;
  }
  if (L.top === 'blangkon') {
    return (
      <g>
        <path d={`M${-w * 0.47} ${-h * 0.8}C${-w * 0.44} ${-h - 8} ${w * 0.44} ${-h - 8} ${w * 0.47} ${-h * 0.8}C${w * 0.3} ${-h * 0.84} ${-w * 0.3} ${-h * 0.84} ${-w * 0.47} ${-h * 0.8}Z`} fill={L.hat} />
        <path d={`M${-w * 0.4} ${-h * 0.86}Q0 ${-h * 0.92} ${w * 0.4} ${-h * 0.86}`} stroke="#d9a441" strokeWidth="2" fill="none" />
        {[-0.24, -0.08, 0.08, 0.24].map((k) => <circle key={k} cx={w * k} cy={-h * 0.93} r={2} fill="#d9a441" opacity="0.8" />)}
        <ellipse cx={-w * 0.44} cy={-h * 0.82} rx={9} ry={7} fill={L.hat} />
      </g>
    );
  }
  if (L.top === 'gelung') {
    return (
      <g>
        <path d={`M${-w * 0.36} ${-h * 0.86}C${-w * 0.3} ${-h - 4} ${w * 0.3} ${-h - 4} ${w * 0.36} ${-h * 0.86}Z`} fill="#111" />
        <ellipse cx="0" cy={-h - 8} rx={16} ry={12} fill="#111" />
        <rect x="-17" y={-h - 2} width="34" height="6" rx="3" fill="#d9a441" />
        <circle cx={w * 0.46} cy={-h * 0.62} r={3.5} fill="#d9a441" />
      </g>
    );
  }
  return <g stroke="#1d1d24" strokeWidth="2.5" fill="none" strokeLinecap="round"><path d={`M-6 ${-h + 2}Q-10 ${-h - 12} -4 ${-h - 16}`} /><path d={`M2 ${-h + 1}Q2 ${-h - 14} 8 ${-h - 18}`} /><path d={`M9 ${-h + 3}Q14 ${-h - 8} 18 ${-h - 10}`} /></g>;
}

function Kain({ type, w, y, c1, c2 }: { type: Look['kainType']; w: number; y: number; c1: string; c2: string }) {
  const cells: ReactElement[] = [];
  if (type === 'poleng' || type === 'bintulu' || type === 'kotak') {
    const s = type === 'kotak' ? 9 : 12;
    for (let r = 0; r < 6; r++) for (let c = -6; c < 6; c++) {
      if ((r + c) % 2 === 0) cells.push(<rect key={`${r}${c}`} x={c * s} y={y + r * s} width={s} height={s} fill={c2} />);
      if (type === 'bintulu' && (r + c) % 3 === 0) cells.push(<rect key={`b${r}${c}`} x={c * s} y={y + r * s} width={s} height={s} fill="#1d2433" />);
    }
    if (type === 'bintulu') cells.push(<rect key="gold" x={-w} y={y + 30} width={w * 2} height={4} fill="#d9a441" />);
  } else {
    for (let i = -8; i < 8; i++) cells.push(<path key={i} d={`M${i * 12} ${y}L${i * 12 + 40} ${y + 60}`} stroke={c2} strokeWidth="4" />);
    cells.push(<rect key="hem" x={-w} y={y + 6} width={w * 2} height={3} fill={c1} opacity="0.5" />);
  }
  return <g>{cells}</g>;
}

function TattooGunungan({ x, y, s, c }: { x: number; y: number; s: number; c: string }) {
  return (
    <g transform={`translate(${x} ${y}) scale(${s})`} opacity="0.9">
      <path d="M0 -20C6 -12 14 -6 16 4C18 12 14 18 10 20H-10C-14 18 -18 12 -16 4C-14 -6 -6 -12 0 -20Z" fill="none" stroke={c} strokeWidth="3" />
      <path d="M0 16V-8M0 6C-4 2 -8 2 -10 4M0 6C4 2 8 2 10 4" stroke={c} strokeWidth="2.5" fill="none" />
    </g>
  );
}

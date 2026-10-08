import { useEffect, useState } from 'react';
import { AGENTS, CORRIDOR_Y, SPOTS, VISIT, type AgentId, type Pose, type Spot } from './world';

// Simulasi "hidup" kantor Pendopo: jadwal mengikuti jam WIB, jalan antar titik, kedip, ketik, gelembung emoji.
// Murni visual di browser, belum terhubung ke agent AI.
// Uji cepat lewat URL: ?jam=21.5 (paksa jam WIB) dan ?hidup=cepat (timer 7x lebih cepat).

export type Status = 'kerja' | 'rapat' | 'istirahat' | 'santai' | 'tidur' | 'ronda' | 'pulang' | 'lembur';
type Holding = 'clipboard' | 'cup' | 'kentongan' | null;

export interface Actor {
  id: AgentId; x: number; y: number; face: 1 | -1; pose: Pose;
  path: { x: number; y: number }[]; walk: number; spot: Spot | null;
  label: string; emoji: string | null; emojiUntil: number; status: Status;
  until: number; typing: boolean; holding: Holding; blinkAt: number; blinkUntil: number;
  opacity: number; leaving: boolean; gone: boolean; wave: number;
}

interface Plan { spot: Spot; label: string; emoji: string | null; status: Status; dur: [number, number]; holding?: Holding; leave?: boolean }

const params = new URLSearchParams(typeof window !== 'undefined' ? window.location.search : '');
const FORCE_HOUR = params.get('jam') ? Number(params.get('jam')) : null;
const FAST = params.get('hidup') === 'cepat';
const TIME_SCALE = FAST ? 0.15 : 1;

export function wibHour(): { h: number; hour: number; minute: number } {
  if (FORCE_HOUR !== null && !Number.isNaN(FORCE_HOUR)) {
    const hour = Math.floor(FORCE_HOUR), minute = Math.round((FORCE_HOUR - hour) * 60);
    return { h: FORCE_HOUR, hour, minute };
  }
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Jakarta', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date());
  const hour = Number(parts.find((p) => p.type === 'hour')?.value ?? 0);
  const minute = Number(parts.find((p) => p.type === 'minute')?.value ?? 0);
  return { h: hour + minute / 60, hour, minute };
}

const rnd = (a: number, b: number) => a + Math.random() * (b - a);
const pick = <T,>(arr: T[]) => arr[Math.floor(Math.random() * arr.length)];
const NAME = Object.fromEntries(AGENTS.map((a) => [a.id, a.name])) as Record<AgentId, string>;
const TASKS = Object.fromEntries(AGENTS.map((a) => [a.id, a.tasks])) as Record<AgentId, string[]>;
const HOME_EMOJI: Record<AgentId, string> = { semar: '🧭', gareng: '🧾', petruk: '📦', bagong: '🧮', bima: '🔍' };

function phaseOf(h: number) {
  if (h >= 22 || h < 5) return 'malam';
  if (h < 7.5) return 'pagi';
  if (h >= 9 && h < 9.5) return 'rapat';
  if (h >= 12 && h < 13) return 'siang';
  if (h >= 17 && h < 19) return 'sore';
  if (h >= 19) return 'petang';
  return 'kerja';
}

const MEETING: Record<AgentId, Spot> = {
  semar: SPOTS.home.semar, gareng: SPOTS.lincak[0], bagong: SPOTS.lincak[1], petruk: SPOTS.lincak[2], bima: VISIT['home-semar'],
};

// Mesin simulasi (di luar React): daftar aktor, jadwal, dan gerak
class OfficeSim {
  actors: Actor[] = [];
  reserved: Record<string, AgentId> = {};
  time = 0;

  constructor() {
    const { h } = wibHour();
    this.actors = AGENTS.map((d) => ({
      id: d.id, x: 0, y: 0, face: 1, pose: 'stand', path: [], walk: 0, spot: null, label: '', emoji: null, emojiUntil: 0,
      status: 'kerja', until: 0, typing: false, holding: null, blinkAt: rnd(1, 4), blinkUntil: 0, opacity: 1, leaving: false, gone: false, wave: 0,
    }));
    // posisi awal: langsung di tempat sesuai jam (tanpa berjalan)
    this.actors.forEach((a) => {
      const p = this.planFor(a, h);
      if (p.leave) {
        a.gone = true; a.opacity = 0; a.status = 'pulang'; a.label = 'sudah pulang';
        a.x = SPOTS.pintu[0].x; a.y = SPOTS.pintu[0].y; a.until = Infinity;
        return;
      }
      this.assign(a, p, 0, true);
      a.emojiUntil = rnd(1, 3);
    });
  }

  free(s: Spot, id: AgentId) { return !this.reserved[s.id] || this.reserved[s.id] === id; }
  freeOf(list: Spot[], id: AgentId) { return list.find((s) => this.free(s, id)) ?? null; }

  // pilih kegiatan berikutnya sesuai jam
  planFor(a: Actor, h: number): Plan {
    const home = SPOTS.home[a.id];
    const work: Plan = { spot: home, label: pick(TASKS[a.id]), emoji: HOME_EMOJI[a.id], status: 'kerja', dur: [18, 40], holding: a.id === 'petruk' ? 'clipboard' : null };
    const ph = phaseOf(h);
    if (ph === 'malam') {
      if (a.id === 'bima') {
        const s = a.spot?.id === 'pintu-1' ? SPOTS.lincak[2] : SPOTS.pintu[0];
        return { spot: s, label: 'ronda malam, jaga kantor', emoji: '🔦', status: 'ronda', dur: [10, 18], holding: 'kentongan' };
      }
      if (a.id === 'semar') return { spot: home, label: 'terlelap di lincak', emoji: '💤', status: 'tidur', dur: [40, 80] };
      if (a.id === 'bagong') return { spot: home, label: 'ketiduran di meja', emoji: '💤', status: 'tidur', dur: [40, 80] };
      const tikar = this.freeOf(SPOTS.tikar, a.id);
      return tikar ? { spot: tikar, label: 'tidur di tikar', emoji: '💤', status: 'tidur', dur: [40, 80] } : { ...work, label: 'tidur di meja', emoji: '💤', status: 'tidur' };
    }
    if (ph === 'rapat') return { spot: MEETING[a.id], label: a.id === 'semar' ? 'memimpin rapat pagi' : 'rapat pagi di lincak', emoji: '💬', status: 'rapat', dur: [20, 40] };
    if (ph === 'pagi') {
      const d = this.freeOf(SPOTS.dapur, a.id);
      return Math.random() < 0.5 && d ? { spot: d, label: 'ngopi tubruk pagi', emoji: '☕', status: 'istirahat', dur: [8, 14], holding: 'cup' } : { ...work, label: 'siap-siap kerja' };
    }
    if (ph === 'siang') {
      const d = this.freeOf(SPOTS.dapur, a.id), l = this.freeOf(SPOTS.lincak, a.id), t = this.freeOf(SPOTS.tikar, a.id);
      if (a.id === 'bagong' && t) return { spot: t, label: 'tidur siang habis makan', emoji: '💤', status: 'istirahat', dur: [20, 40] };
      if (Math.random() < 0.45 && d) return { spot: d, label: 'masak mie rebus', emoji: '🍜', status: 'istirahat', dur: [10, 18] };
      if (l) return { spot: l, label: 'makan nasi bungkus', emoji: '🍛', status: 'istirahat', dur: [12, 24] };
      return { ...work, label: 'makan sambil kerja', emoji: '🍛', status: 'istirahat' };
    }
    if (ph === 'sore' && a.id !== 'bima' && a.id !== 'bagong') {
      const radio = this.freeOf(SPOTS.radio, a.id), l = this.freeOf(SPOTS.lincak, a.id);
      if (Math.random() < 0.3 && radio) return { spot: radio, label: 'dengerin campursari', emoji: '📻', status: 'santai', dur: [10, 20] };
      if (l) return { spot: l, label: 'ngobrol santai sore', emoji: '💬', status: 'santai', dur: [12, 24], holding: 'cup' };
    }
    if (ph === 'petang') {
      if (a.id === 'gareng' || a.id === 'petruk') return { spot: SPOTS.pintu[0], label: 'pulang ke rumah', emoji: '👋', status: 'pulang', dur: [999, 999], leave: true };
      if (a.id === 'semar') {
        const radio = this.freeOf(SPOTS.radio, a.id);
        return radio && Math.random() < 0.4 ? { spot: radio, label: 'dengerin siaran wayang', emoji: '📻', status: 'santai', dur: [14, 24] } : { ...work, label: 'menyiapkan laporan besok', status: 'lembur' };
      }
      return { ...work, label: a.id === 'bima' ? 'pantau CCTV malam' : 'tutup buku harian', status: 'lembur' };
    }
    // jam kerja: kebanyakan di meja, sesekali jalan-jalan
    const r = Math.random();
    if (r < 0.62) return work;
    if (r < 0.74) {
      const d = this.freeOf(SPOTS.dapur, a.id);
      if (d) return { spot: d, label: pick(['bikin kopi tubruk', 'goreng pisang', 'seduh teh nasgitel']), emoji: '☕', status: 'istirahat', dur: [8, 14], holding: 'cup' };
    }
    if (r < 0.8) {
      const p = this.freeOf(SPOTS.papan, a.id);
      if (p) return { spot: p, label: 'nulis target di papan kapur', emoji: '✏️', status: 'kerja', dur: [8, 12] };
    }
    if (r < 0.92) {
      const mates = this.actors.filter((o) => o.id !== a.id && !o.gone && o.spot?.id === SPOTS.home[o.id].id);
      const mate = mates.length ? pick(mates) : null;
      const v = mate && VISIT[SPOTS.home[mate.id].id];
      if (mate && v && this.free(v, a.id)) return { spot: v, label: `ngobrol sama ${NAME[mate.id]}`, emoji: '💬', status: 'kerja', dur: [6, 10] };
    }
    if (r < 0.96) {
      const j = this.freeOf(SPOTS.jendela, a.id);
      if (j) return { spot: j, label: 'lihat cuaca di jendela', emoji: '🌤️', status: 'istirahat', dur: [5, 8] };
    }
    const radio = this.freeOf(SPOTS.radio, a.id);
    if (radio) return { spot: radio, label: 'ganti siaran radio', emoji: '📻', status: 'istirahat', dur: [5, 8] };
    return work;
  }

  // jalur: turun ke koridor, menyusuri koridor, lalu naik/turun ke titik tujuan
  route(a: Actor, s: Spot) {
    const pts: { x: number; y: number }[] = [];
    if (Math.abs(a.y - CORRIDOR_Y) > 4 && Math.abs(a.x - s.x) > 8) pts.push({ x: a.x, y: CORRIDOR_Y });
    if (Math.abs(a.x - s.x) > 8) pts.push({ x: s.x, y: pts.length ? CORRIDOR_Y : a.y });
    pts.push({ x: s.x, y: s.y });
    return pts;
  }

  assign(a: Actor, p: Plan, now: number, instant = false) {
    if (a.spot) delete this.reserved[a.spot.id];
    this.reserved[p.spot.id] = a.id;
    a.spot = p.spot; a.label = p.label; a.status = p.status; a.holding = p.holding ?? null; a.leaving = !!p.leave;
    a.until = now + rnd(p.dur[0], p.dur[1]) * TIME_SCALE;
    a.emoji = p.emoji; a.emojiUntil = now + 3.5;
    if (instant || (a.x === p.spot.x && a.y === p.spot.y)) {
      a.x = p.spot.x; a.y = p.spot.y; a.path = []; a.pose = p.spot.pose; a.face = p.spot.face;
    } else {
      a.path = this.route(a, p.spot); a.pose = 'stand';
    }
  }

  step(dt: number, h: number, reduced: boolean) {
    this.time += dt;
    const now = this.time;
    const speed = (h >= 22 || h < 6 ? 0.8 : 1) * 105;
    for (const a of this.actors) {
      // datang lagi pagi hari setelah pulang
      if (a.gone) {
        const ph = phaseOf(h);
        if (ph === 'petang' || ph === 'malam') continue;
        a.gone = false; a.leaving = false; a.x = SPOTS.pintu[0].x; a.y = SPOTS.pintu[0].y; a.spot = SPOTS.pintu[0];
        a.wave = now + 1.6; a.emoji = '👋'; a.emojiUntil = now + 2.5; a.until = now;
      }
      if (a.opacity < 1 && !a.leaving) a.opacity = Math.min(1, a.opacity + dt * 1.5);

      if (a.path.length) {
        const target = a.path[0];
        const dx = target.x - a.x, dy = target.y - a.y, dist = Math.hypot(dx, dy);
        const stepLen = speed * dt;
        if (Math.abs(dx) > 1) a.face = dx > 0 ? 1 : -1;
        if (reduced || dist <= stepLen) {
          a.x = target.x; a.y = target.y; a.path.shift();
          if (!a.path.length && a.spot) { a.pose = a.spot.pose; a.face = a.spot.face; a.walk = 0; a.emojiUntil = now + 3; }
        } else {
          a.x += (dx / dist) * stepLen; a.y += (dy / dist) * stepLen;
          a.walk = (a.walk + dt * 2.6) % 1;
        }
      } else if (a.leaving) {
        a.opacity = Math.max(0, a.opacity - dt * 1.2);
        if (a.opacity === 0) { a.gone = true; a.label = 'sudah pulang'; if (a.spot) delete this.reserved[a.spot.id]; a.spot = null; }
      } else if (now >= a.until) {
        this.assign(a, this.planFor(a, h), now);
      }

      const atHome = !a.path.length && a.spot?.id === SPOTS.home[a.id].id;
      a.typing = !reduced && atHome && a.status !== 'tidur' && a.pose === 'desk';
      if (now >= a.blinkAt) { a.blinkUntil = now + 0.13; a.blinkAt = now + rnd(2.4, 5.5); }
      // gelembung emoji muncul lagi sesekali
      if (!a.path.length && a.status !== 'pulang' && now > a.emojiUntil + 9) a.emojiUntil = now + 3;
    }
  }
}

export function useOfficeSim(paused: boolean) {
  const [sim] = useState(() => new OfficeSim());
  const [, setTick] = useState(0);
  const [clock, setClock] = useState(wibHour);

  useEffect(() => {
    if (paused) return;
    const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false;
    let raf = 0, last = performance.now(), lastPaint = 0, lastClock = 0;
    const loop = (ts: number) => {
      const dt = Math.min(0.1, (ts - last) / 1000);
      last = ts;
      sim.step(dt, wibHour().h, reduced);
      if (ts - lastClock > 20000) { lastClock = ts; setClock(wibHour()); }
      if (ts - lastPaint > 33) { lastPaint = ts; setTick((n) => (n + 1) % 1e6); }
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, [paused, sim]);

  return { actors: sim.actors, t: sim.time, clock };
}

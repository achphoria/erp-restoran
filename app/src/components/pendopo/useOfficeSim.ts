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
  speech: string | null; speechUntil: number;               // gelembung ucapan (teks)
  anim: { type: Anim; start: number; dur: number } | null;  // gerakan sesaat (lompat, joget, dll.)
  nextIdle: number; pokes: number[]; locked: boolean;        // locked = sedang ngobrol dengan Juragan
  faceUntil: number;                                         // hadap sementara (saat diajak bicara)
}

export type Anim = 'jump' | 'cheer' | 'spin' | 'stretch' | 'dance' | 'look' | 'nod' | 'think' | 'flex' | 'yawn' | 'eat';
export type ChatEvent = 'open' | 'close' | 'thinking' | 'answered' | 'pending' | 'executed' | 'rejected';

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

// kalimat khas tiap karakter (untuk obrolan antar agent & saat dicolek)
const LINES: Record<AgentId, string[]> = {
  semar: ['Piye kabare, Le?', 'Sing sabar, rejeki ora bakal ketuker', 'Laporan hari ini sudah siap?', 'Ojo dumeh, tetap rendah hati ya', 'Juragan senang, kita tenang'],
  gareng: ['Es kopi susu laris manis hari ini!', 'Setoran kasir pas, nggak selisih', 'Jam 12 nanti pasti ramai', 'Gimana kalau bikin paket hemat?', 'Struk sudah kurekap semua'],
  petruk: ['Stok gula tinggal sedikit lho', 'PO ke supplier sudah kusiapkan', 'Batch susu hampir expired!', 'Gudang rapi jali 📦', 'Harga cabai naik lagi…'],
  bagong: ['HPP menu naik, waduh 😬', 'Laba bulan ini lumayan 💰', 'Tagihan supplier sudah lunas', 'Aku lapar… ada pisang goreng? 🍌', 'Angkanya cocok sampai rupiah terakhir'],
  bima: ['Ada void yang mencurigakan!', 'Opname cocok, aman', 'Semua transaksi kupantau', 'Jangan coba-coba curang 💪', 'CCTV aman terkendali'],
};
const REPLIES = ['Siap! 👍', 'Mantap 😄', 'Waduh 😅', 'Wah, iya ya 🤔', 'Haha bisa aja 😂', 'Nanti kuurus ✍️', 'Setuju!'];
const POKE: Record<AgentId, string[]> = {
  semar: ['Mbegegeg ugeg-ugeg… hmel-hmel 😌', 'Dalem, Juragan? 🙏', 'Eh, ada apa, Le?'],
  gareng: ['Eh, kaget! 😳', 'Kasir aman, Juragan!', 'Hehe, geli 🤭'],
  petruk: ['Siap, Juragan! Gudang beres 📦', 'Hidungku jangan dicolek 😆', 'Lagi ngitung stok nih!'],
  bagong: ['Duitnya pas, nggak kurang nggak lebih 🧮', 'Jangan ganggu, lagi ngitung! 😤', 'Ada makanan? 🍌'],
  bima: ['Tidak ada yang lolos dari mataku! 🔍', 'Hmm? 😠', 'Siap jaga! 💪'],
};
const MEET_LINES = ['Target minggu ini naik 10%!', 'Promo akhir pekan jalan ya', 'Stok aman untuk 3 hari', 'Laporan kemarin sudah rapi', 'Ada ide menu baru?', 'Mari kita mulai, Bismillah'];

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
      speech: null, speechUntil: 0, anim: null, nextIdle: rnd(3, 9), pokes: [], locked: false, faceUntil: 0,
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

  chats: { a: Actor; b: Actor; turns: [Actor, string][]; idx: number; next: number }[] = [];
  confettiAt = -10;
  meetNext = 2;

  get(id: AgentId) { return this.actors.find((a) => a.id === id)!; }
  say(a: Actor, text: string, dur = 3) { a.speech = text; a.speechUntil = this.time + dur; }
  play(a: Actor, type: Anim, dur: number) { a.anim = { type, start: this.time, dur }; }

  // klik karakter: lompat & menjawab; dicolek 3x cepat = pusing
  poke(id: AgentId) {
    const a = this.get(id);
    if (a.gone) return;
    a.pokes = [...a.pokes.filter((t) => this.time - t < 3), this.time];
    if (a.pokes.length >= 3) { a.pokes = []; this.play(a, 'spin', 1.1); this.say(a, 'Waduh, pusing, Juragan! 😵', 2.6); return; }
    if (a.status === 'tidur') { this.play(a, 'jump', 0.7); this.say(a, 'Eh! Kebangun 😳', 2.4); return; }
    this.play(a, 'jump', 0.7);
    this.say(a, pick(POKE[a.id]), 2.8);
  }

  // sapaan saat Dashboard dibuka
  greet() {
    this.actors.forEach((a, i) => { if (!a.gone && a.status !== 'tidur') { a.wave = this.time + 1.6 + i * 0.15; } });
    const semar = this.get('semar');
    if (!semar.gone) this.say(semar, semar.status === 'tidur' ? 'Hmm… sugeng rawuh, Juragan 😴' : 'Sugeng rawuh, Juragan! 🙏', 3.5);
  }

  // reaksi Semar terhadap jendela obrolan
  chat(ev: ChatEvent) {
    const semar = this.get('semar');
    const now = this.time;
    if (ev === 'open') {
      const wasAsleep = semar.status === 'tidur';
      semar.locked = true;
      if (semar.gone) { semar.gone = false; semar.opacity = 1; semar.x = SPOTS.pintu[0].x; semar.y = SPOTS.pintu[0].y; }
      this.endChatsOf(semar);
      this.assign(semar, { spot: SPOTS.home.semar, label: 'ngobrol dengan Juragan', emoji: '💬', status: 'kerja', dur: [1e6, 1e6] }, now);
      semar.wave = now + 1.4;
      this.say(semar, wasAsleep ? 'Eh, Juragan! Dalem 🙏' : 'Dalem, Juragan? 🙏', 3);
    } else if (ev === 'close') {
      semar.locked = false; semar.until = now + 1;
      this.say(semar, 'Monggo, Juragan. Saya kerja lagi ya 🙏', 2.5);
    } else if (ev === 'thinking') {
      this.play(semar, 'think', 60); semar.label = 'menimbang jawaban…'; semar.emoji = '🤔'; semar.emojiUntil = now + 60;
    } else if (ev === 'answered') {
      this.play(semar, 'jump', 0.7); semar.label = 'ngobrol dengan Juragan'; semar.emojiUntil = now;
      this.say(semar, pick(['Sampun, Juragan! ✨', 'Monggo dibaca, Juragan 📜', 'Sudah saya jawab 😌']), 2.6);
    } else if (ev === 'pending') {
      this.play(semar, 'jump', 0.7); semar.holding = 'clipboard'; semar.label = 'menunggu persetujuan Juragan';
      this.say(semar, 'Ada usulan, mohon dicek 📜', 3.2);
    } else if (ev === 'executed') {
      semar.holding = null; semar.label = 'ngobrol dengan Juragan';
      this.confettiAt = now;
      this.actors.forEach((a, i) => { if (!a.gone) { a.anim = { type: 'cheer', start: now + i * 0.08, dur: 1.6 }; } });
      this.say(semar, 'Matur nuwun, Juragan! 🎉', 3);
      const mate = pick(this.actors.filter((a) => a.id !== 'semar' && !a.gone));
      if (mate) this.say(mate, pick(['Hore! 🎉', 'Beres! 👏', 'Mantap, Juragan! 🙌']), 2.5);
    } else if (ev === 'rejected') {
      semar.holding = null; semar.label = 'ngobrol dengan Juragan';
      this.play(semar, 'nod', 1); this.say(semar, 'Nggih, Juragan. Kita batalkan 🙏', 2.6);
    }
  }

  endChatsOf(a: Actor) { this.chats = this.chats.filter((c) => c.a !== a && c.b !== a); }

  // mulai obrolan dua karakter (pendatang a, tuan rumah b)
  startChat(a: Actor, b: Actor) {
    if (this.chats.some((c) => c.a === b || c.b === b || c.a === a)) return;
    const turns: [Actor, string][] = [[a, pick(LINES[a.id])], [b, pick(LINES[b.id])], [a, pick(REPLIES)]];
    if (Math.random() < 0.5) turns.push([b, pick(REPLIES)]);
    this.chats.push({ a, b, turns, idx: 0, next: this.time + 0.4 });
  }

  updateChats(now: number) {
    for (const c of this.chats) {
      const dir = Math.sign(c.b.x - c.a.x) || 1;
      if (!c.a.path.length) c.a.face = dir as 1 | -1;
      if (!c.b.path.length && !c.b.locked) { c.b.face = -dir as 1 | -1; c.b.faceUntil = now + 2; }
      if (now < c.next) continue;
      const [who, text] = c.turns[c.idx++];
      this.say(who, text, 2.2);
      if (Math.random() < 0.4) this.play(who === c.a ? c.b : c.a, 'nod', 1.1);
      c.next = now + 2.1;
    }
    this.chats = this.chats.filter((c) => c.idx < c.turns.length || now < c.next);
  }

  // gerakan iseng saat diam
  idle(a: Actor, h: number) {
    const night = h >= 19 || h < 6;
    if (a.status === 'tidur') { a.emoji = '💤'; a.emojiUntil = this.time + 3; return; }
    if (a.spot?.id === 'radio-1') { this.play(a, 'dance', 3.2); this.say(a, pick(['♪ campursari ♪', '♪ nang ning nong ♪', 'Lagunya enak 🎶']), 2.4); return; }
    if (a.status === 'ronda') { this.play(a, 'look', 2.2); if (Math.random() < 0.5) this.say(a, pick(['Siskamling! 🔦', 'Aman terkendali', 'Thok thok thok… 🔔']), 2.4); return; }
    const sig: Record<AgentId, [Anim, string | null]> = {
      semar: ['think', 'Hmm… 🤔'], gareng: ['look', null], petruk: ['nod', '…tiga, empat, lima 📦'],
      bagong: ['eat', 'Nyam 🍌'], bima: ['flex', '💪'],
    };
    const r = Math.random();
    if (night && r < 0.3) { this.play(a, 'yawn', 2); a.emoji = '🥱'; a.emojiUntil = this.time + 2; return; }
    if (a.holding === 'cup' && r < 0.5) { this.play(a, 'nod', 1.2); a.emoji = '☕'; a.emojiUntil = this.time + 2; return; }
    if (r < 0.35) { const [type, text] = sig[a.id]; this.play(a, type, 2.2); if (text && Math.random() < 0.6) this.say(a, text, 2); return; }
    this.play(a, pick<Anim>(['stretch', 'look', 'nod', 'look']), 1.8);
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
      } else if (!a.locked && now >= a.until) {
        this.endChatsOf(a);
        this.assign(a, this.planFor(a, h), now);
      } else if (!reduced && !a.anim && now >= a.nextIdle && !this.chats.some((c) => c.a === a || c.b === a)) {
        this.idle(a, h);
        a.nextIdle = now + rnd(6, 13);
      }
      // baru tiba di meja rekan -> ngobrol
      if (!a.path.length && a.spot?.id.startsWith('visit-') && !this.chats.some((c) => c.a === a)) {
        const host = this.actors.find((o) => VISIT[SPOTS.home[o.id].id]?.id === a.spot!.id);
        if (host && !host.gone && !host.path.length && host.status !== 'tidur') this.startChat(a, host);
      }
      if (a.anim && now > a.anim.start + a.anim.dur) a.anim = null;
      if (a.faceUntil && now > a.faceUntil && !a.path.length && a.spot) { a.face = a.spot.face; a.faceUntil = 0; }

      const atHome = !a.path.length && a.spot?.id === SPOTS.home[a.id].id;
      a.typing = !reduced && atHome && a.status !== 'tidur' && a.pose === 'desk';
      if (now >= a.blinkAt) { a.blinkUntil = now + 0.13; a.blinkAt = now + rnd(2.4, 5.5); }
      // gelembung emoji muncul lagi sesekali
      if (!a.path.length && a.status !== 'pulang' && now > a.emojiUntil + 9) a.emojiUntil = now + 3;
    }
    this.updateChats(now);
    // rapat pagi: bergiliran bicara, yang lain mengangguk
    const meeting = this.actors.filter((a) => a.status === 'rapat' && !a.path.length);
    if (meeting.length >= 3 && now >= this.meetNext) {
      const sp = pick(meeting);
      this.say(sp, pick(MEET_LINES), 2.4);
      meeting.filter((m) => m !== sp && !m.anim).forEach((m) => { if (Math.random() < 0.6) this.play(m, 'nod', 1.2); });
      this.meetNext = now + rnd(2.6, 3.6);
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

  return { sim, actors: sim.actors, t: sim.time, clock };
}

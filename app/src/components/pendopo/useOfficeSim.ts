import { useEffect, useState } from 'react';
import { AGENTS, CORRIDOR_Y, LAPS, SPOTS, type AgentId, type Pose, type Spot } from './world';

// Simulasi "hidup" kantor Pendopo. Murni visual di browser.
// Aturan: agent tidak pura-pura kerja. Yang bekerja hanya Semar saat diajak ngobrol (ke meja kerja);
// selebihnya nongkrong main gaple & kartu, nobar Ultraman vs Godzilla, kegiatan iseng, tidur, takut pocong.
// Uji cepat lewat URL: ?jam=21.5 (paksa jam WIB) dan ?hidup=cepat (timer 7x lebih cepat).

export type Status = 'kerja' | 'siaga' | 'nongkrong' | 'nobar' | 'iseng' | 'istirahat' | 'tidur' | 'takut';
type Holding = 'clipboard' | 'cup' | 'kentongan' | null;
export type Anim = 'jump' | 'cheer' | 'spin' | 'stretch' | 'dance' | 'look' | 'nod' | 'think' | 'flex' | 'yawn' | 'eat' | 'scared' | 'slam';
export type ChatEvent = 'open' | 'close' | 'thinking' | 'answered' | 'pending' | 'executed' | 'rejected';
export interface Show { kind: 'kaiju' | 'pocong'; start: number; dur: number }

export interface Actor {
  id: AgentId; x: number; y: number; face: 1 | -1; pose: Pose;
  path: { x: number; y: number }[]; walk: number; spot: Spot | null;
  label: string; emoji: string | null; emojiUntil: number; status: Status;
  until: number; typing: boolean; holding: Holding; blinkAt: number; blinkUntil: number;
  opacity: number; wave: number; run: boolean;
  speech: string | null; speechUntil: number;               // gelembung ucapan (teks)
  anim: { type: Anim; start: number; dur: number } | null;  // gerakan sesaat
  act: Anim | null; actSay: string | null;                   // gerakan khas kegiatan saat ini
  nextIdle: number; pokes: number[]; locked: boolean;        // locked = sedang ngobrol dengan Juragan
}

interface Plan {
  spot: Spot; label: string; emoji: string | null; status: Status; dur: [number, number];
  holding?: Holding; act?: Anim; say?: string; path?: { x: number; y: number }[]; run?: boolean;
}

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
const isNight = (h: number) => h >= 22 || h < 5;

// ---------------------------------------------------------------- kalimat
const CASUAL: Record<AgentId, string[]> = {
  semar: ['Sing sabar, rejeki ora bakal ketuker', 'Ojo dumeh, Le', 'Kapan Juragan manggil saya ya? 🙏', 'Mbegegeg ugeg-ugeg… 😌'],
  gareng: ['Kapan aku diaktifkan AI ya? 🤖', 'Kartumu jelek, Truk 😆', 'Tadi mimpi jadi kasir bintang lima', 'Aku nunggu giliran kerja nih'],
  petruk: ['Nunggu dipanggil Juragan nih', 'Hidungku ini bawa hoki lho 😎', 'Gaple kok kalah terus…', 'Kapan ya aku ngurus gudang beneran'],
  bagong: ['Lapar… ada pisang goreng? 🍌', 'Bayar kopinya siapa nih?', 'Aku jago ngitung, jago kartu juga!', 'Ngantuk… 😪'],
  bima: ['Jangan curang ya, aku awasi 👀', 'Siapa yang ngumpetin kartu?', 'Yang kalah push-up! 💪', 'Aku siap jaga kapan saja'],
};
const GAME = ['Gaple!', 'Kartu mati!', 'Balak enam! 🎴', 'Giliranmu!', 'Pass dulu ah', 'Curang ki! 😤', 'Hehe, kartuku bagus', 'Tak tutup!', 'Kok gitu sih 😆'];
const WIN = ['Gaple! Menang! 🎉', 'Juara gaple sekampung! 🏆', 'Yang kalah bayar kopi! ☕'];
const LOSE = ['Yah… kalah lagi 😩', 'Besok balas dendam!', 'Kopinya aku yang bayar deh 😔'];
const NOBAR = ['Ayo Ultraman!! ⚡', 'Hajar, hajar!', 'Wih Godzilla kuat banget 😱', 'Sinar spesium!! ✨', 'Wkwk kena!', 'Gedungnya ambruk tuh 😆', 'Ultraman lampunya kedip-kedip!'];
const SCARED = ['POCOOONG!! 😱', 'Ampun, Mbah! 🙏', 'Lariii!! 🏃', 'Mamaaak! 😭', 'Itu apa di jendela?! 😨'];
const POKE: Record<AgentId, string[]> = {
  semar: ['Mbegegeg ugeg-ugeg… hmel-hmel 😌', 'Dalem, Juragan? 🙏', 'Eh, ada apa, Le?'],
  gareng: ['Eh, kaget! 😳', 'Aktifkan aku dong, Juragan! 🤖', 'Hehe, geli 🤭'],
  petruk: ['Hidungku jangan dicolek 😆', 'Siap, Juragan! Tapi belum ada kerjaan 😅', 'Lagi main gaple nih!'],
  bagong: ['Jangan ganggu, kartuku bagus! 😤', 'Ada makanan? 🍌', 'Duitnya pas, nggak kurang nggak lebih 🧮'],
  bima: ['Tidak ada yang lolos dari mataku! 🔍', 'Hmm? 😠', 'Siap jaga! 💪'],
};
// kegiatan iseng gaje
const ISENG: { label: string; emoji: string; act: Anim; say?: string; only?: AgentId }[] = [
  { label: 'main HP sambil ketawa sendiri', emoji: '📱', act: 'nod', say: 'Wkwkwk 🤣' },
  { label: 'nyanyi-nyanyi sendiri', emoji: '🎤', act: 'dance', say: '♪ la la la ♪' },
  { label: 'latihan silat', emoji: '🥋', act: 'spin', say: 'Hiyaaat! 🥋' },
  { label: 'ngelamun', emoji: '💭', act: 'think', say: 'Hmm… makan apa ya nanti' },
  { label: 'nyari sinyal', emoji: '📶', act: 'stretch', say: 'Sinyalnya mana ya…' },
  { label: 'ngitung cicak di dinding', emoji: '🦎', act: 'look', say: 'Satu… dua… cicaknya kabur!' },
  { label: 'push-up', emoji: '💪', act: 'flex', say: 'Sembilan… sepuluh! 💪', only: 'bima' },
  { label: 'ngemil kerupuk', emoji: '🍘', act: 'eat', say: 'Kriuk kriuk', only: 'bagong' },
];

// ---------------------------------------------------------------- mesin simulasi
class OfficeSim {
  actors: Actor[] = [];
  reserved: Record<string, AgentId> = {};
  time = 0;
  confettiAt = -10;
  show: Show | null = null;
  nextShow = rnd(8, 14) * TIME_SCALE;
  gameNext = 2;
  roundNext = 20;
  showNext = 0;
  scaredDone = false;

  constructor() {
    const { h } = wibHour();
    this.actors = AGENTS.map((d) => ({
      id: d.id, x: 0, y: 0, face: 1, pose: 'stand', path: [], walk: 0, spot: null, label: '', emoji: null, emojiUntil: 0,
      status: 'nongkrong', until: 0, typing: false, holding: null, blinkAt: rnd(1, 4), blinkUntil: 0, opacity: 1, wave: 0, run: false,
      speech: null, speechUntil: 0, anim: null, act: null, actSay: null, nextIdle: rnd(3, 9), pokes: [], locked: false,
    }));
    // posisi awal: langsung di tempat (tanpa berjalan)
    this.actors.forEach((a) => { this.assign(a, this.planFor(a, h), 0, true); a.emojiUntil = rnd(1, 3); });
  }

  get(id: AgentId) { return this.actors.find((a) => a.id === id)!; }
  free(s: Spot, id: AgentId) { return !this.reserved[s.id] || this.reserved[s.id] === id; }
  freeOf(list: Spot[], id: AgentId) {
    const opts = list.filter((s) => this.free(s, id));
    return opts.length ? pick(opts) : null;
  }
  say(a: Actor, text: string, dur = 2.6) { a.speech = text; a.speechUntil = this.time + dur; }
  play(a: Actor, type: Anim, dur: number) { a.anim = { type, start: this.time, dur }; }
  showOn(kind: Show['kind']) { return !!this.show && this.show.kind === kind && this.time < this.show.start + this.show.dur; }

  // pilih kegiatan berikutnya (agent nganggur)
  planFor(a: Actor, h: number): Plan {
    const sit = (label: string, status: Status = 'nongkrong'): Plan | null => {
      const s = this.freeOf(SPOTS.nongkrong, a.id);
      return s ? { spot: s, label, emoji: '🎴', status, dur: [25, 60] } : null;
    };
    if (this.showOn('kaiju') && Math.random() < 0.85) {
      const n = this.freeOf(SPOTS.nobar, a.id);
      const left = this.show!.start + this.show!.dur - this.time;
      if (n) return { spot: n, label: 'nobar Ultraman vs Godzilla', emoji: '📺', status: 'nobar', dur: [left, left + 1], act: 'cheer' };
    }
    if (isNight(h)) {
      if (Math.random() < 0.55) {
        const t = this.freeOf(SPOTS.tikar, a.id);
        if (t) return { spot: t, label: 'tidur di tikar', emoji: '💤', status: 'tidur', dur: [40, 90] };
        const s = this.freeOf(SPOTS.nongkrong, a.id);
        if (s) return { spot: s, label: 'ketiduran di lincak', emoji: '💤', status: 'tidur', dur: [40, 90] };
      }
      return sit('begadang main kartu') ?? { spot: SPOTS.iseng[0], label: 'begadang', emoji: '🌙', status: 'iseng', dur: [15, 25] };
    }
    if (h >= 12 && h < 13) {
      const d = this.freeOf(SPOTS.dapur, a.id);
      if (d && Math.random() < 0.45) return { spot: d, label: 'masak mie rebus', emoji: '🍜', status: 'istirahat', dur: [10, 18], act: 'eat' };
      return sit('makan nasi bungkus', 'istirahat') ?? { spot: SPOTS.iseng[1], label: 'makan sambil berdiri', emoji: '🍛', status: 'istirahat', dur: [10, 18] };
    }
    const r = Math.random();
    const afternoon = h >= 13 && h < 15.5;
    if (afternoon && r < 0.12) { const t = this.freeOf(SPOTS.tikar, a.id); if (t) return { spot: t, label: 'tidur siang', emoji: '💤', status: 'tidur', dur: [20, 40] }; }
    if (r < 0.5) { const p = sit(pick(['main gaple', 'main kartu remi', 'main gaple sambil ngopi'])); if (p) return p; }
    if (r < 0.62) {
      return { spot: { id: 'lap', x: LAPS[0].x, y: LAPS[0].y, pose: 'stand', face: 1 }, label: 'lari keliling kantor', emoji: '🏃', status: 'iseng', dur: [2, 4],
        path: [...LAPS], run: true };
    }
    if (r < 0.8) {
      const opts = ISENG.filter((x) => !x.only || x.only === a.id);
      const it = pick(opts);
      const s = this.freeOf(SPOTS.iseng, a.id);
      if (s) return { spot: s, label: it.label, emoji: it.emoji, status: 'iseng', dur: [8, 16], act: it.act, say: it.say };
    }
    if (r < 0.88) { const d = this.freeOf(SPOTS.dapur, a.id); if (d) return { spot: d, label: pick(['bikin kopi tubruk', 'goreng pisang', 'nyolong kerupuk 🤫']), emoji: '☕', status: 'istirahat', dur: [8, 14], holding: 'cup', act: 'eat' }; }
    if (r < 0.95) { const radio = this.freeOf(SPOTS.radio, a.id); if (radio) return { spot: radio, label: 'joget di depan radio', emoji: '📻', status: 'iseng', dur: [8, 14], act: 'dance', say: '♪ nang ning nong ♪' }; }
    const j = this.freeOf(SPOTS.jendela, a.id);
    if (j) return { spot: j, label: 'ngelamun di jendela', emoji: '💭', status: 'iseng', dur: [6, 10], act: 'think' };
    return sit('main gaple') ?? { spot: SPOTS.iseng[2], label: 'bengong', emoji: '😶', status: 'iseng', dur: [6, 10] };
  }

  route(a: Actor, s: Spot) {
    const pts: { x: number; y: number }[] = [];
    if (Math.abs(a.y - CORRIDOR_Y) > 4 && Math.abs(a.x - s.x) > 8) pts.push({ x: a.x, y: CORRIDOR_Y });
    if (Math.abs(a.x - s.x) > 8) pts.push({ x: s.x, y: pts.length ? CORRIDOR_Y : a.y });
    pts.push({ x: s.x, y: s.y });
    return pts;
  }

  assign(a: Actor, p: Plan, now: number, instant = false) {
    if (a.spot) delete this.reserved[a.spot.id];
    if (p.spot.id !== 'lap') this.reserved[p.spot.id] = a.id;
    // Semar yang belum diajak ngobrol = siaga (tidak pura-pura kerja)
    const status: Status = a.id === 'semar' && !a.locked && ['nongkrong', 'iseng', 'nobar'].includes(p.status) ? 'siaga' : p.status;
    a.spot = p.spot; a.label = p.label; a.status = status; a.holding = p.holding ?? null;
    a.act = p.act ?? null; a.actSay = p.say ?? null; a.run = !!p.run;
    a.until = now + rnd(p.dur[0], p.dur[1]) * TIME_SCALE;
    a.emoji = p.emoji; a.emojiUntil = now + 3.5;
    if (instant) {
      a.x = p.spot.x; a.y = p.spot.y; a.path = []; a.pose = p.spot.pose; a.face = p.spot.face;
    } else {
      a.path = p.path ? [...this.route(a, { ...p.spot, x: p.path[0].x, y: p.path[0].y }), ...p.path.slice(1)] : this.route(a, p.spot);
      a.pose = 'stand';
    }
  }

  // ---------------------------------------------------------------- interaksi
  poke(id: AgentId) {
    const a = this.get(id);
    a.pokes = [...a.pokes.filter((t) => this.time - t < 3), this.time];
    if (a.pokes.length >= 3) { a.pokes = []; this.play(a, 'spin', 1.1); this.say(a, 'Waduh, pusing, Juragan! 😵', 2.6); return; }
    if (a.status === 'tidur') { this.play(a, 'jump', 0.7); this.say(a, 'Eh! Kebangun 😳', 2.4); return; }
    this.play(a, 'jump', 0.7);
    this.say(a, pick(POKE[a.id]), 2.8);
  }

  greet() {
    this.actors.forEach((a, i) => { if (a.status !== 'tidur') a.wave = this.time + 1.6 + i * 0.15; });
    const semar = this.get('semar');
    this.say(semar, semar.status === 'tidur' ? 'Hmm… sugeng rawuh, Juragan 😴' : 'Sugeng rawuh, Juragan! 🙏', 3.5);
  }

  // Semar diajak ngobrol: ke meja kerja; ditutup: kembali nongkrong
  chat(ev: ChatEvent) {
    const semar = this.get('semar');
    const now = this.time;
    if (ev === 'open') {
      const wasAsleep = semar.status === 'tidur';
      semar.locked = true;
      this.assign(semar, { spot: SPOTS.meja.semar, label: 'ngobrol dengan Juragan', emoji: '💬', status: 'kerja', dur: [1e6, 1e6] }, now);
      semar.wave = now + 1.4;
      this.say(semar, wasAsleep ? 'Eh, Juragan! Dalem 🙏' : 'Dalem, Juragan? Saya ke meja dulu 🙏', 3);
      const mate = pick(this.actors.filter((a) => a !== semar && a.status !== 'tidur'));
      if (mate) this.say(mate, pick(['Cie, Semar dipanggil Juragan 😆', 'Semangat, Mar!', 'Aku kapan dipanggil? 🥺']), 2.6);
    } else if (ev === 'close') {
      semar.locked = false; semar.until = now + 1.5; semar.holding = null;
      this.say(semar, 'Monggo, Juragan. Saya siaga di lincak ya 🙏', 2.5);
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
      this.actors.forEach((a, i) => { if (a.status !== 'tidur') a.anim = { type: 'cheer', start: now + i * 0.08, dur: 1.6 }; });
      this.say(semar, 'Matur nuwun, Juragan! 🎉', 3);
      const mate = pick(this.actors.filter((a) => a !== semar));
      if (mate) this.say(mate, pick(['Hore! 🎉', 'Beres! 👏', 'Mantap, Juragan! 🙌']), 2.5);
    } else if (ev === 'rejected') {
      semar.holding = null; semar.label = 'ngobrol dengan Juragan';
      this.play(semar, 'nod', 1); this.say(semar, 'Nggih, Juragan. Kita batalkan 🙏', 2.6);
    }
  }

  // gerakan iseng saat diam di tempat
  idle(a: Actor, h: number) {
    if (a.status === 'tidur') { a.emoji = '💤'; a.emojiUntil = this.time + 3; return; }
    if (a.locked) return;
    if (a.act && Math.random() < 0.7) { this.play(a, a.act, a.act === 'spin' ? 1.1 : 2.4); if (a.actSay && Math.random() < 0.6) this.say(a, a.actSay, 2.2); return; }
    if (h >= 19 && Math.random() < 0.25) { this.play(a, 'yawn', 2); a.emoji = '🥱'; a.emojiUntil = this.time + 2; return; }
    this.play(a, pick<Anim>(['stretch', 'look', 'nod', 'look']), 1.8);
  }

  // permainan gaple di meja nongkrong
  updateGame(now: number) {
    const players = this.actors.filter((a) => a.spot?.id.startsWith('nk-') && !a.path.length && a.status !== 'tidur' && !a.locked);
    if (players.length < 2) {
      if (players.length === 1 && now >= this.gameNext) { this.say(players[0], pick(['Ayo main, kurang orang nih!', 'Kocok kartu dulu ah 🃏']), 2.2); this.gameNext = now + rnd(8, 14); }
      return;
    }
    if (now >= this.roundNext) {
      const win = pick(players);
      this.play(win, 'cheer', 1.6); this.say(win, pick(WIN), 2.8);
      const lose = pick(players.filter((p) => p !== win));
      if (lose) { this.play(lose, 'yawn', 1.6); setTimeout(() => this.say(lose, pick(LOSE), 2.4), 900); }
      this.roundNext = now + rnd(18, 30); this.gameNext = now + 3.5;
      return;
    }
    if (now >= this.gameNext) {
      const p = pick(players);
      this.play(p, 'slam', 0.6);
      this.say(p, Math.random() < 0.65 ? pick(GAME) : pick(CASUAL[p.id]), 2.2);
      players.filter((o) => o !== p && !o.anim).forEach((o) => { if (Math.random() < 0.35) this.play(o, 'nod', 1); });
      this.gameNext = now + rnd(2.4, 3.8);
    }
  }

  // tontonan di jendela: siang Ultraman vs Godzilla, malam pocong
  updateShows(now: number, h: number) {
    if (this.show && now > this.show.start + this.show.dur) {
      this.show = null;
      this.nextShow = now + (isNight(h) || h >= 19 ? rnd(30, 60) : rnd(45, 85)) * TIME_SCALE;
    }
    if (!this.show && now >= this.nextShow) {
      const night = h >= 19 || h < 5.5;
      this.show = night ? { kind: 'pocong', start: now, dur: 7 } : { kind: 'kaiju', start: now, dur: 16 };
      this.scaredDone = false; this.showNext = now + 1.5;
      if (!night) {
        this.actors.filter((a) => !a.locked && a.status !== 'tidur').forEach((a) => {
          const n = this.freeOf(SPOTS.nobar, a.id);
          if (n && Math.random() < 0.85) this.assign(a, { spot: n, label: 'nobar Ultraman vs Godzilla', emoji: '📺', status: 'nobar', dur: [16, 17], act: 'cheer' }, now);
        });
        const first = this.actors.find((a) => !a.locked && a.status === 'nobar');
        if (first) this.say(first, 'Eh eh, ada Ultraman lawan Godzilla!! 📺', 2.6);
      }
    }
    if (!this.show) return;
    if (this.show.kind === 'kaiju' && now >= this.showNext) {
      const fans = this.actors.filter((a) => a.status === 'nobar' && !a.path.length);
      if (fans.length) { const f = pick(fans); this.play(f, 'cheer', 1.2); this.say(f, pick(NOBAR), 2); }
      this.showNext = now + rnd(1.8, 3);
    }
    if (this.show.kind === 'pocong' && !this.scaredDone && now >= this.show.start + 1.4) {
      this.scaredDone = true;
      this.actors.forEach((a) => {
        if (a.locked) { this.say(a, 'Tenang, Juragan. Cuma pocong lewat 😌', 2.6); return; }
        if (a.status === 'tidur') { if (Math.random() < 0.35) { this.play(a, 'jump', 0.7); this.say(a, 'Hah?! 😨', 2); } return; }
        this.play(a, 'scared', 2.4);
        this.say(a, pick(SCARED), 2.4);
        a.emoji = '😱'; a.emojiUntil = now + 3;
        if (Math.random() < 0.5) {
          const far = this.freeOf([...SPOTS.dapur, SPOTS.iseng[3], SPOTS.iseng[0]], a.id);
          if (far) setTimeout(() => this.assign(a, { spot: far, label: 'kabur ketakutan', emoji: '😱', status: 'takut', dur: [8, 12], run: true }, this.time), 600);
        }
      });
    }
  }

  step(dt: number, h: number, reduced: boolean) {
    this.time += dt;
    const now = this.time;
    const base = (isNight(h) ? 0.8 : 1) * 105;
    for (const a of this.actors) {
      if (a.path.length) {
        const target = a.path[0];
        const dx = target.x - a.x, dy = target.y - a.y, dist = Math.hypot(dx, dy);
        const stepLen = base * (a.run ? 1.8 : 1) * dt;
        if (Math.abs(dx) > 1) a.face = dx > 0 ? 1 : -1;
        if (reduced || dist <= stepLen) {
          a.x = target.x; a.y = target.y; a.path.shift();
          if (!a.path.length && a.spot) {
            a.pose = a.spot.pose; a.face = a.spot.face; a.walk = 0; a.emojiUntil = now + 3; a.run = false;
            if (a.act && !reduced) { this.play(a, a.act, a.act === 'spin' ? 1.1 : 2.4); if (a.actSay) this.say(a, a.actSay, 2.2); }
            a.nextIdle = now + rnd(4, 8);
          }
        } else {
          a.x += (dx / dist) * stepLen; a.y += (dy / dist) * stepLen;
          a.walk = (a.walk + dt * (a.run ? 4.2 : 2.6)) % 1;
        }
      } else if (!a.locked && now >= a.until) {
        this.assign(a, this.planFor(a, h), now);
      } else if (!reduced && !a.anim && now >= a.nextIdle) {
        this.idle(a, h);
        a.nextIdle = now + rnd(6, 13);
      }
      if (a.anim && now > a.anim.start + a.anim.dur) a.anim = null;
      // mengetik hanya saat benar-benar bekerja di meja kerja
      a.typing = !reduced && !a.path.length && a.status === 'kerja' && a.pose === 'desk';
      if (now >= a.blinkAt) { a.blinkUntil = now + 0.13; a.blinkAt = now + rnd(2.4, 5.5); }
      if (!a.path.length && now > a.emojiUntil + 9) a.emojiUntil = now + 3;
    }
    this.updateGame(now);
    this.updateShows(now, h);
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

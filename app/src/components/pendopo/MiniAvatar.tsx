import { LOOKS, Mascot } from './art';
import { AGENTS, type AgentId } from './world';

const TONE = Object.fromEntries(AGENTS.map((a) => [a.id, a.tone])) as Record<AgentId, string>;

// avatar kecil: kepala & badan karakter
export default function MiniAvatar({ id, size }: { id: AgentId; size: number }) {
  const L = LOOKS[id];
  const top = -L.h - 34;
  return (
    <svg width={size} height={size} viewBox={`${-L.w * 0.7} ${top} ${L.w * 1.4} ${L.w * 1.4}`} className="pd-avatar" style={{ background: `${TONE[id]}1a` }}>
      <Mascot id={id} pose="stand" face={1} t={0} walk={0} />
    </svg>
  );
}

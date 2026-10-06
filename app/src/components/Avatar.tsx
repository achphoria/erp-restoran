// Foto profil, atau inisial nama bila belum ada foto
export default function Avatar({ name, src, size = 36 }: { name?: string | null; src?: string | null; size?: number }) {
  const initials = (name ?? '?').split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join('');
  return (
    <span className="avatar" style={{ width: size, height: size, fontSize: size * 0.38 }}>
      {src ? <img src={src} alt="" /> : initials}
    </span>
  );
}

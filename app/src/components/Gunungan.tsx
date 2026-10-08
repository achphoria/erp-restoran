// Gunungan (kayon) wayang: lambang SEMAR. Dipakai besar di landing page & halaman login.
export default function Gunungan({ className, tone = 'light' }: { className?: string; tone?: 'light' | 'shadow' }) {
  const body = tone === 'light' ? '#fff' : 'rgba(255,255,255,0.10)';
  const line = tone === 'light' ? '#1F7F72' : 'rgba(255,255,255,0.28)';
  return (
    <svg className={className} viewBox="10 4 44 52" aria-hidden="true">
      <path d="M32 7C36 13 44 20 48 29C51 36 51 44 47 50H17C13 44 13 36 16 29C20 20 28 13 32 7Z" fill={body} />
      <g fill="none" stroke={line} strokeWidth="1.6" strokeLinecap="round">
        <path d="M32 43V22" />
        <path d="M32 35C28 31.5 24.5 31.5 21.5 33.5M32 35C36 31.5 39.5 31.5 42.5 33.5" />
        <path d="M32 28C29 25 26.5 25 24.5 26M32 28C35 25 37.5 25 39.5 26" />
        <path d="M32 39C29.5 37 27 37 25 38M32 39C34.5 37 37 37 39 38" />
      </g>
      <path d="M27 50V44.5a5 5 0 0 1 10 0V50Z" fill={line} />
      <circle cx="32" cy="17" r="3.2" fill="#F7B733" />
      <rect x="19" y="50" width="26" height="4.5" rx="2.25" fill="#FC4A1A" />
    </svg>
  );
}

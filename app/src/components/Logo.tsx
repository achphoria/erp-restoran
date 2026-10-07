import { getAppName } from '../lib/brand';

// Logo: pakai logo perusahaan bila sudah diunggah, selain itu logo default aplikasi
export default function Logo({ src, size = 36, withName, subtitle, textClassName, name }: {
  src?: string | null; size?: number; withName?: boolean; subtitle?: string; textClassName?: string; name?: string | null;
}) {
  return (
    <span className="logo">
      <img
        src={src || `${import.meta.env.BASE_URL}favicon.svg`}
        alt=""
        width={size}
        height={size}
        style={{ borderRadius: size * 0.25, objectFit: src ? 'cover' : undefined }}
      />
      {withName && (
        <span className={`logo-text ${textClassName ?? ''}`}>
          <strong>{name || getAppName()}</strong>
          {subtitle && <small>{subtitle}</small>}
        </span>
      )}
    </span>
  );
}

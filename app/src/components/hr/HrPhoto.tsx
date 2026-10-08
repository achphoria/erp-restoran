import { useEffect, useState } from 'react';
import Avatar from '../Avatar';
import { hrFileUrl } from '../../lib/hr';

// Foto karyawan dari bucket privat (signed URL); tanpa foto = inisial
export default function HrPhoto({ path, name, size = 40 }: { path: string | null | undefined; name: string; size?: number }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    hrFileUrl(path).then((u) => { if (alive) setUrl(u); }).catch(() => undefined);
    return () => { alive = false; };
  }, [path]);
  return <Avatar name={name} src={url} size={size} />;
}

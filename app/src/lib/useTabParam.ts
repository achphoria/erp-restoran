import { useCallback } from 'react';
import { useSearchParams } from 'react-router-dom';

// Tab halaman disimpan di URL (?tab=...) supaya menu sidebar bisa membuka tab tertentu
export function useTabParam<T extends string>(fallback: T, allowed?: readonly T[]): [T, (tab: T) => void] {
  const [params, setParams] = useSearchParams();
  const raw = params.get('tab') as T | null;
  const tab = raw && (!allowed || allowed.includes(raw)) ? raw : fallback;
  const setTab = useCallback((t: T) => {
    setParams((p) => {
      const next = new URLSearchParams(p);
      next.set('tab', t);
      return next;
    }, { replace: true });
  }, [setParams]);
  return [tab, setTab];
}

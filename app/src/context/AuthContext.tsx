import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { rpc, supabase } from '../lib/supabase';
import { setCompanyName } from '../lib/brand';
import type { Outlet, Profile } from '../lib/types';
import type { ModuleKey } from '../lib/modules';

interface AuthState {
  session: Session | null;
  profile: Profile | null;
  loading: boolean;
  outlet: Outlet | null;
  setOutletId: (id: string) => void;
  /** true bila user punya salah satu permission yang diberikan */
  can: (permission: string | string[]) => boolean;
  /** modul aktif di perusahaan ini (Pengaturan -> Modul); modul inti selalu true */
  hasModule: (key: ModuleKey | ModuleKey[] | undefined) => boolean;
  refreshProfile: () => Promise<void>;
  /** pindah PT (grup usaha / mode support). null = kembali ke PT sendiri */
  switchCompany: (companyId: string | null) => Promise<void>;
  signOut: () => Promise<void>;
}

// diekspor untuk pratinjau/tes komponen dengan profil contoh
export const AuthContext = createContext<AuthState | null>(null);
const OUTLET_KEY = 'erp.outlet_id';

function readStoredOutlet() {
  try {
    return localStorage.getItem(OUTLET_KEY);
  } catch {
    return null;
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  const [outletId, setOutletIdState] = useState<string | null>(readStoredOutlet);

  const refreshProfile = useCallback(async () => {
    const data = await rpc<Profile | null>('sys_get_my_profile');
    setProfile(data);
    if (data) setCompanyName(data.company_name);
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data: sub } = supabase.auth.onAuthStateChange((_event, newSession) => setSession(newSession));
    return () => sub.subscription.unsubscribe();
  }, []);

  const userId = session?.user.id;
  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      if (!userId) {
        setProfile(null);
      } else {
        try {
          const data = await rpc<Profile | null>('sys_get_my_profile');
          if (!cancelled) setProfile(data);
          if (data) setCompanyName(data.company_name);
          // catat login ke log aktivitas (server mengabaikan duplikat dalam 30 menit)
          if (data) rpc('sys_log_login').catch(() => undefined);
        } catch {
          if (!cancelled) setProfile(null);
        }
      }
      if (!cancelled) setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [userId]);

  const switchCompany = useCallback(async (companyId: string | null) => {
    await rpc('sys_switch_company', { p_company_id: companyId });
    // outlet tersimpan milik PT lama: kembali ke outlet pertama PT tujuan
    setOutletIdState(null);
    try { localStorage.removeItem(OUTLET_KEY); } catch { /* abaikan */ }
    await refreshProfile();
  }, [refreshProfile]);

  const setOutletId = (id: string) => {
    setOutletIdState(id);
    try {
      localStorage.setItem(OUTLET_KEY, id);
    } catch {
      /* abaikan */
    }
  };

  const outlet = profile?.outlets.find((o) => o.id === outletId) ?? profile?.outlets[0] ?? null;

  const can = useCallback(
    (permission: string | string[]) =>
      !!profile &&
      (profile.permissions.includes('*') ||
        (Array.isArray(permission) ? permission : [permission]).some((p) => profile.permissions.includes(p))),
    [profile],
  );

  // salah satu modul aktif cukup; undefined = modul inti
  const hasModule = useCallback((key: ModuleKey | ModuleKey[] | undefined) => {
    if (!key) return true;
    const enabled = profile?.modules?.enabled;
    if (!enabled) return true;
    return (Array.isArray(key) ? key : [key]).some((k) => enabled.includes(k));
  }, [profile]);

  const signOut = async () => {
    await supabase.auth.signOut();
    setProfile(null);
  };

  return (
    <AuthContext.Provider
      value={{ session, profile, loading, outlet, setOutletId, can, hasModule, refreshProfile, switchCompany, signOut }}
    >
      {children}
    </AuthContext.Provider>
  );
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth harus dipakai di dalam AuthProvider');
  return ctx;
}

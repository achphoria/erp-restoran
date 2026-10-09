import { useMemo, useState } from 'react';
import { Save } from 'lucide-react';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { rpc } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { BUSINESS_TYPES, MODULE_BY_KEY, MODULE_KEYS, type ModuleKey } from '../../lib/modules';
import ModuleCards from './ModuleCards';

// Pengaturan -> Modul: owner menyalakan / mematikan modul kapan saja (data tidak dihapus)
export default function ModulesSettings() {
  const { profile, refreshProfile } = useAuth();
  const { toast, confirm } = useFeedback();
  const saved = useMemo(() => (profile?.modules?.enabled ?? MODULE_KEYS) as ModuleKey[], [profile]);
  const [value, setValue] = useState<ModuleKey[]>(saved);
  const [busy, setBusy] = useState(false);
  const dirty = [...value].sort().join() !== [...saved].sort().join();
  const turnedOff = saved.filter((k) => !value.includes(k));
  const type = BUSINESS_TYPES.find((t) => t.key === profile?.modules?.business_type);

  const save = async () => {
    if (turnedOff.length && !(await confirm({
      title: `Matikan ${turnedOff.length} modul?`,
      message: `${turnedOff.map((k) => MODULE_BY_KEY[k].name).join(', ')} akan disembunyikan dari menu semua user. Datanya tetap aman dan muncul lagi bila modul dinyalakan.`,
      confirmLabel: 'Simpan',
    }))) return;
    setBusy(true);
    try {
      const all = MODULE_KEYS.every((k) => value.includes(k));
      await rpc('sys_save_modules', { p_modules: all ? null : value });
      await refreshProfile();
      toast('Pengaturan modul disimpan', 'success');
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };

  return (
    <div className="grid">
      <div className="card">
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <div>
            <h2 style={{ margin: 0 }}>Modul yang dipakai</h2>
            <p className="muted small" style={{ margin: '4px 0 0' }}>
              Nyalakan hanya yang Anda perlukan supaya menu tetap ringkas. Modul yang dimatikan disembunyikan dari menu & hak akses role;
              <b> datanya tidak dihapus</b>. {type && <>Tipe usaha: {type.emoji} {type.name}.</>}
            </p>
          </div>
          <div className="row">
            <button type="button" className="btn-sm" onClick={() => setValue(MODULE_KEYS)}>Aktifkan semua</button>
            <button type="button" className="btn-primary" disabled={!dirty || busy} onClick={save}><Save size={16} /> {busy ? 'Menyimpan…' : 'Simpan'}</button>
          </div>
        </div>
      </div>
      <div className="card"><ModuleCards value={value} onChange={setValue} /></div>
    </div>
  );
}

import { useState } from 'react';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import type { MasterData } from './types';

// Label 5 kolom tambahan produk (Info 1–5 di template Excel), sesuai SOP masing-masing
export default function CustomFieldsTab(md: MasterData) {
  const { toast } = useFeedback();
  const [fields, setFields] = useState(() => [1, 2, 3, 4, 5].map((slot) => {
    const f = md.customFields.find((x) => x.slot === slot);
    return { slot, label: f?.label ?? '', is_active: f?.is_active ?? false };
  }));

  const save = async () => {
    try {
      const keep = fields.filter((f) => f.label.trim());
      await must(supabase.from('inv_item_custom_fields').delete().eq('company_id', md.companyId).not('slot', 'in', `(${keep.map((f) => f.slot).join(',') || 0})`));
      if (keep.length) {
        await must(supabase.from('inv_item_custom_fields').upsert(keep.map((f) => ({ company_id: md.companyId, slot: f.slot, label: f.label.trim(), is_active: f.is_active }))));
      }
      toast('Field tambahan disimpan');
      md.reload();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  return (
    <div className="card" style={{ maxWidth: 640 }}>
      <h2 style={{ marginBottom: 4 }}>Field Tambahan Produk</h2>
      <p className="muted small">Maksimal 5 kolom bebas, mis. "Merek", "Asal supplier", "Sertifikat halal". Tampil di form produk dan kolom Info 1–5 template Excel.</p>
      <div className="grid">
        {fields.map((f, i) => (
          <div key={f.slot} className="row" style={{ flexWrap: 'nowrap' }}>
            <span className="badge" style={{ width: 54, justifyContent: 'center' }}>Info {f.slot}</span>
            <input style={{ flex: 1 }} placeholder="Label (kosong = tidak dipakai)" value={f.label}
              onChange={(e) => setFields(fields.map((x, j) => (j === i ? { ...x, label: e.target.value, is_active: e.target.value ? x.is_active || !x.label : false } : x)))} />
            <label className="switch"><input type="checkbox" checked={f.is_active} disabled={!f.label.trim()}
              onChange={(e) => setFields(fields.map((x, j) => (j === i ? { ...x, is_active: e.target.checked } : x)))} /><span>Aktif</span></label>
          </div>
        ))}
        <button className="btn-primary" style={{ justifySelf: 'start' }} onClick={save}>Simpan</button>
      </div>
    </div>
  );
}

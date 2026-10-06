import { useEffect, useState } from 'react';
import Modal from './Modal';
import { rpc } from '../lib/supabase';
import { errorMessage, formatNumber } from '../lib/format';
import type { CustomerSummary } from '../lib/types';

// Cari member berdasarkan nama / HP / kode, atau daftarkan member baru
export default function CustomerPicker({ onClose, onPick }: { onClose: () => void; onPick: (c: CustomerSummary | null) => void }) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<CustomerSummary[]>([]);
  const [registering, setRegistering] = useState(false);
  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (query.trim().length < 2) {
      setResults([]);
      return;
    }
    const t = setTimeout(() => {
      rpc<CustomerSummary[]>('crm_search_customers', { p_query: query }).then(setResults).catch((e) => setError(errorMessage(e)));
    }, 250);
    return () => clearTimeout(t);
  }, [query]);

  const register = async () => {
    setBusy(true);
    setError('');
    try {
      const c = await rpc<CustomerSummary>('crm_register_customer', { p_name: name, p_phone: phone });
      onPick({ ...c, tier_name: null });
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal title={registering ? 'Daftar Member Baru' : 'Pilih Member'} onClose={onClose}>
      {error && <div className="alert alert-error">{error}</div>}
      {registering ? (
        <div className="grid">
          <label className="field"><span>Nama</span><input autoFocus value={name} onChange={(e) => setName(e.target.value)} /></label>
          <label className="field"><span>Nomor HP / WhatsApp</span><input inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="08123456789" /></label>
          <div className="row">
            <button onClick={() => setRegistering(false)}>← Kembali</button>
            <span className="spacer" />
            <button className="btn-primary" disabled={busy || !name.trim() || phone.replace(/\D/g, '').length < 8} onClick={register}>Daftar & Pilih</button>
          </div>
        </div>
      ) : (
        <div className="grid">
          <input autoFocus placeholder="Cari nama / nomor HP / kode member" value={query} onChange={(e) => setQuery(e.target.value)} />
          <div>
            {results.map((c) => (
              <button key={c.id} className="btn-block" style={{ textAlign: 'left', marginBottom: 6 }} onClick={() => onPick(c)}>
                <span className="bold">{c.name}</span> <span className="muted small">{c.phone} · {c.code}</span>
                <span style={{ float: 'right' }}>
                  {c.tier_name && <span className="badge badge-primary">{c.tier_name}</span>} ⭐ {formatNumber(c.points_balance)}
                </span>
              </button>
            ))}
            {query.trim().length >= 2 && !results.length && <div className="empty">Tidak ditemukan.</div>}
          </div>
          <div className="row">
            <button onClick={() => onPick(null)}>Tanpa member</button>
            <span className="spacer" />
            <button className="btn-primary" onClick={() => { setRegistering(true); setName(/\d/.test(query) ? '' : query); setPhone(/\d/.test(query) ? query : ''); }}>
              + Member Baru
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}

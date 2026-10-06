import { useEffect, useState } from 'react';
import { CheckCircle2, CircleAlert, Copy, KeyRound } from 'lucide-react';
import { useAuth } from '../../context/AuthContext';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';

interface Gateway {
  id?: string; provider: string; environment: 'sandbox' | 'production'; merchant_code: string | null;
  signature_method: 'hmac_sha512' | 'sha256'; is_active: boolean; has_merchant_key?: boolean;
}

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string;

// Persiapan iPay88: konfigurasi merchant + petunjuk deploy Edge Function
export default function PaymentGatewayTab() {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const [g, setG] = useState<Gateway | null>(null);
  const [key, setKey] = useState('');
  const [busy, setBusy] = useState(false);

  const load = async () => {
    const row = (await must(supabase.from('sys_payment_gateways').select('*').eq('provider', 'ipay88').maybeSingle())) as Gateway | null;
    setG(row ?? { provider: 'ipay88', environment: 'sandbox', merchant_code: '', signature_method: 'hmac_sha512', is_active: false });
  };
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, []);

  if (!g) return <div className="skeleton" style={{ height: 240 }} />;
  const set = (patch: Partial<Gateway>) => setG({ ...g, ...patch });
  const callbackUrl = `${SUPABASE_URL}/functions/v1/ipay88-callback`;
  const ready = !!g.id && !!g.merchant_code && !!g.has_merchant_key;

  const save = async () => {
    setBusy(true);
    try {
      const row = { environment: g.environment, merchant_code: g.merchant_code?.trim() || null, signature_method: g.signature_method, is_active: g.is_active && !!g.merchant_code };
      let id = g.id;
      if (id) await must(supabase.from('sys_payment_gateways').update(row).eq('id', id));
      else id = ((await must(supabase.from('sys_payment_gateways').insert({ ...row, company_id: profile!.company_id, provider: 'ipay88' }).select('id').single())) as { id: string }).id;
      if (key.trim()) await rpc('sys_set_payment_gateway_secret', { p_gateway_id: id, p_merchant_key: key });
      setKey('');
      await load();
      toast('Pengaturan iPay88 disimpan');
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="grid grid-2">
      <div className="card">
        <div className="card-header">
          <h2>iPay88</h2>
          {ready && g.is_active
            ? <span className="badge badge-success"><CheckCircle2 size={12} /> Aktif</span>
            : <span className="badge badge-warning"><CircleAlert size={12} /> Belum aktif</span>}
        </div>
        <div className="grid">
          <label className="field"><span>Merchant Code</span>
            <input value={g.merchant_code ?? ''} onChange={(e) => set({ merchant_code: e.target.value })} placeholder="dari iPay88, mis. ID01234" /></label>
          <label className="field"><span>Merchant Key {g.has_merchant_key && <span className="badge badge-success" style={{ marginLeft: 6 }}><KeyRound size={11} /> tersimpan</span>}</span>
            <input type="password" autoComplete="new-password" value={key} onChange={(e) => setKey(e.target.value)}
              placeholder={g.has_merchant_key ? 'Kosongkan bila tidak diganti' : 'Tempel merchant key'} /></label>
          <div className="form-grid">
            <label className="field"><span>Lingkungan</span>
              <select value={g.environment} onChange={(e) => set({ environment: e.target.value as Gateway['environment'] })}>
                <option value="sandbox">Sandbox (uji coba)</option><option value="production">Production (live)</option>
              </select></label>
            <label className="field"><span>Metode tanda tangan</span>
              <select value={g.signature_method} onChange={(e) => set({ signature_method: e.target.value as Gateway['signature_method'] })}>
                <option value="hmac_sha512">HMAC-SHA512 (baru, wajib sejak 2025)</option><option value="sha256">SHA-256 (lama)</option>
              </select></label>
          </div>
          <label className="row"><input type="checkbox" checked={g.is_active} onChange={(e) => set({ is_active: e.target.checked })} /> Tampilkan "Bayar Online" di kasir</label>
          <button className="btn-primary" disabled={busy} onClick={save}>Simpan</button>
          <p className="muted small" style={{ margin: 0 }}>
            Merchant key disimpan di server dalam tabel terkunci: hanya Edge Function yang bisa membacanya, <b>tidak</b> bisa dilihat lagi dari aplikasi.
          </p>
        </div>
      </div>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Langkah aktivasi</h2>
        <ol className="steps">
          <li>Daftar merchant di iPay88 Indonesia, minta <b>Merchant Code</b>, <b>Merchant Key</b>, dan dokumen teknis API.</li>
          <li>Deploy 2 Edge Function dari folder <code>supabase/functions</code>: <code>ipay88-checkout</code> dan <code>ipay88-callback</code> (callback dengan <code>--no-verify-jwt</code>).</li>
          <li>Di Supabase → Edge Functions → Secrets, isi <code>APP_URL</code> = alamat aplikasi ini.</li>
          <li>Daftarkan <b>Backend URL</b> berikut di dashboard iPay88:
            <div className="row" style={{ marginTop: 6, flexWrap: 'nowrap' }}>
              <code className="code-box">{callbackUrl}</code>
              <button className="icon-btn" title="Salin" onClick={() => { navigator.clipboard?.writeText(callbackUrl); toast('URL disalin', 'info'); }}><Copy size={16} /></button>
            </div>
          </li>
          <li>Isi form di samping, uji di <b>Sandbox</b>, lalu ganti ke <b>Production</b>.</li>
          <li>Cocokkan rumus tanda tangan di <code>supabase/functions/_shared/ipay88.ts</code> dengan dokumen iPay88 Anda.</li>
        </ol>
      </div>
    </div>
  );
}

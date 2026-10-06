import { useEffect, useState } from 'react';
import Modal from './Modal';
import CustomerPicker from './CustomerPicker';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatNumber, formatRupiah } from '../lib/format';
import { printReceipt } from '../lib/receipt';
import type { Order, PaymentMethod } from '../lib/types';

interface Props {
  order: Order;
  onClose: () => void;
  onPaid: () => void;
}

interface PayResult {
  order_number: string;
  grand_total: number;
  change_amount: number;
}

interface Member { id: string; name: string; phone: string; points_balance: number }
interface PointSettings { is_points_enabled: boolean; redeem_value: number; min_redeem_points: number }

export default function PaymentModal({ order: initialOrder, onClose, onPaid }: Props) {
  const { can } = useAuth();
  const [order, setOrder] = useState(initialOrder);
  const [methods, setMethods] = useState<PaymentMethod[]>([]);
  const [methodId, setMethodId] = useState('');
  const [amount, setAmount] = useState('');
  const [reference, setReference] = useState('');
  const [discount, setDiscount] = useState(String(Number(initialOrder.discount_amount) || ''));
  const [voucher, setVoucher] = useState('');
  const [points, setPoints] = useState('');
  const [member, setMember] = useState<Member | null>(null);
  const [promoName, setPromoName] = useState('');
  const [settings, setSettings] = useState<PointSettings | null>(null);
  const [pickingMember, setPickingMember] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [result, setResult] = useState<PayResult | null>(null);

  useEffect(() => {
    Promise.all([
      must(supabase.from('mst_payment_methods').select('*').eq('is_active', true).order('sort_order')),
      must(supabase.from('crm_settings').select('is_points_enabled, redeem_value, min_redeem_points').maybeSingle()),
    ])
      .then(([rows, s]) => {
        setMethods(rows as PaymentMethod[]);
        if (rows.length) setMethodId((rows as PaymentMethod[])[0].id);
        setSettings(s as PointSettings | null);
      })
      .catch((e) => setError(errorMessage(e)));
  }, []);

  // detail member & nama promo mengikuti order terbaru
  useEffect(() => {
    if (order.customer_id) {
      must(supabase.from('crm_customers').select('id, name, phone, points_balance').eq('id', order.customer_id).single())
        .then((m) => setMember(m as Member))
        .catch(() => setMember(null));
    } else {
      setMember(null);
    }
  }, [order.customer_id]);

  useEffect(() => {
    if (order.promotion_id) {
      must(supabase.from('crm_promotions').select('name, voucher_code').eq('id', order.promotion_id).single())
        .then((p) => setPromoName(p.voucher_code ? `${p.name} (${p.voucher_code})` : p.name))
        .catch(() => setPromoName('Promo'));
    } else {
      setPromoName('');
    }
  }, [order.promotion_id]);

  const method = methods.find((m) => m.id === methodId);
  const total = Number(order.grand_total);
  const isCash = method?.type === 'cash';
  const paid = isCash ? Number(amount || 0) : total;
  const change = Math.max(paid - total, 0);
  const quickCash = [...new Set([total, Math.ceil(total / 50000) * 50000, Math.ceil(total / 100000) * 100000, 200000])]
    .filter((v) => v >= total)
    .slice(0, 4);

  const update = async (fn: () => Promise<Order>) => {
    setBusy(true);
    setError('');
    try {
      setOrder(await fn());
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const pay = async () => {
    setBusy(true);
    setError('');
    try {
      const res = await rpc<PayResult>('pos_pay_order', {
        p_order_id: order.id,
        p_payments: [{ payment_method_id: methodId, amount: paid, reference_number: reference }],
      });
      setResult(res);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  if (result) {
    return (
      <Modal
        title="Pembayaran Berhasil ✅"
        onClose={onPaid}
        footer={
          <>
            <button onClick={() => printReceipt(order.id).catch((e) => setError(errorMessage(e)))}>🖨️ Cetak Struk</button>
            <button className="btn-primary" onClick={onPaid}>Selesai</button>
          </>
        }
      >
        {error && <div className="alert alert-error">{error}</div>}
        <div className="grid">
          <div className="sum-row"><span>No. Order</span><span className="bold">{result.order_number}</span></div>
          <div className="sum-row"><span>Total</span><span>{formatRupiah(result.grand_total)}</span></div>
          <div className="sum-row total"><span>Kembalian</span><span>{formatRupiah(result.change_amount)}</span></div>
          {member && <div className="alert alert-success">⭐ Poin {member.name} akan bertambah sesuai belanja.</div>}
        </div>
      </Modal>
    );
  }

  const pointsEnabled = settings?.is_points_enabled && member;

  return (
    <Modal
      title={`Bayar ${order.order_number}`}
      onClose={onClose}
      large
      footer={
        <>
          <button onClick={onClose}>Batal</button>
          <button className="btn-success btn-lg" disabled={busy || !methodId || paid < total} onClick={pay}>
            {busy ? 'Memproses…' : `Bayar ${formatRupiah(total)}`}
          </button>
        </>
      }
    >
      {error && <div className="alert alert-error">{error}</div>}
      <div className="grid grid-2">
        {/* kiri: rincian + member + promo */}
        <div className="grid" style={{ alignContent: 'start' }}>
          <div className="card" style={{ background: 'var(--surface-2)' }}>
            <div className="sum-row"><span>Subtotal</span><span>{formatRupiah(order.subtotal)}</span></div>
            {Number(order.discount_amount) > 0 && (
              <div className="sum-row"><span>Diskon</span><span>-{formatRupiah(order.discount_amount)}</span></div>
            )}
            {Number(order.promotion_amount) > 0 && (
              <div className="sum-row" style={{ color: 'var(--success)' }}><span>🏷️ {promoName}</span><span>-{formatRupiah(order.promotion_amount)}</span></div>
            )}
            {Number(order.points_amount) > 0 && (
              <div className="sum-row" style={{ color: 'var(--success)' }}><span>⭐ Tukar {order.points_redeemed} poin</span><span>-{formatRupiah(order.points_amount)}</span></div>
            )}
            <div className="sum-row"><span>Service</span><span>{formatRupiah(order.service_amount)}</span></div>
            <div className="sum-row"><span>Pajak</span><span>{formatRupiah(order.tax_amount)}</span></div>
            {Number(order.rounding_amount) !== 0 && (
              <div className="sum-row"><span>Pembulatan</span><span>{formatRupiah(order.rounding_amount)}</span></div>
            )}
            <div className="sum-row total"><span>Total</span><span>{formatRupiah(total)}</span></div>
          </div>

          <div className="row">
            <span className="muted small" style={{ width: 70 }}>Member</span>
            <button style={{ flex: 1, textAlign: 'left' }} onClick={() => setPickingMember(true)} disabled={busy}>
              {member ? <>👤 <b>{member.name}</b> · ⭐ {formatNumber(member.points_balance)} poin</> : '👤 Pilih / daftar member'}
            </button>
          </div>

          <div className="row">
            <span className="muted small" style={{ width: 70 }}>Voucher</span>
            <input placeholder="Kode voucher" value={voucher} onChange={(e) => setVoucher(e.target.value.toUpperCase())} style={{ flex: 1 }} />
            <button disabled={busy || !voucher.trim()} onClick={() => update(() => rpc<Order>('pos_apply_voucher', { p_order_id: order.id, p_code: voucher }))}>Pakai</button>
          </div>

          {pointsEnabled && (
            <div className="row">
              <span className="muted small" style={{ width: 70 }}>Tukar poin</span>
              <input type="number" min={0} placeholder={`min ${settings!.min_redeem_points}`} value={points}
                onChange={(e) => setPoints(e.target.value)} style={{ flex: 1 }} />
              <button disabled={busy} onClick={() => update(() => rpc<Order>('pos_redeem_points', { p_order_id: order.id, p_points: Number(points || 0) }))}>
                Tukar
              </button>
            </div>
          )}
          {pointsEnabled && <div className="muted small">1 poin = {formatRupiah(settings!.redeem_value)}</div>}

          {can('pos.discount') && (
            <div className="row">
              <span className="muted small" style={{ width: 70 }}>Diskon</span>
              <input type="number" min={0} placeholder="Rp" value={discount} onChange={(e) => setDiscount(e.target.value)} style={{ flex: 1 }} />
              <button disabled={busy} onClick={() => update(() => rpc<Order>('pos_set_order_discount', { p_order_id: order.id, p_discount_amount: Number(discount || 0) }))}>
                Terapkan
              </button>
            </div>
          )}
        </div>

        {/* kanan: pembayaran */}
        <div className="grid" style={{ alignContent: 'start' }}>
          <div>
            <div className="muted small" style={{ marginBottom: 6 }}>Metode pembayaran</div>
            <div className="choice-list">
              {methods.map((m) => (
                <button key={m.id} className={m.id === methodId ? 'active' : ''} onClick={() => setMethodId(m.id)}>
                  {m.name}
                </button>
              ))}
            </div>
          </div>

          {isCash ? (
            <>
              <label className="field">
                <span>Uang diterima</span>
                <input type="number" autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} />
              </label>
              <div className="choice-list">
                {quickCash.map((v) => (
                  <button key={v} onClick={() => setAmount(String(v))}>{v === total ? 'Uang pas' : formatRupiah(v)}</button>
                ))}
              </div>
              <div className="sum-row total"><span>Kembalian</span><span>{formatRupiah(change)}</span></div>
            </>
          ) : (
            <label className="field">
              <span>No. referensi (opsional)</span>
              <input value={reference} onChange={(e) => setReference(e.target.value)} />
            </label>
          )}
        </div>
      </div>

      {pickingMember && (
        <CustomerPicker
          onClose={() => setPickingMember(false)}
          onPick={(c) => {
            setPickingMember(false);
            setPoints('');
            update(() => rpc<Order>('pos_set_order_customer', { p_order_id: order.id, p_customer_id: c?.id ?? null }));
          }}
        />
      )}
    </Modal>
  );
}

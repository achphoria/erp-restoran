import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';

function beep() {
  try {
    const ctx = new AudioContext();
    const osc = ctx.createOscillator();
    osc.frequency.value = 880;
    osc.connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + 0.25);
  } catch {
    /* browser tanpa audio */
  }
}

// Banner di sidebar: jumlah item pesanan QR yang menunggu konfirmasi kasir
export default function QrOrderAlert({ outletId }: { outletId: string }) {
  const [count, setCount] = useState(0);
  const last = useRef(0);

  const refresh = useCallback(async () => {
    const { count: c } = await supabase
      .from('pos_order_items')
      .select('id, pos_orders!inner(outlet_id)', { count: 'exact', head: true })
      .eq('pos_orders.outlet_id', outletId)
      .eq('kitchen_status', 'waiting')
      .eq('is_void', false);
    const n = c ?? 0;
    if (n > last.current) beep();
    last.current = n;
    setCount(n);
  }, [outletId]);

  useEffect(() => {
    refresh();
    const channel = supabase
      .channel('qr-alert')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'pos_order_items' }, () => refresh())
      .subscribe();
    return () => {
      supabase.removeChannel(channel);
    };
  }, [refresh]);

  if (!count) return null;
  return (
    <Link to="/orders" className="qr-alert">
      🔔 {count} item pesanan QR menunggu konfirmasi
    </Link>
  );
}

import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, supabase } from '../lib/supabase';
import { errorMessage, formatRupiah } from '../lib/format';
import type { MenuCategory, MenuItem, ModifierGroup } from '../lib/types';
import Modal from '../components/Modal';
import SimpleList from '../components/SimpleList';
import TableQrList from '../components/TableQrList';

type Tab = 'menu' | 'category' | 'modifier' | 'table';

interface MenuPrice { id: string; menu_item_id: string; outlet_id: string | null; sales_channel: string; price: number }

export default function MenuPage() {
  const { profile, outlet } = useAuth();
  const companyId = profile!.company_id;
  const [tab, setTab] = useState<Tab>('menu');
  const [brandId, setBrandId] = useState('');
  const [categories, setCategories] = useState<MenuCategory[]>([]);
  const [items, setItems] = useState<MenuItem[]>([]);
  const [groups, setGroups] = useState<ModifierGroup[]>([]);
  const [links, setLinks] = useState<{ menu_item_id: string; modifier_group_id: string }[]>([]);
  const [prices, setPrices] = useState<MenuPrice[]>([]);
  const [editing, setEditing] = useState<Partial<MenuItem> | null>(null);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      const [brands, cats, menu, grp, lnk, pr] = await Promise.all([
        must(supabase.from('sys_brands').select('id').limit(1)),
        must(supabase.from('mst_menu_categories').select('*').order('sort_order')),
        must(supabase.from('mst_menu_items').select('*').order('code')),
        must(supabase.from('mst_modifier_groups').select('*, mst_modifiers(*)').order('name')),
        must(supabase.from('mst_menu_item_modifier_groups').select('menu_item_id, modifier_group_id')),
        must(supabase.from('mst_menu_prices').select('*').is('outlet_id', null)),
      ]);
      setBrandId((brands as { id: string }[])[0]?.id ?? '');
      setCategories(cats as MenuCategory[]);
      setItems(menu as MenuItem[]);
      setGroups(grp as ModifierGroup[]);
      setLinks(lnk as { menu_item_id: string; modifier_group_id: string }[]);
      setPrices(pr as MenuPrice[]);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [outlet]);

  useEffect(() => {
    load();
  }, [load]);

  const act = async (fn: () => Promise<unknown>) => {
    setError('');
    try {
      await fn();
      await load();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Master Menu</h1>
          <p>Atur menu, kategori, modifier, dan meja.</p>
        </div>
        {tab === 'menu' && (
          <button className="btn-primary" onClick={() => setEditing({ station: 'kitchen', is_active: true, base_price: 0 })}>+ Menu Baru</button>
        )}
      </div>
      <div className="tabs">
        {([['menu', 'Menu'], ['category', 'Kategori'], ['modifier', 'Modifier'], ['table', 'Meja & QR']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>
        ))}
      </div>
      {error && <div className="alert alert-error">{error}</div>}

      {tab === 'menu' && (
        <div className="card table-wrap">
          <table className="table">
            <thead>
              <tr><th>Kode</th><th>Nama</th><th>Kategori</th><th>Station</th><th className="right">Harga</th><th className="right">GoFood</th><th>Status</th><th></th></tr>
            </thead>
            <tbody>
              {items.map((i) => (
                <tr key={i.id}>
                  <td>{i.code}</td>
                  <td className="bold">{i.name}</td>
                  <td>{categories.find((c) => c.id === i.menu_category_id)?.name}</td>
                  <td>{i.station}</td>
                  <td className="right">{formatRupiah(i.base_price)}</td>
                  <td className="right muted">
                    {(() => {
                      const p = prices.find((x) => x.menu_item_id === i.id && x.sales_channel === 'gofood');
                      return p ? formatRupiah(p.price) : '-';
                    })()}
                  </td>
                  <td>{i.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}</td>
                  <td className="right"><button className="btn-sm" onClick={() => setEditing(i)}>Edit</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {tab === 'category' && (
        <SimpleList
          title="Kategori Menu"
          rows={categories.map((c) => ({ id: c.id, label: c.name, sub: `${items.filter((i) => i.menu_category_id === c.id).length} menu` }))}
          onAdd={(name) => act(() => must(supabase.from('mst_menu_categories').insert({
            company_id: companyId, brand_id: brandId, name, sort_order: categories.length + 1,
          })))}
          onRename={(id, name) => act(() => must(supabase.from('mst_menu_categories').update({ name }).eq('id', id)))}
        />
      )}

      {tab === 'modifier' && (
        <div className="grid grid-2">
          {groups.map((g) => (
            <SimpleList
              key={g.id}
              title={`${g.name} (maks ${g.max_select})`}
              rows={[...g.mst_modifiers].sort((a, b) => a.sort_order - b.sort_order)
                .map((m) => ({ id: m.id, label: m.name, sub: Number(m.extra_price) ? `+${formatRupiah(m.extra_price)}` : 'gratis' }))}
              addPlaceholder="Nama opsi, contoh: Extra Keju"
              withPrice
              onAdd={(name, price) => act(() => must(supabase.from('mst_modifiers').insert({
                company_id: companyId, modifier_group_id: g.id, name, extra_price: price ?? 0, sort_order: g.mst_modifiers.length + 1,
              })))}
              onRename={(id, name) => act(() => must(supabase.from('mst_modifiers').update({ name }).eq('id', id)))}
              onDelete={(id) => act(() => must(supabase.from('mst_modifiers').delete().eq('id', id)))}
            />
          ))}
          <SimpleList
            title="+ Grup Modifier Baru"
            rows={[]}
            addPlaceholder="contoh: Ukuran, Gula, Topping"
            onAdd={(name) => act(() => must(supabase.from('mst_modifier_groups').insert({ company_id: companyId, name, max_select: 1 })))}
          />
        </div>
      )}

      {tab === 'table' && (
        <TableQrList companyId={companyId} outletId={outlet!.id} outletName={outlet!.name} />
      )}

      {editing && (
        <MenuForm
          item={editing}
          categories={categories}
          groups={groups}
          selectedGroups={links.filter((l) => l.menu_item_id === editing.id).map((l) => l.modifier_group_id)}
          prices={prices.filter((p) => p.menu_item_id === editing.id)}
          onClose={() => setEditing(null)}
          onSave={async (data, groupIds, channelPrices) => {
            const row = { ...data, company_id: companyId, brand_id: brandId };
            const saved = (await must(
              data.id
                ? supabase.from('mst_menu_items').update(row).eq('id', data.id).select().single()
                : supabase.from('mst_menu_items').insert(row).select().single(),
            )) as MenuItem;

            await must(supabase.from('mst_menu_item_modifier_groups').delete().eq('menu_item_id', saved.id));
            if (groupIds.length) {
              await must(supabase.from('mst_menu_item_modifier_groups').insert(
                groupIds.map((gid) => ({ company_id: companyId, menu_item_id: saved.id, modifier_group_id: gid })),
              ));
            }
            for (const [channel, price] of Object.entries(channelPrices)) {
              await must(supabase.from('mst_menu_prices').delete()
                .eq('menu_item_id', saved.id).is('outlet_id', null).eq('sales_channel', channel));
              if (price !== '') {
                await must(supabase.from('mst_menu_prices').insert({
                  company_id: companyId, menu_item_id: saved.id, sales_channel: channel, price: Number(price),
                }));
              }
            }
            setEditing(null);
            await load();
          }}
        />
      )}
    </>
  );
}

function MenuForm({
  item, categories, groups, selectedGroups, prices, onClose, onSave,
}: {
  item: Partial<MenuItem>;
  categories: MenuCategory[];
  groups: ModifierGroup[];
  selectedGroups: string[];
  prices: MenuPrice[];
  onClose: () => void;
  onSave: (data: Partial<MenuItem>, groupIds: string[], channelPrices: Record<string, string>) => Promise<void>;
}) {
  const [form, setForm] = useState<Partial<MenuItem>>({ menu_category_id: categories[0]?.id, ...item });
  const [groupIds, setGroupIds] = useState(selectedGroups);
  const [channelPrices, setChannelPrices] = useState<Record<string, string>>({
    gofood: String(prices.find((p) => p.sales_channel === 'gofood')?.price ?? ''),
    grabfood: String(prices.find((p) => p.sales_channel === 'grabfood')?.price ?? ''),
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const set = (patch: Partial<MenuItem>) => setForm((f) => ({ ...f, ...patch }));

  const save = async () => {
    setBusy(true);
    setError('');
    try {
      const { id, code, name, menu_category_id, base_price, station, is_active, description } = form;
      await onSave({ id, code, name, menu_category_id, base_price: Number(base_price), station, is_active, description }, groupIds, channelPrices);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal
      title={item.id ? `Edit ${item.name}` : 'Menu Baru'}
      onClose={onClose}
      large
      footer={
        <>
          <button onClick={onClose}>Batal</button>
          <button className="btn-primary" disabled={busy || !form.code || !form.name || !form.menu_category_id} onClick={save}>
            {busy ? 'Menyimpan…' : 'Simpan'}
          </button>
        </>
      }
    >
      {error && <div className="alert alert-error">{error}</div>}
      <div className="form-grid">
        <label className="field"><span>Kode</span><input value={form.code ?? ''} onChange={(e) => set({ code: e.target.value })} /></label>
        <label className="field"><span>Nama</span><input value={form.name ?? ''} onChange={(e) => set({ name: e.target.value })} /></label>
        <label className="field">
          <span>Kategori</span>
          <select value={form.menu_category_id} onChange={(e) => set({ menu_category_id: e.target.value })}>
            {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="field">
          <span>Station</span>
          <select value={form.station} onChange={(e) => set({ station: e.target.value })}>
            <option value="kitchen">Dapur</option><option value="bar">Bar</option><option value="pastry">Pastry</option>
          </select>
        </label>
        <label className="field"><span>Harga (Dine In / Take Away)</span>
          <input type="number" value={form.base_price ?? 0} onChange={(e) => set({ base_price: Number(e.target.value) })} /></label>
        <label className="field"><span>Harga GoFood (kosong = sama)</span>
          <input type="number" value={channelPrices.gofood} onChange={(e) => setChannelPrices((p) => ({ ...p, gofood: e.target.value }))} /></label>
        <label className="field"><span>Harga GrabFood (kosong = sama)</span>
          <input type="number" value={channelPrices.grabfood} onChange={(e) => setChannelPrices((p) => ({ ...p, grabfood: e.target.value }))} /></label>
        <label className="field"><span>Status</span>
          <select value={form.is_active ? '1' : '0'} onChange={(e) => set({ is_active: e.target.value === '1' })}>
            <option value="1">Aktif</option><option value="0">Nonaktif</option>
          </select>
        </label>
      </div>
      <div style={{ marginTop: 16 }}>
        <div className="muted small" style={{ marginBottom: 6 }}>Grup modifier yang berlaku</div>
        <div className="choice-list">
          {groups.map((g) => (
            <button key={g.id} className={groupIds.includes(g.id) ? 'active' : ''}
              onClick={() => setGroupIds((ids) => ids.includes(g.id) ? ids.filter((x) => x !== g.id) : [...ids, g.id])}>
              {g.name}
            </button>
          ))}
        </div>
      </div>
      <p className="muted small">Resep & HPP diatur di halaman Inventory → Resep.</p>
    </Modal>
  );
}

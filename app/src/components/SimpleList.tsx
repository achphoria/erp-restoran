import { useState } from 'react';
import { useFeedback } from './Feedback';
import MoneyInput from './MoneyInput';

// Daftar sederhana dengan tambah / ubah nama / hapus
export default function SimpleList({
  title, rows, onAdd, onRename, onDelete, addPlaceholder = 'Nama baru', withPrice,
}: {
  title: string;
  rows: { id: string; label: string; sub?: string }[];
  onAdd: (name: string, price?: number) => void;
  onRename?: (id: string, name: string) => void;
  onDelete?: (id: string) => void;
  addPlaceholder?: string;
  withPrice?: boolean;
}) {
  const [name, setName] = useState('');
  const [price, setPrice] = useState('');
  const { confirm, prompt } = useFeedback();
  return (
    <div className="card">
      <h3 style={{ marginBottom: 8 }}>{title}</h3>
      <table className="table">
        <tbody>
          {rows.map((r) => (
            <tr key={r.id}>
              <td className="bold">{r.label}</td>
              <td className="muted small">{r.sub}</td>
              <td className="right">
                <div className="row" style={{ justifyContent: 'flex-end' }}>
                  {onRename && (
                    <button className="btn-sm" onClick={async () => {
                      const v = await prompt({ title: 'Ubah nama', label: 'Nama baru', defaultValue: r.label });
                      if (v) onRename(r.id, v);
                    }}>Ubah</button>
                  )}
                  {onDelete && (
                    <button className="btn-sm btn-danger" onClick={async () => {
                      if (await confirm({ title: `Hapus "${r.label}"?`, message: 'Data yang dihapus tidak bisa dikembalikan.', danger: true, confirmLabel: 'Hapus' })) onDelete(r.id);
                    }}>Hapus</button>
                  )}
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <form className="row" style={{ marginTop: 8 }} onSubmit={(e) => {
        e.preventDefault();
        if (!name.trim()) return;
        onAdd(name.trim(), withPrice ? Number(price || 0) : undefined);
        setName('');
        setPrice('');
      }}>
        <input placeholder={addPlaceholder} value={name} onChange={(e) => setName(e.target.value)} style={{ flex: 1 }} />
        {withPrice && <MoneyInput placeholder="+Rp" value={price} onChange={(v) => setPrice(v)} style={{ width: 90 }} />}
        <button>Tambah</button>
      </form>
    </div>
  );
}

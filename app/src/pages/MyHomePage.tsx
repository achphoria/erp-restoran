import { useCallback, useEffect, useState } from 'react';
import { Briefcase, Clock, Megaphone, MapPin, Pencil, Phone, Pin, UserRound } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from '../components/Feedback';
import Modal from '../components/Modal';
import HrPhoto from '../components/hr/HrPhoto';
import { rpc } from '../lib/supabase';
import { errorMessage, formatDateTime } from '../lib/format';
import { EMPLOYMENT } from '../lib/hr';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Beranda Saya: halaman setiap karyawan (dirancang untuk HP) - kartu karyawan, absen, pengumuman, profil
export default function MyHomePage() {
  const { profile, outlet } = useAuth();
  const { toast } = useFeedback();
  const [me, setMe] = useState<any | null | undefined>(undefined);
  const [ann, setAnn] = useState<any[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const [edit, setEdit] = useState<any | null>(null);

  const load = useCallback(async () => {
    const [m, a] = await Promise.all([rpc<any>('hr_my_employee'), rpc<any[]>('hr_my_announcements')]);
    setMe(m ?? null);
    setAnn(a ?? []);
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const read = async (a: any) => {
    setOpen(open === a.id ? null : a.id);
    if (!a.read) { await rpc('hr_mark_announcement_read', { p_id: a.id }).catch(() => undefined); setAnn((x) => x.map((y) => (y.id === a.id ? { ...y, read: true } : y))); }
  };
  const saveProfile = async () => {
    try {
      setMe(await rpc('hr_update_my_profile', { p: edit }));
      setEdit(null);
      toast('Profil diperbarui', 'success');
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  const hour = Number(new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Jakarta', hour: '2-digit', hourCycle: 'h23' }).format(new Date()));
  const greet = hour < 11 ? 'Selamat pagi' : hour < 15 ? 'Selamat siang' : hour < 18 ? 'Selamat sore' : 'Selamat malam';
  const unread = ann.filter((a) => !a.read).length;

  return (
    <div className="me-page">
      <div className="me-hero">
        <HrPhoto path={me?.photo_path} name={me?.full_name ?? profile?.full_name ?? '?'} size={64} />
        <div>
          <div className="me-greet">{greet},</div>
          <h1>{me?.nickname || me?.full_name || profile?.full_name} 👋</h1>
          <div className="me-sub">{me?.position ?? profile?.role_name}{(me?.outlet ?? outlet?.name) ? ` · ${me?.outlet ?? outlet?.name}` : ''}</div>
        </div>
      </div>

      {me === null && (
        <div className="alert alert-info small">Akun Anda belum terhubung ke data karyawan. Minta HR/owner menautkannya di menu <b>SDM / HR → Karyawan</b>.</div>
      )}

      <div className="me-grid">
        <div className="card me-attend">
          <div className="me-card-title"><Clock size={16} /> Absensi hari ini</div>
          <p className="muted small" style={{ margin: '4px 0 10px' }}>Absen dengan foto selfie & lokasi GPS. Fitur ini segera aktif.</p>
          <div className="me-attend-btns">
            <button className="btn-primary btn-lg" disabled>Absen Masuk</button>
            <button className="btn-lg" disabled>Absen Pulang</button>
          </div>
        </div>

        <div className="card">
          <div className="me-card-title"><Megaphone size={16} /> Pengumuman {unread > 0 && <span className="badge badge-danger">{unread} baru</span>}</div>
          <div className="me-ann">
            {ann.map((a) => (
              <button key={a.id} type="button" className={`me-ann-item ${a.read ? '' : 'unread'}`} onClick={() => read(a)}>
                <b>{a.pinned && <Pin size={12} style={{ verticalAlign: -1, color: 'var(--accent)' }} />} {a.title}</b>
                <small className="muted">{formatDateTime(a.published_at)}{a.author ? ` · ${a.author}` : ''}</small>
                {open === a.id && <p>{a.body || <span className="muted">(tanpa isi)</span>}</p>}
              </button>
            ))}
            {!ann.length && <p className="muted small" style={{ margin: 0 }}>Belum ada pengumuman.</p>}
          </div>
        </div>

        {me && (
          <div className="card">
            <div className="me-card-title" style={{ justifyContent: 'space-between' }}>
              <span><UserRound size={16} /> Data saya</span>
              <button className="btn-sm" onClick={() => setEdit({ nickname: me.nickname ?? '', phone: me.phone ?? '', email: me.email ?? '', address_domicile: me.address_domicile ?? '',
                emergency_name: me.emergency_name ?? '', emergency_relation: me.emergency_relation ?? '', emergency_phone: me.emergency_phone ?? '' })}><Pencil size={13} /> Ubah</button>
            </div>
            <dl className="me-dl">
              <dt>No. karyawan</dt><dd>{me.employee_number}</dd>
              <dt><Briefcase size={13} /> Jabatan</dt><dd>{me.position ?? '—'}{me.department ? ` · ${me.department}` : ''}</dd>
              <dt><MapPin size={13} /> Outlet</dt><dd>{me.outlet ?? 'Kantor pusat'}</dd>
              <dt>Atasan</dt><dd>{me.manager ?? '—'}</dd>
              <dt>Status</dt><dd>{EMPLOYMENT[me.employment_status]}{me.join_date ? ` · sejak ${new Date(me.join_date).toLocaleDateString('id-ID')}` : ''}</dd>
              <dt><Phone size={13} /> HP</dt><dd>{me.phone ?? '—'}</dd>
              <dt>Kontak darurat</dt><dd>{me.emergency_name ? `${me.emergency_name} (${me.emergency_relation ?? '-'}) ${me.emergency_phone ?? ''}` : '—'}</dd>
            </dl>
          </div>
        )}
      </div>

      {edit && (
        <Modal title="Ubah data saya" onClose={() => setEdit(null)}
          footer={<><button onClick={() => setEdit(null)}>Batal</button><button className="btn-primary" onClick={saveProfile}>Simpan</button></>}>
          <div className="form-grid">
            {([['nickname', 'Nama panggilan'], ['phone', 'No. HP'], ['email', 'Email'], ['emergency_name', 'Kontak darurat: nama'],
              ['emergency_relation', 'Hubungan'], ['emergency_phone', 'Kontak darurat: HP']] as [string, string][]).map(([k, l]) => (
              <label key={k} className="field"><span>{l}</span><input value={edit[k]} onChange={(e) => setEdit({ ...edit, [k]: e.target.value })} /></label>
            ))}
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Alamat domisili</span><textarea rows={2} value={edit.address_domicile} onChange={(e) => setEdit({ ...edit, address_domicile: e.target.value })} /></label>
          </div>
          <p className="muted small">Data identitas (KTP, BPJS, jabatan) hanya bisa diubah HR.</p>
        </Modal>
      )}
    </div>
  );
}

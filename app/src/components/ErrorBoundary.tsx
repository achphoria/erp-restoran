import { Component, type ErrorInfo, type ReactNode } from 'react';
import { isChunkError, reloadForNewVersion } from '../lib/lazyRetry';

interface Props { children: ReactNode; inline?: boolean }
interface State { error: Error | null; updating: boolean }

// Penangkap error: daripada layar putih, tampilkan pesan + tombol muat ulang.
// Error karena versi aplikasi baru (file lama hilang) langsung dimuat ulang otomatis.
export default class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null, updating: false };

  static getDerivedStateFromError(error: Error): Partial<State> {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    if (isChunkError(error) && reloadForNewVersion()) { this.setState({ updating: true }); return; }
    console.error('[SEMAR] halaman error', error, info.componentStack);
  }

  render() {
    const { error, updating } = this.state;
    if (!error) return this.props.children;
    const chunk = isChunkError(error);
    return (
      <div className={this.props.inline ? 'card app-error' : 'app-error app-error-full'}>
        <div className="app-error-box">
          <div className="app-error-icon" aria-hidden>{chunk ? '✨' : '⚠️'}</div>
          <h2>{updating || chunk ? 'SEMAR baru saja diperbarui' : 'Halaman ini gagal dimuat'}</h2>
          <p className="muted">{updating ? 'Memuat versi terbaru…' : chunk
            ? 'Ada versi baru aplikasi. Muat ulang untuk melanjutkan.'
            : 'Maaf, terjadi kesalahan. Data Anda aman. Coba muat ulang halaman.'}</p>
          {!chunk && <details className="small muted"><summary>Detail teknis</summary><code>{error.message}</code></details>}
          <div className="row" style={{ gap: 8, justifyContent: 'center' }}>
            <button className="btn-primary" onClick={() => window.location.reload()}>Muat ulang</button>
            {this.props.inline && <button onClick={() => this.setState({ error: null })}>Coba lagi</button>}
          </div>
        </div>
      </div>
    );
  }
}

import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from 'react';
import { AlertTriangle, CheckCircle2, Info, X, XCircle } from 'lucide-react';
import Modal from './Modal';

type ToastType = 'success' | 'error' | 'info';
interface Toast { id: number; message: string; type: ToastType }

interface ConfirmOptions { title: string; message?: ReactNode; confirmLabel?: string; danger?: boolean }
interface PromptOptions { title: string; label?: string; defaultValue?: string; placeholder?: string; confirmLabel?: string; required?: boolean }

interface FeedbackApi {
  toast: (message: string, type?: ToastType) => void;
  confirm: (opts: ConfirmOptions) => Promise<boolean>;
  prompt: (opts: PromptOptions) => Promise<string | null>;
}

const FeedbackContext = createContext<FeedbackApi | null>(null);

type DialogState =
  | { kind: 'confirm'; opts: ConfirmOptions; resolve: (v: boolean) => void }
  | { kind: 'prompt'; opts: PromptOptions; resolve: (v: string | null) => void }
  | null;

const ICONS = { success: CheckCircle2, error: XCircle, info: Info };

// Pengganti alert/confirm/prompt bawaan browser + notifikasi toast
export function FeedbackProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [dialog, setDialog] = useState<DialogState>(null);
  const [value, setValue] = useState('');
  const nextId = useRef(1);

  const dismiss = (id: number) => setToasts((t) => t.filter((x) => x.id !== id));

  const toast = useCallback((message: string, type: ToastType = 'success') => {
    if (!message) return;
    const id = nextId.current++;
    setToasts((t) => [...t.slice(-3), { id, message, type }]);
    setTimeout(() => dismiss(id), type === 'error' ? 7000 : 4000);
  }, []);

  const confirm = useCallback((opts: ConfirmOptions) =>
    new Promise<boolean>((resolve) => setDialog({ kind: 'confirm', opts, resolve })), []);

  const prompt = useCallback((opts: PromptOptions) => {
    setValue(opts.defaultValue ?? '');
    return new Promise<string | null>((resolve) => setDialog({ kind: 'prompt', opts, resolve }));
  }, []);

  const close = (result: boolean) => {
    if (!dialog) return;
    if (dialog.kind === 'confirm') dialog.resolve(result);
    else dialog.resolve(result ? value.trim() : null);
    setDialog(null);
  };

  const promptInvalid = dialog?.kind === 'prompt' && (dialog.opts.required ?? true) && !value.trim();

  return (
    <FeedbackContext.Provider value={{ toast, confirm, prompt }}>
      {children}

      <div className="toast-stack" role="status" aria-live="polite">
        {toasts.map((t) => {
          const Icon = ICONS[t.type];
          return (
            <div key={t.id} className={`toast toast-${t.type}`}>
              <Icon size={18} />
              <span>{t.message}</span>
              <button className="icon-btn" onClick={() => dismiss(t.id)} aria-label="Tutup"><X size={16} /></button>
            </div>
          );
        })}
      </div>

      {dialog && (
        <Modal
          title={dialog.opts.title}
          onClose={() => close(false)}
          footer={
            <>
              <button onClick={() => close(false)}>Batal</button>
              <button
                className={dialog.kind === 'confirm' && dialog.opts.danger ? 'btn-danger-solid' : 'btn-primary'}
                disabled={promptInvalid}
                onClick={() => close(true)}
              >
                {dialog.opts.confirmLabel ?? (dialog.kind === 'confirm' ? 'Ya, lanjutkan' : 'Simpan')}
              </button>
            </>
          }
        >
          {dialog.kind === 'confirm' ? (
            <div className="row" style={{ alignItems: 'flex-start', flexWrap: 'nowrap' }}>
              {dialog.opts.danger && <AlertTriangle size={22} style={{ color: 'var(--danger)', flexShrink: 0 }} />}
              <div className="muted">{dialog.opts.message}</div>
            </div>
          ) : (
            <form onSubmit={(e) => { e.preventDefault(); if (!promptInvalid) close(true); }}>
              <label className="field">
                {dialog.opts.label && <span>{dialog.opts.label}</span>}
                <input autoFocus value={value} placeholder={dialog.opts.placeholder} onChange={(e) => setValue(e.target.value)} />
              </label>
            </form>
          )}
        </Modal>
      )}
    </FeedbackContext.Provider>
  );
}

// eslint-disable-next-line react-refresh/only-export-components
export function useFeedback() {
  const ctx = useContext(FeedbackContext);
  if (!ctx) throw new Error('useFeedback harus di dalam FeedbackProvider');
  return ctx;
}

// Pengganti state "notice" lama: setNotice('teks') -> toast sukses
// eslint-disable-next-line react-refresh/only-export-components
export function useNotice() {
  return useFeedback().toast;
}

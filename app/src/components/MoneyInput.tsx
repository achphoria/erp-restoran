import type { InputHTMLAttributes } from 'react';

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'type'> & {
  value: number | string | null | undefined;
  onChange: (value: string) => void;   // angka mentah tanpa titik, '' bila kosong
  allowNegative?: boolean;
};

const fmt = new Intl.NumberFormat('id-ID', { maximumFractionDigits: 0 });

// Input Rupiah: tampil "150.000", nilai yang dikirim "150000"
export default function MoneyInput({ value, onChange, allowNegative, className, ...rest }: Props) {
  const raw = value === null || value === undefined || value === '' ? '' : String(value);
  const negative = raw.startsWith('-');
  const digits = raw.replace(/[^0-9]/g, '');
  const display = digits ? (negative ? '-' : '') + fmt.format(Number(digits)) : negative ? '-' : '';

  return (
    <div className={`money-input ${className ?? ''}`}>
      <span className="money-prefix">Rp</span>
      <input
        {...rest}
        inputMode="numeric"
        value={display}
        onChange={(e) => {
          const v = e.target.value;
          const d = v.replace(/[^0-9]/g, '').replace(/^0+(?=\d)/, '');
          onChange((allowNegative && v.trim().startsWith('-') ? '-' : '') + d);
        }}
      />
    </div>
  );
}

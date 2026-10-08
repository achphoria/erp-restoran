import type { ReactNode } from 'react';

// Markdown sederhana untuk jawaban agent: judul, paragraf, daftar, tabel, blok kode, **tebal**, *miring*, `kode`.
// Dirender sebagai elemen React (tanpa innerHTML), jadi aman dari HTML berbahaya.

function inline(text: string, key: string): ReactNode[] {
  const out: ReactNode[] = [];
  const re = /(\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*)/g;
  let last = 0, m: RegExpExecArray | null, i = 0;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const t = m[0];
    if (t.startsWith('**')) out.push(<b key={`${key}-${i++}`}>{t.slice(2, -2)}</b>);
    else if (t.startsWith('`')) out.push(<code key={`${key}-${i++}`}>{t.slice(1, -1)}</code>);
    else out.push(<i key={`${key}-${i++}`}>{t.slice(1, -1)}</i>);
    last = m.index + t.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

const cells = (line: string) => line.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());

export function MiniMarkdown({ text }: { text: string }) {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const blocks: ReactNode[] = [];
  let i = 0, k = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('```')) {
      const code: string[] = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('```')) code.push(lines[i++]);
      i++;
      blocks.push(<pre key={k++}><code>{code.join('\n')}</code></pre>);
      continue;
    }
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      const head = cells(line);
      i += 2;
      const rows: string[][] = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) rows.push(cells(lines[i++]));
      blocks.push(
        <div key={k++} className="md-table"><table className="table">
          <thead><tr>{head.map((h, j) => <th key={j}>{inline(h, `h${j}`)}</th>)}</tr></thead>
          <tbody>{rows.map((r, ri) => <tr key={ri}>{r.map((c, j) => <td key={j}>{inline(c, `c${ri}${j}`)}</td>)}</tr>)}</tbody>
        </table></div>,
      );
      continue;
    }
    const h = /^(#{1,4})\s+(.*)$/.exec(line);
    if (h) { blocks.push(<div key={k++} className={`md-h md-h${h[1].length}`}>{inline(h[2], `t${k}`)}</div>); i++; continue; }
    if (/^\s*([-*]|\d+[.)])\s+/.test(line)) {
      const ordered = /^\s*\d+[.)]/.test(line);
      const items: string[] = [];
      while (i < lines.length && /^\s*([-*]|\d+[.)])\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*([-*]|\d+[.)])\s+/, ''));
      const List = ordered ? 'ol' : 'ul';
      blocks.push(<List key={k++}>{items.map((it, j) => <li key={j}>{inline(it, `l${k}${j}`)}</li>)}</List>);
      continue;
    }
    if (!line.trim()) { i++; continue; }
    const para: string[] = [];
    while (i < lines.length && lines[i].trim() && !/^(#{1,4}\s|```|\s*([-*]|\d+[.)])\s|\s*\|)/.test(lines[i])) para.push(lines[i++]);
    if (!para.length) para.push(lines[i++]);
    blocks.push(<p key={k++}>{para.flatMap((p, j) => (j ? [<br key={`br${j}`} />, ...inline(p, `p${k}${j}`)] : inline(p, `p${k}${j}`)))}</p>);
  }
  return <div className="md">{blocks}</div>;
}

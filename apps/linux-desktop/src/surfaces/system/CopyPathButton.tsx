import { useState } from 'react';

export function CopyPathButton({ path, label = 'Copy path' }: { path: string; label?: string }) {
  const [copied, setCopied] = useState(false);

  const onCopy = async () => {
    try {
      await navigator.clipboard.writeText(path);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      setCopied(false);
    }
  };

  return (
    <span className="system-copy-wrap">
      <button type="button" className="ghost system-copy-btn" onClick={() => void onCopy()}>
        {label}
      </button>
      <span className="visually-hidden" aria-live="polite">
        {copied ? 'Copied' : ''}
      </span>
    </span>
  );
}
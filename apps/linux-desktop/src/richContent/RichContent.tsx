import { Fragment, useMemo, useState, type ReactNode } from 'react';
import {
  RICH_CONTENT_VISIBLE_CHARACTER_LIMIT,
  hermesAtomActionLabel,
  hermesAtomCategory,
  hermesAtomDescription,
  parseRichContent,
  type HermesAtom,
  type RichBlock,
  type RichInlineRun
} from './richContentModel.js';
import './richContent.css';

export type RichContentProps = {
  text: string;
  className?: string;
  label?: string;
  preservePlainText?: boolean;
  visibleCharacterLimit?: number;
  expanded?: boolean;
  onOpenAtom?: (atom: HermesAtom) => void | Promise<void>;
  onOpenExternal?: (url: string) => void | Promise<void>;
};

function inlineKey(run: RichInlineRun, index: number): string {
  if (run.kind === 'atom') return `atom:${run.atom.kind}:${run.label}:${index}`;
  if (run.kind === 'mention') return `mention:${run.handle}:${index}`;
  if (run.kind === 'code') return `code:${run.text}:${index}`;
  if (run.kind === 'link') return `link:${run.url}:${index}`;
  return `${run.kind}:${index}`;
}

function InlineRuns({
  runs,
  onAtom,
  onExternal
}: {
  runs: RichInlineRun[];
  onAtom: (atom: HermesAtom, label: string) => void;
  onExternal?: (url: string) => void | Promise<void>;
}) {
  return runs.map((run, index) => {
    const key = inlineKey(run, index);
    switch (run.kind) {
      case 'text': {
        let content: ReactNode = run.text;
        if (run.style.bold) content = <strong>{content}</strong>;
        if (run.style.italic) content = <em>{content}</em>;
        if (run.style.strikethrough) content = <s>{content}</s>;
        return <Fragment key={key}>{content}</Fragment>;
      }
      case 'code':
        return <code key={key} className="rich-inline-code">{run.text}</code>;
      case 'mention':
        return <span key={key} className="rich-mention">{run.handle}</span>;
      case 'atom':
        return (
          <button
            key={key}
            type="button"
            className={`rich-atom rich-atom--${run.atom.kind}`}
            onClick={() => onAtom(run.atom, run.label)}
            aria-label={`${hermesAtomCategory(run.atom)}: ${run.label}`}
            title={hermesAtomDescription(run.atom)}
          >
            <span className="rich-atom__glyph" aria-hidden="true" />
            <span>{run.label}</span>
          </button>
        );
      case 'link':
        return onExternal ? (
          <button
            key={key}
            type="button"
            className="rich-link"
            onClick={() => void onExternal(run.url)}
            title={run.url}
          >
            <InlineRuns runs={run.label} onAtom={onAtom} onExternal={onExternal} />
            <span aria-hidden="true">↗</span>
          </button>
        ) : (
          <span key={key} className="rich-link rich-link--disabled">
            <InlineRuns runs={run.label} onAtom={onAtom} />
          </span>
        );
      case 'break':
        return <br key={key} />;
    }
  });
}

function ListBlock({
  block,
  onAtom,
  onExternal
}: {
  block: Extract<RichBlock, { kind: 'list' }>;
  onAtom: (atom: HermesAtom, label: string) => void;
  onExternal?: (url: string) => void | Promise<void>;
}) {
  const Tag = block.ordered ? 'ol' : 'ul';
  return (
    <Tag className="rich-list" start={block.ordered ? block.start : undefined}>
      {block.items.map((item, index) => (
        <li
          key={`${item.depth}:${index}`}
          className="rich-list__item"
          style={{ '--rich-list-depth': item.depth } as React.CSSProperties}
        >
          <InlineRuns runs={item.runs} onAtom={onAtom} onExternal={onExternal} />
        </li>
      ))}
    </Tag>
  );
}

function RichBlocks({
  blocks,
  onAtom,
  onExternal
}: {
  blocks: RichBlock[];
  onAtom: (atom: HermesAtom, label: string) => void;
  onExternal?: (url: string) => void | Promise<void>;
}) {
  return blocks.map((block, index) => {
    const key = `${block.kind}:${index}`;
    switch (block.kind) {
      case 'paragraph':
        return (
          <p key={key}>
            <InlineRuns runs={block.runs} onAtom={onAtom} onExternal={onExternal} />
          </p>
        );
      case 'heading': {
        const Heading = `h${block.level}` as 'h1' | 'h2' | 'h3' | 'h4' | 'h5' | 'h6';
        return (
          <Heading key={key}>
            <InlineRuns runs={block.runs} onAtom={onAtom} onExternal={onExternal} />
          </Heading>
        );
      }
      case 'list':
        return <ListBlock key={key} block={block} onAtom={onAtom} onExternal={onExternal} />;
      case 'quote':
        return (
          <blockquote key={key}>
            <RichBlocks blocks={block.blocks} onAtom={onAtom} onExternal={onExternal} />
          </blockquote>
        );
      case 'code':
        return (
          <figure key={key} className="rich-code-block">
            <figcaption>
              <span>{block.language ?? 'code'}</span>
              <button
                type="button"
                className="ghost rich-code-copy"
                onClick={() => void navigator.clipboard?.writeText(block.text)}
                aria-label={`Copy ${block.language ?? 'code'} block`}
              >
                Copy
              </button>
            </figcaption>
            <pre tabIndex={0}><code data-language={block.language ?? undefined}>{block.text}</code></pre>
          </figure>
        );
      case 'table':
        return (
          <div key={key} className="rich-table-scroll" tabIndex={0} role="region" aria-label="Scrollable table">
            <table>
              <thead>
                <tr>
                  {block.table.header.map((cell, cellIndex) => (
                    <th
                      key={`head:${cellIndex}`}
                      style={{ textAlign: block.table.alignments[cellIndex] ?? 'left' }}
                    >
                      <InlineRuns runs={cell} onAtom={onAtom} onExternal={onExternal} />
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {block.table.rows.map((row, rowIndex) => (
                  <tr key={`row:${rowIndex}`}>
                    {row.map((cell, cellIndex) => (
                      <td
                        key={`cell:${rowIndex}:${cellIndex}`}
                        style={{ textAlign: block.table.alignments[cellIndex] ?? 'left' }}
                      >
                        <InlineRuns runs={cell} onAtom={onAtom} onExternal={onExternal} />
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        );
      case 'rule':
        return <hr key={key} />;
    }
  });
}

export function RichContent({
  text,
  className,
  label,
  preservePlainText = false,
  visibleCharacterLimit = RICH_CONTENT_VISIBLE_CHARACTER_LIMIT,
  expanded = false,
  onOpenAtom,
  onOpenExternal
}: RichContentProps) {
  const [showFull, setShowFull] = useState(expanded);
  const [pendingAtom, setPendingAtom] = useState<{ atom: HermesAtom; label: string } | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const shouldLimit = visibleCharacterLimit > 0 && text.length > visibleCharacterLimit && !showFull;
  const visibleText = shouldLimit ? text.slice(0, visibleCharacterLimit) : text;
  const document = useMemo(
    () => preservePlainText ? null : parseRichContent(visibleText),
    [preservePlainText, visibleText]
  );
  const hiddenCount = shouldLimit ? text.length - visibleText.length : 0;
  const openAtom = (atom: HermesAtom, atomLabel: string) => {
    if (!onOpenAtom) return;
    setActionError(null);
    setPendingAtom({ atom, label: atomLabel });
  };
  const openExternal = onOpenExternal
    ? async (url: string) => {
        setActionError(null);
        try {
          await onOpenExternal(url);
        } catch (cause) {
          setActionError(cause instanceof Error ? cause.message : 'Could not open this link.');
        }
      }
    : undefined;

  return (
    <div
      className={`rich-content${preservePlainText ? ' rich-content--plain' : ''}${className ? ` ${className}` : ''}`}
      aria-label={label}
    >
      {preservePlainText ? (
        <p>{visibleText}</p>
      ) : (
        <RichBlocks blocks={document?.blocks ?? []} onAtom={openAtom} onExternal={openExternal} />
      )}
      {actionError ? <p className="rich-content__action-error" role="alert">{actionError}</p> : null}
      {document?.parserLimited ? (
        <p className="rich-content__limit-note" role="status">
          This message is too large to render fully. The first 200,000 characters are shown safely.
        </p>
      ) : null}
      {hiddenCount > 0 ? (
        <button type="button" className="ghost rich-content__expand" onClick={() => setShowFull(true)}>
          Show full message ({hiddenCount.toLocaleString()} more characters)
        </button>
      ) : null}
      {pendingAtom ? (
        <div className="rich-atom-popover" role="dialog" aria-modal="false" aria-label={`${hermesAtomCategory(pendingAtom.atom)} detail`}>
          <div className={`rich-atom-popover__icon rich-atom--${pendingAtom.atom.kind}`} aria-hidden="true" />
          <div className="rich-atom-popover__copy">
            <span>{hermesAtomCategory(pendingAtom.atom).toUpperCase()}</span>
            <strong>{pendingAtom.label}</strong>
            <p>{hermesAtomDescription(pendingAtom.atom)}</p>
          </div>
          <div className="rich-atom-popover__actions">
            <button type="button" className="ghost" onClick={() => setPendingAtom(null)}>Cancel</button>
            <button
              type="button"
              className="primary"
              onClick={() => {
                const selected = pendingAtom.atom;
                setPendingAtom(null);
                Promise.resolve(onOpenAtom?.(selected)).catch((cause: unknown) => {
                  setActionError(cause instanceof Error ? cause.message : 'Could not open this destination.');
                });
              }}
            >
              {hermesAtomActionLabel(pendingAtom.atom)}
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

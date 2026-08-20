import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from 'react';
import {
  HomeSpaceBudget,
  planColumnGroups,
  planPlacement,
  planVisibleSpanningIDs,
  type HomePlacement,
  type HomeSlot,
  type HomeSpacePlan
} from './homeSpaceBudget.js';
import { prefersReducedMotion, staggerDelayMs } from './motion.js';
import { useElementSize } from './useElementSize.js';
import './home-living-layout.css';

export type HomeLivingLayoutProps = {
  slots: HomeSlot[];
  gutter?: number;
  padding?: number;
  children: (id: string, placement: HomePlacement, plan: HomeSpacePlan) => ReactNode;
};

/**
 * View side of `HomeSpaceBudget`. CSS grid owns the columns; the solver owns
 * Fit / Feed / Breathe — especially the row counts CSS cannot decide.
 */
export function HomeLivingLayout({
  slots,
  gutter = 16,
  padding = 16,
  children
}: HomeLivingLayoutProps) {
  const { ref, width, height } = useElementSize<HTMLDivElement>();
  const [columns, setColumns] = useState(1);
  const reduced = prefersReducedMotion();

  const canvasWidth = Math.max(0, width - padding * 2);
  const canvasHeight = Math.max(0, height - padding * 2);

  useEffect(() => {
    const next = HomeSpaceBudget.columns(width, columns, slots.length);
    if (next !== columns) setColumns(next);
  }, [width, columns, slots.length]);

  const plan = useMemo(
    () =>
      HomeSpaceBudget.resolve({
        canvas: { width: canvasWidth, height: canvasHeight },
        slots,
        gutter,
        columns
      }),
    [canvasWidth, canvasHeight, slots, gutter, columns]
  );

  const spanning = planVisibleSpanningIDs(plan);
  const groups = planColumnGroups(plan);
  const style = {
    '--living-gutter': `${gutter}px`,
    '--living-padding': `${padding}px`,
    '--living-columns': String(Math.max(1, plan.columns))
  } as CSSProperties;

  return (
    <div
      ref={ref}
      className="living-layout"
      data-overflows={plan.overflows ? 'true' : 'false'}
      data-columns={plan.columns}
      style={style}
    >
      {spanning.map((id, index) => (
        <LivingSlot
          key={id}
          id={id}
          plan={plan}
          staggerIndex={index}
          reduced={reduced}
          render={children}
        />
      ))}
      {plan.columns > 1 ? (
        <div className="living-layout__columns">
          {groups.map((group, columnIndex) => (
            <div key={columnIndex} className="living-layout__column">
              {group.map((id, index) => (
                <LivingSlot
                  key={id}
                  id={id}
                  plan={plan}
                  staggerIndex={index + spanning.length}
                  reduced={reduced}
                  render={children}
                />
              ))}
            </div>
          ))}
        </div>
      ) : (
        <div className="living-layout__column">
          {(groups[0] ?? []).map((id, index) => (
            <LivingSlot
              key={id}
              id={id}
              plan={plan}
              staggerIndex={index + spanning.length}
              reduced={reduced}
              render={children}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function LivingSlot({
  id,
  plan,
  staggerIndex,
  reduced,
  render
}: {
  id: string;
  plan: HomeSpacePlan;
  staggerIndex: number;
  reduced: boolean;
  render: HomeLivingLayoutProps['children'];
}) {
  const placement = planPlacement(plan, id);
  if (!placement?.isVisible) return null;
  const hug = placement.height == null || plan.overflows;
  return (
    <div
      className="living-slot living-slot__arrive"
      data-slot={id}
      data-hug={hug ? 'true' : 'false'}
      data-rows={placement.rowCount}
      style={{
        height: hug ? undefined : placement.height ?? undefined,
        flexBasis: hug ? undefined : placement.height ?? undefined,
        ['--living-stagger' as string]: `${staggerDelayMs(staggerIndex, reduced)}ms`
      }}
    >
      {render(id, placement, plan)}
    </div>
  );
}

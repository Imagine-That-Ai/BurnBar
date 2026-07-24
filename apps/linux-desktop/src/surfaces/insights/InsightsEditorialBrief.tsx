import type { InsightsBrief as InsightsBriefModel } from './insightsBrief.js';

export function InsightsEditorialBrief({ brief }: { brief: InsightsBriefModel }) {
  return (
    <section className="insights-panel insights-brief" aria-labelledby="insights-brief-title">
      <div className="insights-brief-heading">
        <div>
          <p className="insights-trend-title">Editorial brief</p>
          <h2 id="insights-brief-title">{brief.headline}</h2>
        </div>
        <span className="insights-brief-source">Derived from usage aggregates</span>
      </div>
      <p className="insights-brief-summary">{brief.summary}</p>
      <ul className="insights-brief-observations">
        {brief.observations.map((observation) => <li key={observation}>{observation}</li>)}
      </ul>
      <nav className="insights-brief-followups" aria-label="Insights follow-up actions">
        {brief.followUps.map((followUp) => (
          <a key={followUp.href} href={followUp.href} title={followUp.reason}>
            {followUp.label}
          </a>
        ))}
      </nav>
    </section>
  );
}

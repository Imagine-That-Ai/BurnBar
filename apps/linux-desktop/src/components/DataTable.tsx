export type DataRow = { id: string; title: string; detail: string };

/**
 * Three-column daemon/fixture data table (`.table.fixture-table`).
 * Surfaces render honest data provenance above the table via `sourceLabel`.
 */
export function DataTable({ rows, sourceLabel }: { rows: DataRow[]; sourceLabel: string }) {
  return (
    <>
      <p className="muted data-source">{`Data source: ${sourceLabel}`}</p>
      <table className="table fixture-table">
        <thead>
          <tr>
            <th>ID</th>
            <th>Title</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.id}>
              <td>{row.id}</td>
              <td>{row.title}</td>
              <td>{row.detail}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  );
}

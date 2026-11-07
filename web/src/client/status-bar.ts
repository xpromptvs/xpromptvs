import { statusCells, type StatusInfo, type StatusCell } from "../lib/ice-stats";

/// The 38px footer. Renders `statusCells` into `#status-cells` with a 1px divider between cells and sets
/// the connection dot's state. Thin by design — all the decisions live in `statusCells` (tested).
export class StatusBar {
  constructor(private readonly els: { dot: HTMLElement; cells: HTMLElement }) {}

  render(info: StatusInfo): void {
    this.els.dot.dataset.state = info.state;
    this.els.cells.replaceChildren(...statusCells(info).flatMap((c, i) => this.renderCell(c, i > 0)));
  }

  private renderCell(cell: StatusCell, divider: boolean): HTMLElement[] {
    const out: HTMLElement[] = [];
    if (divider) {
      const d = document.createElement("span");
      d.className = "status-divider";
      out.push(d);
    }
    const el = document.createElement("span");
    el.className = "status-cell";
    el.dataset.cell = cell.key;
    el.textContent = cell.text;
    // The transport ("p2p"/"relay") rides INSIDE the state cell in a secondary colour, so it reads as a
    // qualifier on "connected" rather than as another independent status item.
    if (cell.detail) {
      const d = document.createElement("span");
      d.className = "status-detail";
      d.textContent = cell.detail;
      el.append(" ", d);
    }
    out.push(el);
    return out;
  }
}

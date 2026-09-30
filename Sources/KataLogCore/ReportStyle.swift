enum ReportStyle {
    static let css = #"""
    :root {
      color-scheme: light;
      --bg: #f7f7f5; --surface: #fff; --surface-2: #efefec; --ink: #171717;
      --muted: #62625e; --line: #deded8; --soft-line: #ecece7; --accent: #176a61;
      --accent-soft: #e9f3ef; --amber: #865100; --amber-soft: #fff1d6;
      --red: #a93336; --red-soft: #fcebec; --focus: #176a61;
      --shadow: 0 2px 4px #17171703, 0 12px 30px #17171703;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-synthesis: none; -webkit-font-smoothing: antialiased;
      font-size: 14px; line-height: 1.55;
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        color-scheme: dark;
        --bg: #0b0b0b; --surface: #191919; --surface-2: #242424; --ink: #f3f3f1;
        --muted: #b0b0aa; --line: #3c3c38; --soft-line: #2d2d2a; --accent: #80c9b9;
        --accent-soft: #203730; --amber: #f0be67; --amber-soft: #3b2f1a;
        --red: #f2a3a5; --red-soft: #3f2327; --focus: #80c9b9;
        --shadow: none;
      }
    }
    :root[data-theme="dark"] {
      color-scheme: dark;
      --bg: #0b0b0b; --surface: #191919; --surface-2: #242424; --ink: #f3f3f1;
      --muted: #b0b0aa; --line: #3c3c38; --soft-line: #2d2d2a; --accent: #80c9b9;
      --accent-soft: #203730; --amber: #f0be67; --amber-soft: #3b2f1a;
      --red: #f2a3a5; --red-soft: #3f2327; --focus: #80c9b9;
      --shadow: none;
    }
    *, *::before, *::after { box-sizing: border-box; }
    [hidden] { display: none !important; }
    html { scroll-behavior: smooth; scroll-padding-top: 100px; }
    body { margin: 0; background: var(--bg); color: var(--ink); }
    button, input, select { font: inherit; color: inherit; }
    button, select, summary { -webkit-tap-highlight-color: transparent; }
    button, select { cursor: pointer; }
    button, input, select {
      border: 1px solid var(--line); border-radius: 9px; background: var(--surface);
      min-height: 40px; padding: 8px 12px;
    }
    button { font-size: .9rem; font-weight: 600; }
    button:hover { background: var(--surface-2); }
    button:active { transform: translateY(1px); }
    button:disabled { cursor: default; opacity: .5; }
    :where(button, select, input, summary, a):focus-visible {
      outline: 3px solid var(--focus); outline-offset: 4px;
    }
    input::placeholder { color: var(--muted); opacity: 1; }
    a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 3px; }
    a:hover { text-decoration-thickness: 2px; }
    h1, h2, h3, p { margin: 0; }
    h1, h2, h3 { line-height: 1.2; font-weight: 650; letter-spacing: -.025em; }
    h1 { font-size: clamp(2.15rem, 4.3vw, 3.55rem); }
    h2 { font-size: 1.45rem; }
    h3 { font-size: 1.06rem; }
    p, li, td, .drone-meta, .log-meta { overflow-wrap: anywhere; }
    strong { font-weight: 650; }
    small { font-size: .84em; }
    .muted { color: var(--muted); }
    .mono, code, .raw {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: .86em; overflow-wrap: anywhere; word-break: break-word;
    }
    .raw, code { white-space: pre-wrap; }
    .raw { line-height: 1.65; }
    .topbar { border-bottom: 1px solid var(--line); background: var(--bg); }
    .topbar-inner {
      max-width: 1344px; margin: 0 auto; min-height: 78px; padding: 16px 32px;
      display: flex; align-items: center; gap: 36px;
    }
    .brand { display: inline-flex; align-items: center; gap: 11px; flex-shrink: 0;
      color: var(--ink); text-decoration: none; font-size: 1.4rem; font-weight: 750;
      letter-spacing: -.06em; }
    .brand svg { width: 30px; height: 34px; fill: currentColor; }
    .topbar nav { display: flex; align-items: center; gap: 24px; flex-wrap: wrap; }
    .topbar nav a { color: var(--muted); font-size: .88rem; font-weight: 550; text-decoration: none; }
    .topbar nav a:hover { color: var(--ink); text-decoration: underline; }
    .actions { margin-left: auto; display: flex; align-items: center; gap: 8px; }
    .actions button { white-space: nowrap; }
    .actions .primary, button.primary {
      background: var(--ink); border-color: var(--ink); color: var(--bg);
    }
    .actions .primary:hover, button.primary:hover { opacity: .85; }
    .report-shell { max-width: 1344px; margin: 0 auto; padding: 48px 32px 40px; }
    .hero { margin-bottom: 30px; max-width: 920px; }
    .eyebrow {
      display: block; color: var(--muted); font-size: .72rem; font-weight: 700;
      letter-spacing: .13em; text-transform: uppercase; margin-bottom: 12px;
    }
    .hero .lede { max-width: 770px; color: var(--muted); font-size: 1.08rem; margin-top: 18px; line-height: 1.65; }
    .hero .meta { display: flex; flex-wrap: wrap; gap: 8px 18px; color: var(--muted); font-size: .84rem; margin-top: 20px; }
    .pill { display: inline-flex; align-items: center; gap: 5px; border: 1px solid var(--line);
      border-radius: 100px; padding: 3px 9px; color: var(--muted); font-size: .78rem; line-height: 1.5; }
    .scope-bar {
      display: flex; flex-wrap: wrap; align-items: flex-end; gap: 12px;
      padding: 20px; border: 1px solid var(--line); border-radius: 16px;
      background: var(--surface); margin-bottom: 20px;
    }
    .filter-controls { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 12px;
      width: 100%; min-width: 0; }
    .scope-bar label { display: flex; flex-direction: column; gap: 6px;
      color: var(--muted); font-size: .78rem; font-weight: 600; min-width: 140px; flex: 1 1 150px; }
    .scope-bar .search-label, .scope-bar label:has(input[type="search"]) { flex-grow: 2; }
    .scope-bar input, .scope-bar select { width: 100%; min-width: 0; font-size: .9rem; font-weight: 400; color: var(--ink); }
    .scope-bar button { flex-shrink: 0; }
    .filter-status { flex-basis: 100%; color: var(--muted); font-size: .83rem; }
    .stats { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 14px; margin: 0 0 20px; }
    .stat { border: 1px solid var(--line); background: var(--surface); border-radius: 16px;
      padding: 22px 24px; box-shadow: var(--shadow); min-width: 0; }
    .stat label, .stat .label, .stat > span { display: block; color: var(--muted); font-size: .85rem; font-weight: 550; }
    .stat strong { display: block; font-size: clamp(1.85rem, 3vw, 2.5rem); line-height: 1.25;
      margin: 10px 0 5px; font-weight: 650; letter-spacing: -.055em; font-variant-numeric: tabular-nums; }
    .stat strong em { font-size: .42em; font-style: normal; font-weight: 500;
      color: var(--muted); letter-spacing: -.015em; white-space: nowrap; }
    .stat small { display: block; color: var(--muted); font-size: .77rem; }
    .stat-label, .heading-with-help { display: flex; align-items: center; gap: 7px; color: var(--muted); font-size: .85rem; }
    .heading-with-help { color: var(--ink); }
    .report-help { display: inline-block; position: relative; flex-shrink: 0; font-size: 12px; font-weight: 400; }
    .report-help > summary { display: inline-flex; align-items: center; justify-content: center; border-radius: 50%; width: 24px; height: 24px; color: var(--muted); }
    .report-help > summary:hover { background: var(--surface-2); color: var(--ink); }
    .report-help > summary::after { display: none; }
    .report-help > p { position: absolute; top: 100%; left: 0; z-index: 3; width: min(320px, 76vw); padding: 13px; border: 1px solid var(--line); border-radius: 10px; background: var(--surface); color: var(--ink); font-size: .85rem; box-shadow: var(--shadow); }
    .stat:nth-last-child(-n+2) .report-help > p { left: auto; right: 0; }
    .assessment-legend { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; color: var(--muted); font-size: .83rem; margin: 18px 0; }
    .log-assessment { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; padding: 3px 7px; font-size: .73rem; font-weight: 600; color: var(--muted); }
    .log-assessment.red { color: var(--red); background: var(--red-soft); border-color: var(--red); }
    .log-assessment.orange, .log-assessment.yellow { color: var(--amber); background: var(--amber-soft); border-color: var(--amber); }
    .dashboard-grid { display: grid; grid-template-columns: minmax(0, 1.12fr) minmax(0, 1fr); gap: 20px; margin-bottom: 20px; }
    .panel { background: var(--surface); border: 1px solid var(--line); border-radius: 18px;
      padding: 25px 26px; box-shadow: var(--shadow); min-width: 0; }
    .panel-heading { display: flex; flex-wrap: wrap; align-items: flex-start; justify-content: space-between; gap: 8px 20px; margin-bottom: 22px; }
    .panel-heading h2 { font-size: 1.12rem; letter-spacing: -.015em; }
    .panel-heading p { color: var(--muted); font-size: .82rem; margin-top: 7px; }
    .chart-space { min-width: 0; }
    .chart-legend { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 20px;
      font-size: .78rem; color: var(--muted); margin-top: 16px; }
    .chart-legend > span { display: inline-flex; align-items: center; gap: 7px; }
    .chart-legend button { padding: 5px 9px; min-height: 32px; font-size: .78rem; font-weight: 500; }
    .chart-legend button[aria-pressed="true"] { color: var(--accent); background: var(--accent-soft); border-color: var(--accent); }
    .chart-help { margin-top: 16px; font-size: .79rem; line-height: 1.55; }
    .legend-dot { display: inline-block; width: 8px; height: 8px; background: var(--accent); border-radius: 50%; flex-shrink: 0; }
    .legend-dot.neutral { background: var(--line); }
    .legend-total, .legend-alert { display: inline-block; width: 9px; height: 9px;
      border-radius: 2px; background: var(--line); flex-shrink: 0; }
    .legend-alert { background: var(--accent); }
    .family-bars { display: flex; flex-direction: column; gap: 6px; }
    .family-row {
      display: grid; grid-template-columns: minmax(88px, .75fr) minmax(50px, 1.2fr) 30px;
      align-items: center; gap: 14px; width: 100%; border-color: transparent;
      border-radius: 8px; background: transparent; padding: 10px 8px; min-height: 42px;
      text-align: left; font-size: .88rem; font-weight: 500;
    }
    a.family-row { color: var(--ink); text-decoration: none; }
    .family-row:hover { background: var(--surface-2); }
    .family-row[aria-pressed="true"], .family-row.is-active { background: var(--accent-soft); color: var(--accent); }
    .family-row > :first-child { overflow-wrap: anywhere; }
    .family-row > :last-child { font-variant-numeric: tabular-nums; text-align: right; font-weight: 650; }
    .bar-track { display: block; height: 8px; border-radius: 20px; background: var(--surface-2); overflow: hidden; }
    .bar-fill { display: block; height: 100%; border-radius: inherit; background: var(--accent); min-width: 0; }
    .radar { margin: -6px auto 0; width: 100%; max-width: 420px; }
    .radar svg, svg.radar { display: block; width: 100%; height: auto; overflow: visible; }
    .radar-grid { fill: none; stroke: var(--line); stroke-width: 1; }
    .radar-shape { fill: var(--accent); fill-opacity: .14; stroke: var(--accent); stroke-width: 2; stroke-linejoin: round; }
    .radar-dot { fill: var(--accent); stroke: var(--surface); stroke-width: 2; cursor: pointer; }
    .radar-dot:hover { stroke: var(--accent); stroke-width: 3; }
    .radar-dot:focus-visible { outline: 3px solid var(--focus); outline-offset: 4px; }
    .radar-label { fill: var(--muted); font-family: inherit; font-size: 11px; font-weight: 500; }
    .timeline {
      display: flex; align-items: stretch; gap: 10px; height: 206px;
      padding: 4px 0 0; overflow-x: auto; overscroll-behavior-x: contain;
    }
    .timeline-column { display: flex; flex: 1 0 36px; min-width: 36px; flex-direction: column;
      align-items: stretch; justify-content: flex-end; position: relative; gap: 8px; }
    .timeline-column button, button.timeline-column {
      display: flex; flex-direction: column; align-items: center; justify-content: flex-end;
      flex: 1; border-color: transparent; padding: 5px 3px; background: transparent;
      min-width: 30px; min-height: 0; border-radius: 7px; position: relative;
    }
    .timeline-column button:hover, button.timeline-column:hover { background: var(--surface-2); }
    .timeline-column button[aria-pressed="true"], button.timeline-column[aria-pressed="true"] {
      outline: 1px solid var(--accent); outline-offset: 0; background: var(--accent-soft);
    }
    .timeline-bars { height: 155px; width: 100%; max-width: 38px; display: flex; align-items: flex-end; position: relative; }
    .timeline-total { display: block; width: 100%; background: var(--line); border-radius: 5px 5px 0 0; min-height: 2px; position: relative; }
    .timeline-alert { display: block; background: var(--accent); border-radius: 5px 5px 0 0; width: 100%; position: absolute; bottom: 0; left: 0; }
    .timeline-label { display: block; width: 100%; text-align: center; color: var(--muted); font-size: .67rem;
      white-space: nowrap; margin-top: 9px; line-height: 1.25; font-weight: 500; }
    .timeline-value { color: var(--muted); font-size: .73rem; margin-bottom: 5px; font-variant-numeric: tabular-nums; }
    .section-heading { display: flex; justify-content: space-between; align-items: baseline; flex-wrap: wrap;
      gap: 10px 24px; margin: 42px 0 18px; }
    .section-heading p { color: var(--muted); font-size: .85rem; max-width: 760px; }
    .group-list { display: flex; flex-direction: column; gap: 10px; }
    details { min-width: 0; }
    summary { cursor: pointer; list-style: none; position: relative; }
    summary::-webkit-details-marker { display: none; }
    summary::after { content: "+"; color: var(--muted); font-size: 1.4rem; font-weight: 400;
      line-height: 1; flex-shrink: 0; width: 18px; text-align: center; }
    details[open] > summary::after { content: "−"; }
    .alert-group, .log-card { border: 1px solid var(--line); background: var(--surface); border-radius: 14px; }
    .alert-group > summary { display: flex; align-items: center; gap: 16px; padding: 19px 22px; border-radius: 14px; }
    .alert-group > summary:hover, .log-card > summary:hover { background: var(--surface-2); }
    .alert-group[open] > summary, .log-card[open] > summary { border-radius: 14px 14px 0 0; }
    .severity { display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0;
      border-radius: 6px; padding: 4px 7px; font-size: .66rem; font-weight: 750; letter-spacing: .04em;
      line-height: 1.4; background: var(--surface-2); color: var(--muted); }
    .severity.warning, .severity.warn, .severity[data-level="WARNING"], .severity[data-level="WARN"] { color: var(--amber); background: var(--amber-soft); }
    .severity.danger, .severity.error, .severity.critical, .severity.alert, .severity.emergency,
    .severity[data-level="ERROR"], .severity[data-level="CRITICAL"], .severity[data-level="ALERT"], .severity[data-level="EMERGENCY"] {
      color: var(--red); background: var(--red-soft);
    }
    .group-heading { flex: 1; min-width: 0; font-weight: 600; font-size: .94rem; overflow-wrap: anywhere; }
    .group-heading > strong { display: block; font-weight: 600; }
    .group-heading small, .group-heading .muted { display: block; font-size: .8rem; font-weight: 400; margin-top: 4px; }
    .group-count { color: var(--muted); font-size: .78rem; text-align: right; flex-shrink: 0; font-variant-numeric: tabular-nums; }
    .group-count strong { color: var(--ink); font-size: .96rem; }
    .group-body { border-top: 1px solid var(--soft-line); padding: 22px; }
    .group-body > p { margin-bottom: 12px; font-size: .86rem; }
    .group-body > p.raw { padding: 13px 15px; background: var(--bg); border: 1px solid var(--soft-line);
      border-radius: 8px; font-size: .8rem; }
    .group-body > .table-wrap { margin-top: 16px; }
    .explanation { background: var(--bg); border: 1px solid var(--soft-line); border-radius: 11px;
      padding: 20px; margin-bottom: 20px; }
    .explanation .eyebrow { font-size: .66rem; margin-bottom: 9px; }
    .explanation h3 { margin-bottom: 10px; }
    .explanation p { font-size: .9rem; }
    .explanation p + p { margin-top: 10px; }
    .checks { padding-left: 20px; margin: 15px 0 0; font-size: .87rem; }
    .checks li + li { margin-top: 5px; }
    .limits { color: var(--muted); font-size: .83rem !important; margin-top: 16px !important;
      padding-top: 13px; border-top: 1px solid var(--line); }
    .source-links { display: flex; flex-wrap: wrap; gap: 8px 20px; font-size: .79rem; margin-top: 14px; }
    .table-wrap { width: 100%; overflow-x: auto; border: 1px solid var(--soft-line); border-radius: 10px; }
    table { width: 100%; border-collapse: collapse; font-size: .82rem; text-align: left; }
    th, td { padding: 11px 13px; border-bottom: 1px solid var(--soft-line); vertical-align: top; }
    th { color: var(--muted); font-size: .72rem; font-weight: 650; background: var(--bg); }
    tr:last-child > td { border-bottom: 0; }
    td:first-child, th:first-child { padding-left: 16px; }
    td:last-child, th:last-child { padding-right: 16px; }
    td .raw { font-size: .92em; }
    td.raw { font-size: .77rem; }
    td > small { display: block; color: var(--muted); margin-top: 4px; }
    .message-table { table-layout: fixed; }
    .message-table th:first-child { width: 76px; }
    .message-table th:nth-child(2) { width: 94px; }
    .message-table th:nth-child(3) { width: 120px; }
    .drone-section { margin-top: 26px; }
    .drone-section > h2 { font-size: 1.15rem; margin-bottom: 6px; }
    .drone-meta { color: var(--muted); font-size: .82rem; margin-bottom: 16px; }
    .log-card { margin-top: 10px; }
    .log-card > summary { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 16px; padding: 18px 22px; border-radius: 14px; }
    .log-title { min-width: 0; flex: 1 1 230px; font-size: .92rem; font-weight: 600; overflow-wrap: anywhere; }
    .log-title small { display: block; color: var(--muted); margin-top: 4px; font-size: .8rem; font-weight: 400; }
    .log-status { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; padding: 3px 7px;
      color: var(--muted); font-size: .73rem; font-weight: 500; }
    .log-status.partial, .log-status.warning { color: var(--amber); border-color: var(--amber); }
    .log-status.error, .log-status.danger { color: var(--red); border-color: var(--red); }
    .log-meta { color: var(--muted); font-size: .78rem; }
    .log-body { border-top: 1px solid var(--soft-line); padding: 24px; }
    .log-body > h3 { margin: 25px 0 12px; }
    .log-body > p { margin: 10px 0; font-size: .86rem; }
    .log-body > p + .table-wrap { margin-top: 15px; }
    .detail-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 15px; margin-bottom: 20px; }
    .detail-box { background: var(--bg); border: 1px solid var(--soft-line); border-radius: 10px; padding: 17px 18px; min-width: 0; }
    .detail-box h3 { font-size: .9rem; margin-bottom: 10px; }
    .detail-box p { font-size: .82rem; }
    .detail-box p + p { margin-top: 7px; }
    .detail-box dl { margin: 0; font-size: .82rem; display: grid; grid-template-columns: minmax(0, .7fr) minmax(0, 1fr); gap: 7px 12px; }
    .detail-box dt { color: var(--muted); }
    .detail-box dd { margin: 0; overflow-wrap: anywhere; }
    .coverage-list { margin: 0; padding-left: 20px; color: var(--muted); font-size: .85rem; }
    .coverage-list li + li { margin-top: 7px; }
    .technical { border: 1px solid var(--line); border-radius: 10px; margin: 20px 0; }
    .technical > summary { display: flex; justify-content: space-between; align-items: center; gap: 15px;
      padding: 13px 16px; font-size: .85rem; font-weight: 600; }
    .technical > :not(summary) { margin: 0 16px 16px; }
    .technical > p, .technical li { font-size: .8rem; }
    .technical .table-wrap { width: auto; }
    .empty-state { border: 1px dashed var(--line); border-radius: 12px; padding: 35px 24px;
      text-align: center; color: var(--muted); font-size: .9rem; }
    .empty-state h3 { color: var(--ink); margin-bottom: 8px; }
    .notice { border-left: 3px solid var(--line); padding: 12px 16px; color: var(--muted);
      font-size: .83rem; margin: 18px 0; background: var(--surface-2); border-radius: 0 8px 8px 0; }
    .notice.warning { border-left-color: var(--amber); }
    .report-footer { border-top: 1px solid var(--line); padding-top: 22px; margin-top: 45px;
      display: flex; flex-wrap: wrap; justify-content: space-between; gap: 12px 30px;
      color: var(--muted); font-size: .78rem; }
    .report-footer p { max-width: 800px; }
    #sources { margin-top: 36px; }
    #sources > .section-heading { margin: 0 0 18px; }
    #sources > p { margin-top: 14px; color: var(--muted); font-size: .85rem; }
    @media (max-width: 1000px) {
      .topbar-inner { gap: 22px; }
      .topbar nav { gap: 14px; }
      .stat { padding: 20px; }
      .dashboard-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .panel { padding: 22px; }
      .family-row { gap: 9px; grid-template-columns: minmax(70px, 1fr) minmax(45px, 1fr) 25px; }
    }
    @media (max-width: 800px) {
      .topbar-inner { flex-wrap: wrap; gap: 12px 20px; padding: 16px 24px; }
      .topbar nav { order: 3; flex-basis: 100%; padding-top: 2px; }
      .report-shell { padding: 34px 24px; }
      .stats { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
      .dashboard-grid { grid-template-columns: minmax(0, 1fr); }
      .family-row { grid-template-columns: minmax(90px, .7fr) minmax(90px, 1.5fr) 35px; }
      .detail-grid { grid-template-columns: minmax(0, 1fr); }
      .group-count { max-width: 95px; }
      .message-table { table-layout: auto; min-width: 540px; }
      .message-table th:first-child { width: 65px; }
    }
    @media (max-width: 480px) {
      :root { font-size: 13px; }
      .topbar-inner { padding: 14px 16px; gap: 12px; }
      .brand { font-size: 1.45rem; gap: 8px; }
      .brand svg { width: 25px; height: 30px; }
      .actions { gap: 6px; }
      .actions button { padding: 7px 9px; font-size: .8rem; }
      .topbar nav { justify-content: space-between; gap: 8px; }
      .report-shell { padding: 28px 16px; }
      .hero { margin-bottom: 22px; }
      .hero .lede { font-size: 1rem; margin-top: 14px; }
      .hero .meta { gap: 6px 14px; margin-top: 16px; }
      .scope-bar { padding: 15px; gap: 10px; }
      .filter-controls { gap: 10px; }
      .scope-bar label { min-width: 0; flex-basis: calc(50% - 10px); }
      .scope-bar .search-label, .scope-bar label:has(input[type="search"]) { flex-basis: 100%; }
      .scope-bar button { min-height: 38px; }
      .stat { padding: 17px; border-radius: 13px; }
      .stat strong { font-size: 2.15rem; margin-top: 7px; }
      .stat small { font-size: .75rem; }
      .panel { padding: 20px 17px; border-radius: 15px; }
      .family-row { grid-template-columns: minmax(83px, 1fr) minmax(60px, 1.15fr) 24px; padding-left: 3px; padding-right: 3px; gap: 9px; }
      .section-heading { margin-top: 32px; }
      .alert-group > summary { padding: 16px; gap: 10px; flex-wrap: wrap; }
      .alert-group > summary .severity { order: 0; }
      .alert-group > summary .group-heading { flex-basis: calc(100% - 86px); order: 1; }
      .alert-group > summary .group-count { order: 2; max-width: none; flex: 1; text-align: left; }
      .alert-group > summary::after { order: 3; }
      .group-body, .log-body { padding: 16px; }
      .explanation { padding: 16px; }
      .log-card > summary { padding: 16px; gap: 7px 10px; }
      .log-title { flex-basis: calc(100% - 85px); }
      .log-meta { flex-basis: calc(100% - 30px); }
      .detail-box { padding: 15px; }
      .table-wrap table:not(.message-table) { min-width: 370px; }
      .report-footer { margin-top: 32px; }
    }
    @media (prefers-reduced-motion: reduce) {
      html { scroll-behavior: auto; }
      *, *::before, *::after { animation: none !important; transition: none !important; }
    }
    @page { margin: 14mm; }
    @media print {
      :root, :root[data-theme], :root:not([data-theme="light"]) {
        color-scheme: light; --bg: #fff; --surface: #fff; --surface-2: #f1f1ee;
        --ink: #171717; --muted: #50504b; --line: #c9c9c3; --soft-line: #deded8;
        --accent: #176a61; --accent-soft: #e9f3ef; --amber: #754700; --amber-soft: #fff1d6;
        --red: #94252a; --red-soft: #fcebec; --shadow: none; font-size: 10px;
      }
      html, body { width: auto; min-width: 0; background: #fff; color: #171717; }
      body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      .topbar { position: static; background: #fff; }
      .topbar-inner { min-height: 0; max-width: none; padding: 0 0 13px; }
      .topbar nav, .topbar .actions, .filter-controls, #expand-logs, .scope-bar label, .scope-bar > button,
      .scope-bar input, .scope-bar select, .no-print { display: none !important; }
      .detail-pagination, .report-help { display: none !important; }
      .report-shell { max-width: none; padding: 24px 0 0; }
      h1 { font-size: 30px; }
      h2 { font-size: 17px; }
      .hero { max-width: none; margin-bottom: 18px; }
      .hero .lede { font-size: 11px; max-width: none; }
      .hero .meta { margin-top: 10px; }
      .scope-bar { padding: 9px 12px; border-radius: 6px; margin-bottom: 13px; }
      .filter-status { display: block !important; color: #50504b; }
      .stats { grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 10px; margin-bottom: 13px; }
      .stat { padding: 12px; border-radius: 8px; }
      .stat strong { font-size: 24px; margin: 5px 0 3px; }
      .dashboard-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 13px; }
      .panel { padding: 15px; border-radius: 8px; }
      .panel-heading { margin-bottom: 13px; }
      .family-row { grid-template-columns: minmax(62px, 1fr) minmax(40px, 1fr) 20px; gap: 7px;
        font-size: 9px; min-height: 26px; padding: 5px 2px; }
      .radar { max-width: 295px; }
      .radar-label { font-size: 11px; fill: #50504b; }
      .timeline { height: 155px; overflow: visible; gap: 5px; }
      .timeline-column { flex-basis: 0; min-width: 0; }
      .timeline-column button, button.timeline-column { min-width: 0; padding-left: 1px; padding-right: 1px; }
      .timeline-bars { height: 110px; }
      .timeline-label { font-size: 7px; white-space: normal; }
      .section-heading { margin-top: 26px; }
      .alert-group, .log-card { border-radius: 7px; }
      .alert-group > summary, .log-card > summary { padding: 11px 13px; }
      summary::after { display: none; }
      details > :not(summary) { display: block !important; }
      details > :not(summary)[hidden] { display: none !important; }
      .group-body, .log-body { padding: 13px; }
      .explanation { padding: 13px; }
      .detail-grid { display: grid !important; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
      .detail-box { padding: 12px; }
      .table-wrap { overflow: visible; width: 100%; border-radius: 0; }
      table, .table-wrap table:not(.message-table), .message-table {
        min-width: 0; width: 100%; table-layout: fixed; font-size: 9px;
      }
      th, td { padding: 7px 8px; overflow-wrap: anywhere; word-break: break-word; }
      td:first-child, th:first-child { padding-left: 8px; }
      td:last-child, th:last-child { padding-right: 8px; }
      .message-table th:first-child { width: 47px; }
      .message-table th:nth-child(2) { width: 65px; }
      .message-table th:nth-child(3) { width: 78px; }
      td.raw { font-size: 8.5px; }
      .raw, code, .mono { white-space: pre-wrap; overflow: visible; max-height: none; }
      thead { display: table-header-group; }
      tr, .stat, .panel, .explanation, .detail-box { break-inside: avoid; }
      h1, h2, h3, summary, .section-heading, .drone-meta { break-after: avoid; }
      .alert-group, .log-card, .drone-section, .group-body, .log-body { break-inside: auto; }
      a { color: #176a61; }
      .source-links a::after { content: " (" attr(href) ")"; font-size: 8px; overflow-wrap: anywhere; }
      .report-footer { margin-top: 25px; padding-top: 15px; }
      [hidden] { display: none !important; }
    }
    """#
}

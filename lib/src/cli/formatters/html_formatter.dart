import '../../reporting/run_report.dart';
import 'json_formatter.dart';
import 'report_formatter.dart';

/// Formats a report as a self-contained, interactive HTML document.
class HtmlFormatter extends ReportFormatter {
  /// Creates an HTML formatter.
  const HtmlFormatter();

  @override
  String format(RunReport report) {
    final json = const JsonFormatter().format(report);
    final fallback = _fallbackMarkup(report);
    return r'''<!doctype html>
<html lang="en" class="report-pending">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
  <title>flutter_pruner report</title>
  <style>
    :root { color-scheme: light; --bg:#f6f8fb; --surface:#fff; --text:#172033; --muted:#61708a; --line:#dce3ee; --accent:#3457d5; --on-accent:#fff; --hero-bg:#1e3a5f; --hero-text:#fff; --hero-muted:#dce8f5; --hero-warning:#fff0b3; --safe:#087b52; --safe-bg:#eaf8f1; --high:#8a4b00; --high-bg:#fff4dc; --review:#0b6f8a; --review-bg:#eaf8fc; --protected:#8d3c8c; --danger:#b42318; --danger-bg:#fff0ee; --shadow:0 10px 30px rgba(31,43,73,.08); }
    :root[data-theme="dark"] { color-scheme: dark; --bg:#111723; --surface:#182131; --text:#edf3ff; --muted:#aab8d0; --line:#344056; --accent:#9bb1ff; --on-accent:#101827; --hero-bg:#1e293b; --hero-text:#f8fafc; --hero-muted:#cbd5e1; --hero-warning:#fde68a; --safe:#62d7a7; --safe-bg:#173a31; --high:#f9bc63; --high-bg:#3c2e18; --review:#72d4ed; --review-bg:#173642; --protected:#e99be8; --danger:#ff9c93; --danger-bg:#442423; --shadow:none; }
    * { box-sizing:border-box; } body { margin:0; background:var(--bg); color:var(--text); font:16px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    button,input,select { min-height:44px; font:inherit; } button { cursor:pointer; } button:focus-visible,input:focus-visible,select:focus-visible,summary:focus-visible,a:focus-visible { outline:3px solid var(--accent); outline-offset:2px; }
    [hidden] { display:none!important; } .page { max-width:1440px; margin:auto; padding:16px; } .hero { background:var(--hero-bg); color:var(--hero-text); border-radius:16px; padding:18px 22px; box-shadow:var(--shadow); }
    .hero-heading { display:flex; align-items:flex-start; justify-content:space-between; gap:18px; flex-wrap:wrap; } .eyebrow { margin:0 0 3px; font-weight:700; letter-spacing:.08em; text-transform:uppercase; font-size:.7rem; opacity:.83; } h1 { margin:0; font-size:clamp(1.55rem,3vw,2.2rem); line-height:1.12; } h2 { margin:0; font-size:1.08rem; } h3 { margin:0; font-size:.96rem; }
    .skip-link { position:fixed; z-index:10; top:8px; left:8px; padding:10px 14px; color:var(--on-accent); background:var(--accent); border-radius:8px; transform:translateY(-150%); } .skip-link:focus { transform:none; }
    .hero-meta,.actions,.filters,.chips,.kpis,.grid { display:flex; gap:8px; flex-wrap:wrap; } .hero-meta { color:var(--hero-muted); justify-content:flex-end; } .pill,.chip { border:1px solid currentColor; border-radius:999px; padding:5px 10px; font-size:.78rem; font-weight:650; } button.chip { display:inline-flex; min-height:44px; align-items:center; }
    main { display:grid; gap:12px; margin-top:12px; } .card { background:var(--surface); border:1px solid var(--line); border-radius:14px; padding:16px; box-shadow:var(--shadow); } .section-head { display:flex; gap:12px; align-items:center; justify-content:space-between; flex-wrap:wrap; margin-bottom:12px; }
    .summary-grid { display:grid; grid-template-columns:minmax(0,1.2fr) minmax(340px,.8fr); gap:12px; } .decision-banner { margin-bottom:12px; padding:12px 14px; border:1px solid var(--line); border-left:5px solid currentColor; border-radius:10px; background:var(--bg); } .decision-banner h3 { font-size:1.1rem; } .decision-banner.safe { background:var(--safe-bg); } .decision-banner.high { background:var(--high-bg); } .decision-banner.review { background:var(--review-bg); } .decision-banner.danger { background:var(--danger-bg); } .decision-facts { display:flex; gap:6px; flex-wrap:wrap; margin-top:10px; } .decision-fact { color:var(--text); background:var(--surface); border:1px solid var(--line); border-radius:999px; padding:4px 9px; font-size:.8rem; } .kpis { display:grid; grid-template-columns:repeat(4,minmax(90px,1fr)); gap:8px; } .kpi { border:1px solid var(--line); border-radius:10px; padding:9px 11px; background:color-mix(in srgb,var(--surface) 90%,var(--bg)); } .kpi strong { display:inline; margin-right:6px; font-size:1.3rem; line-height:1.1; } .kpi span { color:var(--muted); font-size:.78rem; }
    .safe { color:var(--safe); } .high { color:var(--high); } .review { color:var(--review); } .protected { color:var(--protected); } .danger { color:var(--danger); }
    .next-card { display:grid; align-content:start; } .action-copy { display:grid; grid-template-columns:minmax(0,1fr) auto; gap:8px; align-items:center; margin-top:10px; } code { min-width:0; overflow:auto; display:block; white-space:nowrap; padding:8px 10px; border-radius:8px; color:var(--text); background:var(--bg); border:1px solid var(--line); } .button { border:1px solid var(--accent); background:var(--accent); color:var(--on-accent); border-radius:8px; padding:9px 12px; font-weight:700; font-size:.86rem; transition:background-color .18s ease,color .18s ease,border-color .18s ease; } .button.secondary { color:var(--text); background:transparent; border-color:var(--line); } .button:hover { filter:brightness(.96); } .feedback { min-height:1.5em; margin:8px 0 0; color:var(--safe); font-size:.86rem; } .feedback.danger { color:var(--danger); }
    .toolbar { display:flex; gap:8px; flex-wrap:wrap; } .findings-head { align-items:flex-start; } .section-title-row { display:flex; align-items:center; gap:8px; } .filters { align-items:flex-end; flex:1; justify-content:flex-end; } .filter-control { display:grid; gap:3px; min-width:130px; color:var(--muted); font-size:.78rem; font-weight:650; } .filter-control.search-control { flex:1; min-width:min(100%,260px); } input,select { width:100%; color:var(--text); background:var(--surface); border:1px solid var(--line); border-radius:8px; padding:8px 10px; } .chip { color:var(--muted); background:transparent; } .chip[aria-pressed="true"] { color:var(--on-accent); background:var(--accent); border-color:var(--accent); } .filter-actions { display:flex; align-items:flex-end; gap:8px; } .finding-controls { display:flex; justify-content:center; margin-top:12px; } .print-context { display:none; }
    .finding-list { display:grid; gap:6px; } details { border:1px solid var(--line); border-radius:10px; overflow:hidden; background:var(--surface); } summary { cursor:pointer; padding:10px 12px; list-style:none; } summary::-webkit-details-marker { display:none; } .finding-summary { display:grid; grid-template-columns:auto minmax(0,1fr) auto; gap:10px; align-items:center; } .finding-title { font-weight:750; line-height:1.25; } .finding-subtitle { min-width:0; color:var(--muted); font-size:.84rem; overflow-wrap:anywhere; } .details { border-top:1px solid var(--line); padding:13px; display:grid; gap:12px; } .detail-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:14px; } .detail-grid section { min-width:0; } dl { display:grid; grid-template-columns:minmax(120px,auto) 1fr; gap:5px 10px; margin:6px 0 0; } dt { color:var(--muted); } dd { margin:0; overflow-wrap:anywhere; } ul { margin:6px 0 0; padding-left:18px; } .empty { color:var(--muted); padding:12px 0; text-align:center; } .copy-actions { display:flex; gap:8px; flex-wrap:wrap; }
    .rows { display:grid; gap:5px; } .row { display:flex; gap:12px; justify-content:space-between; border-bottom:1px solid var(--line); padding:6px 0; } .row:last-child { border-bottom:0; } .row span:last-child { color:var(--muted); overflow-wrap:anywhere; text-align:right; } .timeline { border-left:2px solid var(--line); margin-left:7px; padding-left:16px; display:grid; gap:12px; } .timeline-item { position:relative; } .timeline-item::before { content:""; position:absolute; width:9px; height:9px; border-radius:50%; background:var(--accent); left:-22px; top:6px; }
    .apply-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:10px; } .metric-group { padding:10px 12px; border:1px solid var(--line); border-radius:10px; background:var(--bg); } .outcome-card { margin-top:10px; padding:13px; border:1px solid var(--line); border-radius:10px; background:var(--bg); } .recovery-card { border-left:5px solid var(--danger); background:var(--danger-bg); } .recovery-card.review-state { border-left-color:var(--high); background:var(--high-bg); } .technical-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,320px),1fr)); gap:12px; } .disclosure { padding:0; } .disclosure > summary { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:13px 16px; } .disclosure > summary::after { content:"View"; color:var(--muted); font-size:.8rem; font-weight:650; } .disclosure[open] > summary::after { content:"Hide"; } .disclosure-body { border-top:1px solid var(--line); padding:14px 16px; } .notice { margin:0; color:var(--muted); } .hero .notice { margin-top:6px; color:var(--hero-muted); font-size:.78rem; } .warning { margin:10px 0 0; padding:8px 10px; border:1px solid currentColor; border-radius:9px; color:var(--hero-warning); background:rgba(0,0,0,.16); font-size:.88rem; } .sr-only { position:absolute; width:1px; height:1px; padding:0; margin:-1px; overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap; border:0; }
    .report-pending .hero,.report-pending main > :not(#render-fallback) { display:none!important; }
    @media (prefers-color-scheme:dark) { :root:not([data-theme]) { color-scheme:dark; --bg:#111723; --surface:#182131; --text:#edf3ff; --muted:#aab8d0; --line:#344056; --accent:#9bb1ff; --on-accent:#101827; --hero-bg:#1e293b; --hero-text:#f8fafc; --hero-muted:#cbd5e1; --hero-warning:#fde68a; --safe:#62d7a7; --safe-bg:#173a31; --high:#f9bc63; --high-bg:#3c2e18; --review:#72d4ed; --review-bg:#173642; --protected:#e99be8; --danger:#ff9c93; --danger-bg:#442423; --shadow:none; } }
    @media (max-width:980px) { .summary-grid,.apply-grid { grid-template-columns:1fr; } .filters { justify-content:flex-start; } }
    @media (max-width:700px) { .page { padding:10px; } .hero,.card { padding:14px; } .hero-meta { justify-content:flex-start; } .kpis { grid-template-columns:repeat(2,minmax(0,1fr)); } .detail-grid { grid-template-columns:1fr; } .action-copy { grid-template-columns:1fr; } .finding-summary { grid-template-columns:auto minmax(0,1fr); } .finding-summary .finding-subtitle { grid-column:1 / -1; } .row { align-items:flex-start; flex-direction:column; } .row span:last-child { text-align:left; } .filters,.filter-control,.filter-actions { width:100%; } .filter-actions .button { flex:1; } }
    @media (prefers-reduced-motion:reduce) { *,*::before,*::after { scroll-behavior:auto!important; transition-duration:.01ms!important; } }
    @media print { body { background:#fff; } .page { max-width:none; padding:0; } .hero { color:#000; background:#fff; border:1px solid #bbb; box-shadow:none; } .card { box-shadow:none; break-inside:avoid; } .toolbar,.action-copy button,.filters,.finding-controls,.copy-actions { display:none!important; } .print-context { display:block; margin:0 0 10px; } details { break-inside:avoid; } details:not([open]) > .details,details:not([open]) > .disclosure-body { display:block; } }
    .render-fallback { border-color:var(--danger); } .render-fallback h2 { color:var(--danger); } .fallback-meta { display:flex; gap:8px 18px; flex-wrap:wrap; margin:8px 0; } .fallback-findings { max-height:52vh; overflow:auto; }
  </style>
  <noscript><style>main > :not(#render-fallback) { display:none!important; }</style></noscript>
</head>
<body>
  <a class="skip-link" href="#report-main">Skip to report content</a>
  <div class="page">
    <header class="hero" aria-labelledby="report-title">
      <div class="hero-heading"><div><p class="eyebrow">flutter_pruner offline report</p><h1 id="report-title">Scan report</h1></div><div id="hero-meta" class="hero-meta" aria-label="Run metadata"></div></div>
      <p id="status-warning" class="warning" role="status" hidden></p>
      <p class="notice">Privacy: this report can contain absolute local paths. Store and share it with care.</p>
    </header>
    <main id="report-main">
''' +
        fallback +
        r'''
      <section class="summary-grid"><section class="card" aria-labelledby="overview-title"><div class="section-head"><h2 id="overview-title">Decision overview</h2><div id="toolbar" class="toolbar"></div></div><div id="decision-banner" class="decision-banner" role="status"><h3 id="decision-title">Evaluating report</h3><p id="decision-copy" class="notice"></p><div id="decision-facts" class="decision-facts"></div></div><div id="kpis" class="kpis" aria-label="Finding tiers"></div></section><section class="card next-card" aria-labelledby="next-title"><div class="section-head"><h2 id="next-title">Recommended next action</h2></div><p id="next-action-copy" class="notice"></p><div id="next-command-panel" class="action-copy"><code id="next-command"></code><button id="copy-command" class="button" type="button">Copy command</button></div><p id="copy-status" class="feedback" role="status" aria-live="polite" aria-atomic="true"></p></section></section>
      <section id="recovery-section" class="card recovery-card" aria-labelledby="recovery-title" hidden><div class="section-head"><div><h2 id="recovery-title">Recovery attention</h2><p id="recovery-copy" class="notice"></p></div></div><div id="recovery-details"></div><div id="recovery-actions" class="copy-actions"></div></section>
      <section id="apply-section" class="card" aria-labelledby="apply-title" hidden><div class="section-head"><h2 id="apply-title">Apply summary</h2></div><div id="apply-summary" class="apply-grid"></div><div id="apply-outcomes"></div></section>
      <section class="card" aria-labelledby="findings-title"><div class="section-head findings-head"><div class="section-title-row"><h2 id="findings-title">Findings</h2><span id="finding-count" class="pill" role="status" aria-live="polite" aria-atomic="true"></span></div><div class="filters"><label class="filter-control search-control" for="search"><span>Search</span><input id="search" type="search" placeholder="Title, path, rule, or evidence"></label><div><span class="sr-only">Confidence tiers</span><div id="tier-filters" class="chips" aria-label="Filter by confidence"></div></div><label class="filter-control" for="adapter-filter"><span>Adapter</span><select id="adapter-filter"><option value="all">All adapters</option></select></label><label class="filter-control" for="blocker-filter"><span>Blockers</span><select id="blocker-filter"><option value="all">Any blocker state</option><option value="with">Has blockers</option><option value="without">No blockers</option></select></label><label id="outcome-filter-control" class="filter-control" for="outcome-filter" hidden><span>Apply outcome</span><select id="outcome-filter"><option value="all">All outcomes</option></select></label><label class="filter-control" for="sort"><span>Sort</span><select id="sort"><option value="tier">Confidence tier</option><option value="title">Title</option><option value="path">Path</option></select></label><div class="filter-actions"><button id="reset-filters" class="button secondary" type="button">Reset filters</button></div></div></div><p id="print-context" class="print-context"></p><div id="findings" class="finding-list"></div><div id="finding-controls" class="finding-controls"><button id="load-more" class="button secondary" type="button" hidden>Show more findings</button></div></section>
      <section class="technical-grid"><details class="card disclosure"><summary><h2 id="verification-title">Verification</h2></summary><div id="verification" class="disclosure-body"></div></details><details class="card disclosure"><summary><h2 id="coverage-title">Coverage and diagnostics</h2></summary><div class="disclosure-body"><div id="coverage"></div><div id="diagnostics"></div></div></details><details class="card disclosure"><summary><h2 id="adapters-title">Analysis details</h2></summary><div class="disclosure-body"><div id="adapters"></div><div id="measurements"></div><div id="exclusions"></div></div></details></section>
    </main>
  </div>
  <script id="report-data" type="application/json">''' +
        _escapeForScript(json) +
        r'''</script>
  <script>
    (() => {
      'use strict';
      const $ = id => document.getElementById(id);
      const report = JSON.parse($('report-data').textContent);
      if (!report || report.version !== 3 || !report.run) throw new Error('Unsupported or incomplete report schema.');
      const tiers = ['SAFE', 'HIGH', 'REVIEW', 'PROTECTED'];
      const activeTiers = new Set(tiers);
      const tierOrder = Object.fromEntries(tiers.map((tier, index) => [tier, index]));
      const openFindingIds = new Set();
      const pageSize = 100;
      let visibleLimit = pageSize;
      const make = (tag, className, value) => { const node = document.createElement(tag); if (className) node.className = className; if (value !== undefined && value !== null) node.textContent = String(value); return node; };
      const append = (parent, tag, className, value) => { const node = make(tag, className, value); parent.append(node); return node; };
      const number = value => new Intl.NumberFormat().format(Number(value || 0));
      const duration = micros => `${(Number(micros || 0) / 1000000).toFixed(2)} s`;
      const value = input => input === undefined || input === null || input === '' ? 'Not recorded' : Array.isArray(input) ? input.join(', ') : typeof input === 'object' ? JSON.stringify(input) : String(input);
      const labels = Object.freeze({
        predicate: { ruleAllowsAutoFix:'Rule supports automatic fixes', unreachableAcrossAllTargets:'Unreachable in every configured target', notRetained:'Not retained by any execution context', noDynamicBlockers:'No dynamic-use blockers', notProtected:'Not protected by policy', noPublicApiRisk:'No public API risk', hasDeterministicInverse:'Change is fully reversible', analysisCoverageComplete:'Analysis coverage is complete', actionSupported:'Apply action is supported' },
        classification: { 'incomplete-target-matrix':'Target coverage is incomplete', 'incomplete-root-coverage':'Entry-point coverage is incomplete', 'incomplete-graph-integrity':'Analysis graph is incomplete', 'dynamic-reference':'A dynamic reference may still use this', 'generated-code-uncertainty':'Generated code could not be fully resolved', 'duplicate-canonical-choice':'Choose which duplicate to keep', 'unsupported-action':'No supported apply action', 'non-deterministic-inverse':'Change cannot be reversed exactly', 'public-api-surface':'May be part of a public API', 'retained-only':'Retained without exact reachability', 'broad-removal-scope':'Removal has broad dependency scope' },
        nodeKind: { dartLibrary:'Dart library', assetVariant:'Asset variant', generatedArtifact:'Generated file', localizationKey:'Localization key', diRegistration:'Dependency registration', nativeResource:'Native resource', duplicateGroup:'Duplicate files' },
        measurement: { 'source-bytes':'Source size', 'dart-finding-source-bytes':'Dart source size', 'asset-family-source-bytes':'Asset family size', 'duplicate-potential-reclaimable-bytes':'Potential duplicate savings' },
        detail: { baseSizeBytes:'Base asset size', variantCount:'Variants', variantSizeBytes:'Variant size', hasTransformers:'Asset transformers', fileCount:'Files', sizePerFile:'Size per file', groupSourceBytes:'Duplicate group size', potentialReclaimableBytes:'Potential savings', paths:'Files' },
        rootMode: { applicationEntrypoints:'Application entry points', applicationApi:'Application API', packagePublicApi:'Package public API', packageInternal:'Package-internal roots', inferred:'Inferred roots' },
        analysisPass: { initial:'Initial scan', rescan:'Rescan', finalScan:'Final scan' },
        adapterStatus: { executed:'Completed', notApplicable:'Not applicable', failed:'Failed' },
        measurementStatus: { measured:'Measured', unknown:'Not measured', notApplicable:'Not applicable' },
        verificationPurpose: { baseline:'Baseline verification', candidate:'Candidate verification', rollback:'Rollback verification' },
        outcomeStatus: { committed:'Committed', rejectedRecovered:'Rejected and recovered', blocked:'Blocked', skippedDependency:'Skipped because of a dependency', remaining:'Remaining', recoveryRequired:'Recovery required' },
        evidenceKind: { semanticReference:'Semantic reference', constString:'Constant string', finiteStringSet:'Finite string set', symbolicPattern:'Symbolic pattern', generatedAccessor:'Generated accessor', configuration:'Configuration', userKeepRule:'User keep rule', annotation:'Annotation', runtimeObservation:'Runtime observation', externalTool:'External tool' },
        runStatus: { completed:'Completed', noChanges:'No changes', dryRun:'Dry run', safeStopped:'Stopped safely', infrastructureFailure:'Infrastructure failure', recoveryRequired:'Recovery required', internalError:'Internal error', interrupted:'Interrupted' },
        action: { removeDeclaration:'Remove declaration', deleteFile:'Delete file', deleteAssetFamily:'Delete asset family', deleteDuplicate:'Delete duplicate', none:'No automatic action' },
        unit: { bytes:'bytes' },
      });
      const acronyms = Object.freeze({ api:'API', di:'DI', id:'ID', ids:'IDs', json:'JSON', ui:'UI', url:'URL' });
      const humanizeIdentifier = raw => String(raw === undefined || raw === null ? '' : raw).replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/[-_]+/g, ' ').trim().split(/\s+/).filter(Boolean).map((word, index) => acronyms[word.toLowerCase()] || (index === 0 ? word.charAt(0).toUpperCase() + word.slice(1) : word.toLowerCase())).join(' ');
      const labelFor = (group, raw) => labels[group] && Object.prototype.hasOwnProperty.call(labels[group], raw) ? labels[group][raw] : humanizeIdentifier(raw);
      const adapterCatalog = new Map((((report.presentation || {}).adapters) || []).map(definition => [definition.id, definition]));
      const adapterFor = adapterId => adapterCatalog.get(String(adapterId || ''));
      const findingPresentationFor = finding => { const adapter = adapterFor(finding && finding.reportingAdapterId); const definitions = adapter && adapter.findings || []; const nodeKind = finding && finding.node && finding.node.kind; return definitions.find(definition => definition.nodeKind === nodeKind && (!finding.ruleId || definition.ruleId === finding.ruleId)) || definitions.find(definition => definition.nodeKind === nodeKind); };
      const adapterName = adapterId => { const definition = adapterFor(adapterId); return definition && definition.displayName || labelFor('producer', adapterId); };
      const nodeKindLabel = finding => { const definition = findingPresentationFor(finding); return definition && definition.nodeLabel || labelFor('nodeKind', finding && finding.node && finding.node.kind); };
      const measurementLabel = (adapterId, kind) => { const adapter = adapterFor(adapterId); const definition = (adapter && adapter.measurements || []).find(measurement => measurement.kind === kind); return definition && definition.label || labelFor('measurement', kind); };
      const detailDefinition = (finding, key) => { const definition = findingPresentationFor(finding); return (definition && definition.details || []).find(detail => detail.key === key); };
      const knownClassificationLabel = raw => Object.prototype.hasOwnProperty.call(labels.classification, raw) ? labels.classification[raw] : value(raw);
      const formatBytes = raw => { if (raw === undefined || raw === null || raw === '') return 'Not recorded'; const bytes = Number(raw); if (!Number.isFinite(bytes)) return value(raw); if (Math.abs(bytes) < 1024) return `${number(bytes)} B`; if (Math.abs(bytes) < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`; if (Math.abs(bytes) < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MiB`; return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GiB`; };
      const formatMeasurement = measurement => measurement && measurement.status === 'measured' ? (measurement.unit === 'bytes' ? formatBytes(measurement.value) : `${value(measurement.value)} ${labelFor('unit', measurement.unit)}`) : measurement && measurement.status ? labelFor('measurementStatus', measurement.status) : 'Not recorded';
      const detailValue = (key, content, definition) => (definition && definition.valueType === 'bytes' || /Bytes$/.test(key)) && !Array.isArray(content) ? formatBytes(content) : value(content);
      const readableCode = raw => typeof raw === 'string' && /^[A-Za-z0-9_-]+$/.test(raw) ? humanizeIdentifier(raw) : value(raw);
      const empty = (parent, message) => append(parent, 'p', 'empty', message);
      const addRows = (parent, entries) => { const rows = append(parent, 'div', 'rows'); entries.forEach(([label, content]) => { const row = append(rows, 'div', 'row'); append(row, 'strong', '', label); append(row, 'span', '', value(content)); }); };
      const addMetricGroup = (parent, title, entries) => { const group = append(parent, 'section', 'metric-group'); append(group, 'h3', '', title); addRows(group, entries); };
      const compactRows = entries => entries.filter(([, content]) => content !== undefined && content !== null && content !== '' && (!Array.isArray(content) || content.length));
      const badges = (parent, labels) => labels.forEach(label => append(parent, 'span', 'pill', label));
      const normalizeTier = tier => String(tier || 'REVIEW').toUpperCase();
      const tierClass = tier => { const normalized = normalizeTier(tier); return tiers.includes(normalized) ? normalized.toLowerCase() : 'review'; };
      const shellQuote = path => { const quote = String.fromCharCode(39); return quote + String(path || '.').split(quote).join(quote + '"' + quote + '"' + quote) + quote; };
      const stableAnchor = raw => { let hash = 2166136261; for (const character of String(raw || 'finding')) { hash ^= character.codePointAt(0); hash = Math.imul(hash, 16777619); } return `finding-${(hash >>> 0).toString(36)}`; };
      const announceCopy = (message, failed = false) => { const status = $('copy-status'); status.textContent = message; status.classList.toggle('danger', failed); };
      const copyText = async (content, button, successMessage) => { const original = button.textContent; try { let copied = false; try { await navigator.clipboard.writeText(content); copied = true; } catch (_) { const input = document.createElement('textarea'); input.value = content; input.setAttribute('readonly', ''); document.body.append(input); input.select(); copied = document.execCommand('copy'); input.remove(); } if (!copied) throw new Error('Copy was rejected'); button.textContent = successMessage; announceCopy(`${successMessage}.`); window.setTimeout(() => { button.textContent = original; }, 1600); } catch (_) { announceCopy('Copy failed. Select the text and copy it manually.', true); } };
      const statusWarnings = [];
      const showStatusWarnings = () => { const node = $('status-warning'); node.hidden = !statusWarnings.length; node.textContent = statusWarnings.join(' '); };

      $('report-title').textContent = `${report.run.command === 'apply' ? 'Apply' : 'Scan'} report · ${report.run.packageName || report.run.id}`;
      badges($('hero-meta'), [labelFor('runStatus', report.run.status), `exit ${report.run.exitCode}`, `finished ${new Date(report.run.finishedAtUtc).toLocaleString()}`, duration(report.run.elapsedMicros)]);
      const statistics = report.statistics || {}; const findingStats = statistics.findings || {}; const byTier = findingStats.byTier || {}; const blockerStats = statistics.blockers || {};
      tiers.forEach(tier => { const card = append($('kpis'), 'div', `kpi ${tierClass(tier)}`); append(card, 'strong', '', number(byTier[tier])); append(card, 'span', '', tier); });
      const coverage = report.analysisCoverage || {}; const analysisMode = coverage.analysisMode || 'application'; const coverageReady = coverage.targetMatrix && coverage.targetMatrix.complete && coverage.roots && coverage.roots.internalBoundaryComplete; const passes = report.execution && report.execution.analysisPasses || []; const finalPass = passes.length ? passes[passes.length - 1] : null; const graph = finalPass && finalPass.graph || {}; const danglingEdges = Number(graph.danglingEdges || 0); const danglingRoots = Number(graph.danglingRoots || 0); const graphIntegrityFacts = []; if (danglingEdges > 0) graphIntegrityFacts.push(`${number(danglingEdges)} dangling edge(s)`); if (danglingRoots > 0) graphIntegrityFacts.push(`${number(danglingRoots)} dangling root(s)`); const failedAdapters = finalPass ? (finalPass.adapters || []).filter(adapter => adapter.status === 'failed') : []; const analysisHealthy = finalPass !== null && danglingEdges === 0 && danglingRoots === 0 && !failedAdapters.length; const ready = coverageReady && analysisHealthy; const packageOpenWorld = analysisMode === 'package'; const packageInternal = analysisMode === 'package-internal';
      if (packageOpenWorld) statusWarnings.push('Reusable-package consumers are open-world. Package mode is review-only and cannot be applied.');
      else if (packageInternal) statusWarnings.push('PACKAGE-INTERNAL BOUNDARY: external consumers were not scanned. Externally addressable findings require explicit confirmation before mutation.');
      else if (!coverageReady) statusWarnings.push('Coverage is incomplete. SAFE and HIGH findings must not be applied until target and root coverage issues are resolved.');
      if (finalPass === null) statusWarnings.push('No final analysis pass was recorded. Re-run the scan before considering apply guidance.');
      else { if (danglingEdges > 0) statusWarnings.push(`Final analysis graph has ${number(danglingEdges)} dangling edge(s). Apply guidance is disabled.`); if (danglingRoots > 0) statusWarnings.push(`Final analysis graph has ${number(danglingRoots)} dangling root(s). Apply guidance is disabled.`); if (failedAdapters.length) statusWarnings.push(`Final analysis has failed adapter(s): ${failedAdapters.map(adapter => adapter.name || adapter.id).join(', ')}. Apply guidance is disabled.`); }
      const run = report.run || {}; const apply = report.apply; const transactions = apply && apply.transactions || {}; const terminalTransactions = Number(transactions.committed || 0) + Number(transactions.rolledBackVerified || 0) + Number(transactions.recoveryRequired || 0) + Number(transactions.nonTerminal || 0); const transactionPartitionInvalid = Boolean(apply) && Number(transactions.begun || 0) !== terminalTransactions; const recoveryRequired = run.command === 'apply' && run.status === 'recoveryRequired'; const partialApplied = run.command === 'apply' && run.partialApplied === true; const recoveryAttention = partialApplied; const recoverySignal = recoveryRequired || recoveryAttention || Number(transactions.recoveryRequired || 0) > 0 || Number(transactions.nonTerminal || 0) > 0 || transactionPartitionInvalid; const runFailed = ['infrastructureFailure', 'internalError', 'interrupted'].includes(run.status);
      if (recoverySignal) statusWarnings.push('Recovery required: do not assume rollback completed successfully.');
      if (recoveryAttention) statusWarnings.push('The legacy partialApplied flag marks an uncertain working-copy state. Inspect recovery evidence; do not infer that committed changes remain.');
      if (transactionPartitionInvalid) statusWarnings.push('Transaction counters do not form a terminal partition. Treat this apply report as incomplete and inspect recovery records.');
      if (Number(transactions.recoveryRequired || 0) > 0) statusWarnings.push('One or more transactions require recovery. Do not assume rollback completed successfully.');
      if (Number(transactions.nonTerminal || 0) > 0) statusWarnings.push('One or more transactions are non-terminal. Recovery is required before this result can be treated as complete.');

      let decisionTitle = 'Review report'; let decisionCopy = 'Inspect the report evidence before taking another action.'; let decisionTone = 'review';
      if (recoverySignal) { decisionTitle = recoveryAttention && !recoveryRequired ? 'Working-copy state needs recovery attention' : 'Recovery required'; decisionCopy = recoveryAttention && !recoveryRequired ? 'The compatibility partialApplied flag is uncertain evidence. Inspect the manifest before another apply; it does not prove that prior changes remain.' : 'Transaction state is incomplete or rollback is not verified. Do not run another apply command.'; decisionTone = 'danger'; }
      else if (runFailed) { decisionTitle = 'Run did not complete'; decisionCopy = 'Resolve the recorded failure and generate a fresh report before planning changes.'; decisionTone = 'danger'; }
      else if (run.status === 'safeStopped') { decisionTitle = 'Stopped safely — no mutation retained'; decisionCopy = 'Whole-run rollback was verified (or no mutation began). Re-scan before planning another apply.'; decisionTone = 'high'; }
      else if (packageOpenWorld || !coverageReady || !analysisHealthy) { decisionTitle = 'Audit only — not actionable'; decisionCopy = 'Coverage or analysis health is incomplete, so automatic apply guidance is disabled.'; decisionTone = 'review'; }
      else if (run.command === 'apply') { decisionTitle = run.status === 'dryRun' ? 'Dry run complete' : 'Apply complete — verify current state'; decisionCopy = run.status === 'dryRun' ? 'No project mutation was requested. Review the proposed scope before any real apply.' : 'Retain this audit record and re-scan the current project state.'; decisionTone = 'safe'; }
      else if (Number(byTier.SAFE || 0) > 0 || Number(byTier.HIGH || 0) > 0) { decisionTitle = 'Ready for dry-run preview'; decisionCopy = 'Coverage and analysis gates passed. Preview eligible findings before any mutation.'; decisionTone = 'safe'; }
      else { decisionTitle = 'No auto-applicable findings'; decisionCopy = 'Review manual and protected findings, then re-scan when evidence changes.'; decisionTone = 'review'; }
      const decisionBanner = $('decision-banner'); decisionBanner.className = `decision-banner ${decisionTone}`; $('decision-title').textContent = decisionTitle; $('decision-copy').textContent = decisionCopy;
      const graphFact = finalPass === null ? 'Not recorded' : failedAdapters.length ? `${number(failedAdapters.length)} adapter failure(s)` : graphIntegrityFacts.length ? graphIntegrityFacts.join(' · ') : 'Healthy';
      const decisionFacts = $('decision-facts'); [['Coverage', coverageReady ? 'Complete' : 'Incomplete'], ['Graph', graphFact], ['Active blockers', number(blockerStats.activeUnique)], ['Affected findings', number(blockerStats.affectedFindings)], ...(run.command === 'apply' ? [['Working-copy evidence', recoveryAttention ? 'Recovery attention' : run.status === 'safeStopped' ? 'No mutation retained' : 'No recovery attention']] : [])].forEach(([label, content]) => append(decisionFacts, 'span', 'decision-fact', `${label}: ${content}`));

      const recoverySection = $('recovery-section');
      if (run.command === 'apply' && (recoverySignal || run.status === 'safeStopped')) { recoverySection.hidden = false; recoverySection.classList.toggle('review-state', !recoverySignal); $('recovery-title').textContent = recoverySignal ? recoveryAttention && !recoveryRequired ? 'Working-copy state needs recovery attention' : 'Recovery required' : 'Rollback verified — apply stopped safely'; $('recovery-copy').textContent = recoverySignal ? recoveryAttention && !recoveryRequired ? 'The compatibility partialApplied flag is uncertain evidence. Inspect quarantine and transaction evidence before another command; no automatic rollback is offered here.' : 'Inspect quarantine and transaction evidence before another command. No automatic rollback is offered from this report.' : 'No mutation from this run was retained after verified rollback (or no mutation began). Re-scan before planning another apply.'; addRows($('recovery-details'), compactRows([['Working-copy evidence', recoveryAttention ? 'Legacy partialApplied: recovery attention' : run.status === 'safeStopped' ? 'No mutation retained' : 'No recovery attention'], ['Quarantine path', report.quarantine && report.quarantine.path], ['Transactions begun', transactions.begun], ['Committed', transactions.committed], ['Rollback verified', transactions.rolledBackVerified], ['Recovery required', transactions.recoveryRequired], ['Non-terminal', transactions.nonTerminal]])); const quarantinePath = report.quarantine && report.quarantine.path; if (quarantinePath) { const copyQuarantine = make('button', 'button secondary', 'Copy quarantine path'); copyQuarantine.type = 'button'; copyQuarantine.addEventListener('click', () => copyText(quarantinePath, copyQuarantine, 'Path copied')); $('recovery-actions').append(copyQuarantine); } }

      const project = shellQuote(run.projectRoot); const adapterArguments = ((report.execution && report.execution.requestedAdapters) || []).map(adapter => ` --adapter ${shellQuote(adapter)}`).join(''); let nextCommand = null;
      if (recoverySignal) { $('next-action-copy').textContent = 'Recovery is required. Inspect transaction state and quarantine records before running another command.'; }
      else if (runFailed) { $('next-action-copy').textContent = 'This run did not complete. Resolve its diagnostics and generate a fresh report before considering another command.'; }
      else if (packageOpenWorld) { $('next-action-copy').textContent = 'This package is audit-only in the current version. Validate REVIEW findings against external consumers; no automatic apply command is offered.'; }
      else if (!coverageReady) { $('next-action-copy').textContent = 'Complete coverage first. This report does not offer an apply command while target or root coverage is incomplete.'; nextCommand = `flutter_pruner init --project ${project}`; }
      else if (!analysisHealthy) { $('next-action-copy').textContent = 'Final analysis is unhealthy. Re-run the scan and resolve graph or adapter failures before considering apply.'; nextCommand = `flutter_pruner scan --project ${project}${adapterArguments}`; }
      else if (run.command === 'apply') { if (run.status === 'dryRun') { $('next-action-copy').textContent = 'Dry run completed. To preserve the reviewed configuration, quarantine path, and scope, rerun the exact reviewed invocation from shell history.'; } else if (run.status === 'safeStopped') { $('next-action-copy').textContent = 'Apply stopped safely. Re-scan to establish the current project state before planning another run.'; nextCommand = `flutter_pruner scan --project ${project}${adapterArguments}`; } else if (run.status === 'completed') { $('next-action-copy').textContent = 'Apply completed. Re-scan to confirm the current project state and retain this report with the transaction records.'; nextCommand = `flutter_pruner scan --project ${project}${adapterArguments}`; } else { $('next-action-copy').textContent = 'Review this apply result and its diagnostics before taking further action.'; } }
      else if (!(report.findings || []).length) { $('next-action-copy').textContent = 'No findings were reported. Re-scan after relevant project or coverage changes.'; nextCommand = `flutter_pruner scan --project ${project}${adapterArguments}`; }
      else if (Number(byTier.SAFE || 0) > 0) { $('next-action-copy').textContent = 'Preview eligible findings in a dry-run report. This command does not modify the project.'; nextCommand = `flutter_pruner apply --project ${project} --dry-run${adapterArguments}`; }
      else if (Number(byTier.HIGH || 0) > 0) { $('next-action-copy').textContent = 'Preview eligible HIGH findings in dry-run mode. A later mutation requires confirmation or --yes.'; nextCommand = `flutter_pruner apply --project ${project} --dry-run${adapterArguments}`; }
      else { $('next-action-copy').textContent = 'No auto-applicable findings are available. Inspect REVIEW and PROTECTED findings, then re-scan when evidence changes.'; }
      $('next-command-panel').hidden = nextCommand === null; if (nextCommand !== null) $('next-command').textContent = nextCommand;
      $('copy-command').addEventListener('click', () => { if (nextCommand !== null) copyText(nextCommand, $('copy-command'), 'Command copied'); });
      const print = make('button', 'button secondary', 'Print report'); print.type = 'button'; print.addEventListener('click', () => window.print()); $('toolbar').append(print);
      const download = make('button', 'button secondary', 'Download JSON'); download.type = 'button'; download.addEventListener('click', () => { const blob = new Blob([JSON.stringify(report, null, 2)], {type:'application/json'}); const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = `${report.run.id || 'flutter-pruner'}-report.json`; document.body.append(link); link.click(); link.remove(); URL.revokeObjectURL(link.href); }); $('toolbar').append(download);
      const theme = make('button', 'button secondary'); theme.id = 'theme-toggle'; theme.type = 'button'; const preferredTheme = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'; let storedTheme = null; try { storedTheme = localStorage.getItem('flutter-pruner-theme'); } catch (_) {} const setTheme = themeName => { document.documentElement.dataset.theme = themeName; theme.textContent = themeName === 'dark' ? 'Switch to light theme' : 'Switch to dark theme'; theme.setAttribute('aria-pressed', String(themeName === 'dark')); try { localStorage.setItem('flutter-pruner-theme', themeName); } catch (_) {} }; setTheme(storedTheme === 'dark' || storedTheme === 'light' ? storedTheme : preferredTheme); theme.addEventListener('click', () => { setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark'); }); $('toolbar').append(theme);

      const tierButtons = new Map();
      tiers.forEach(tier => { const button = make('button', `chip ${tierClass(tier)}`, `${tier} ${number(byTier[tier])}`); button.type = 'button'; button.setAttribute('aria-pressed', 'true'); button.addEventListener('click', () => { activeTiers.has(tier) ? activeTiers.delete(tier) : activeTiers.add(tier); button.setAttribute('aria-pressed', String(activeTiers.has(tier))); renderFindings(true); }); tierButtons.set(tier, button); $('tier-filters').append(button); });
      const appendOption = (select, optionValue, label) => { const option = make('option', '', label); option.value = optionValue; select.append(option); };
      const adapterIds = [...new Set((report.findings || []).map(finding => finding.reportingAdapterId).filter(Boolean))].sort((left, right) => adapterName(left).localeCompare(adapterName(right)));
      adapterIds.forEach(adapterId => appendOption($('adapter-filter'), adapterId, adapterName(adapterId)));
      const outcomeByFindingId = new Map();
      for (const outcome of apply && apply.findingOutcomes || []) { if (outcome.findingId) outcomeByFindingId.set(outcome.findingId, outcome); const nodeId = outcome.finding && outcome.finding.node && outcome.finding.node.id; if (nodeId) outcomeByFindingId.set(nodeId, outcome); }
      const outcomeStatuses = [...new Set([...outcomeByFindingId.values()].map(outcome => outcome.status).filter(Boolean))].sort();
      if (outcomeStatuses.length) { $('outcome-filter-control').hidden = false; outcomeStatuses.forEach(status => appendOption($('outcome-filter'), status, labelFor('outcomeStatus', status))); appendOption($('outcome-filter'), 'none', 'No recorded outcome'); }
      const findBlocker = id => report.blockers && report.blockers[id] ? report.blockers[id] : { producer:'analysis', reason:'Unknown blocker reference' };
      const addList = (parent, title, items, map, showEmpty = true) => { if (!items || !items.length) { if (showEmpty) { const section = append(parent, 'section'); append(section, 'h3', '', title); empty(section, 'None recorded.'); } return; } const section = append(parent, 'section'); append(section, 'h3', '', title); const list = append(section, 'ul'); items.forEach(item => append(list, 'li', '', map ? map(item) : value(item))); };
      const blockerText = blocker => `${adapterName(blocker.producer || 'analysis')}: ${readableCode(blocker.reason)}${blocker.location ? ` (${blocker.location})` : ''}`;
      const evidenceText = evidence => `${labelFor('evidenceKind', evidence.kind || 'evidence')}: ${evidence.description || 'No description'}${evidence.location ? ` (${evidence.location})` : ''}`;
      const measurementText = (measurement, adapterId) => `${measurementLabel(adapterId || measurement.adapterId, measurement.kind || 'measurement')}: ${formatMeasurement(measurement)}`;
      const detailRows = (details, finding) => Object.entries(details || {}).map(([key, content]) => { const definition = detailDefinition(finding, key); return [definition && definition.label || labelFor('detail', key), detailValue(key, content, definition)]; });
      const targetText = target => { const parts = [target.name || 'Unnamed target']; if (target.platform) parts.push(`Platform: ${target.platform}`); if (target.entrypoint) parts.push(`Entry point: ${target.entrypoint}`); if (target.flavor) parts.push(`Flavor: ${target.flavor}`); const defines = Object.entries(target.dartDefines || {}).map(([key, content]) => `${key}=${content}`); if (defines.length) parts.push(`Dart defines: ${defines.join(', ')}`); return parts.join(' · '); };
      const renderFinding = finding => {
        const details = make('details');
        const findingId = finding.node && finding.node.id || finding.ruleId || finding.title;
        details.dataset.findingId = findingId;
        details.id = stableAnchor(findingId);
        details.open = openFindingIds.has(findingId);
        details.addEventListener('toggle', () => { details.open ? openFindingIds.add(findingId) : openFindingIds.delete(findingId); });
        const summary = append(details, 'summary');
        const head = append(summary, 'div', 'finding-summary');
        append(head, 'span', `pill ${tierClass(finding.confidence)}`, normalizeTier(finding.confidence));
        const title = append(head, 'div');
        append(title, 'div', 'finding-title', finding.title);
        append(title, 'div', 'finding-subtitle', `${finding.node && finding.node.projectRelativeOrigin || finding.node && finding.node.origin || 'Path unavailable'} · ${finding.ruleId}`);
        append(head, 'span', 'finding-subtitle', nodeKindLabel(finding));
        const body = append(details, 'div', 'details');
        const presentation = findingPresentationFor(finding); if (presentation && presentation.description) append(body, 'p', 'empty', presentation.description);
        const grid = append(body, 'div', 'detail-grid');
        const decision = append(grid, 'section');
        append(decision, 'h3', '', 'Decision evidence');
        addRows(decision, compactRows([['Rule ID', finding.ruleId], ['Adapter', adapterName(finding.reportingAdapterId)], ['Why not safe', finding.whyNotSafe], ['Proposed action', labelFor('action', finding.proposedAction)], ['Unreachable in', finding.unreachableIn], ['Reachable in', finding.reachableIn], ['Retained in', finding.retainedIn], ['Auxiliary retained in', finding.auxiliaryRetainedIn]]));
        const predicates = append(grid, 'section');
        append(predicates, 'h3', '', 'Safety checks');
        addRows(predicates, Object.entries(finding.predicates || {}).map(([key, state]) => [labelFor('predicate', key), state ? 'Passed' : 'Not satisfied']));
        addList(body, 'Classification reasons', finding.classificationReasons, reason => labelFor('classification', reason), false);
        addList(body, 'Protection reasons', finding.protectionReasons, reason => labelFor('classification', reason), false);
        addList(body, 'Blockers', finding.blockerIds, id => blockerText(findBlocker(id)), false);
        addList(body, 'Evidence', finding.evidence, evidenceText, false);
        addList(body, 'Measurements', finding.measurements, measurement => measurementText(measurement, finding.reportingAdapterId), false);
        const findingDomainRows = detailRows(finding.details, finding); if (findingDomainRows.length) { const detailsSection = append(body, 'section'); append(detailsSection, 'h3', '', 'Domain details'); addRows(detailsSection, findingDomainRows); }
        const path = finding.node && (finding.node.projectRelativeOrigin || finding.node.origin);
        const copyActions = append(body, 'div', 'copy-actions');
        if (path) { const copyPath = make('button', 'button secondary', 'Copy path'); copyPath.type = 'button'; copyPath.addEventListener('click', () => copyText(path, copyPath, 'Path copied')); copyActions.append(copyPath); }
        const copyLink = make('button', 'button secondary', 'Copy finding link'); copyLink.type = 'button'; copyLink.addEventListener('click', () => { const url = new URL(window.location.href); url.hash = details.id; copyText(url.toString(), copyLink, 'Link copied'); }); copyActions.append(copyLink);
        return details;
      };
      const renderFindings = (resetLimit = false) => { const host = $('findings'); host.querySelectorAll('details[data-finding-id][open]').forEach(details => openFindingIds.add(details.dataset.findingId)); host.replaceChildren(); if (resetLimit) visibleLimit = pageSize; const query = $('search').value.trim().toLowerCase(); const sort = $('sort').value; const adapterFilter = $('adapter-filter').value; const blockerFilter = $('blocker-filter').value; const outcomeFilter = $('outcome-filter').value; const findings = (report.findings || []).filter(finding => { const blockerIds = finding.blockerIds || []; const findingId = finding.node && finding.node.id; const outcome = outcomeByFindingId.get(findingId); const haystack = [finding.title, finding.ruleId, finding.confidence, adapterName(finding.reportingAdapterId), finding.node && finding.node.projectRelativeOrigin, finding.node && finding.node.origin, ...(finding.retainedIn || []), ...(finding.auxiliaryRetainedIn || []), ...(finding.classificationReasons || []), ...blockerIds.map(id => findBlocker(id).reason), ...(finding.evidence || []).map(evidence => evidence.description)].join(' ').toLowerCase(); const adapterMatches = adapterFilter === 'all' || finding.reportingAdapterId === adapterFilter; const blockerMatches = blockerFilter === 'all' || blockerFilter === 'with' && blockerIds.length > 0 || blockerFilter === 'without' && blockerIds.length === 0; const outcomeMatches = outcomeFilter === 'all' || outcomeFilter === 'none' && !outcome || outcome && outcome.status === outcomeFilter; return activeTiers.has(normalizeTier(finding.confidence)) && adapterMatches && blockerMatches && outcomeMatches && (!query || haystack.includes(query)); }).sort((left, right) => { if (sort === 'title') return String(left.title).localeCompare(String(right.title)); if (sort === 'path') return String(left.node && left.node.projectRelativeOrigin || '').localeCompare(String(right.node && right.node.projectRelativeOrigin || '')); const tierDifference = (tierOrder[normalizeTier(left.confidence)] ?? 99) - (tierOrder[normalizeTier(right.confidence)] ?? 99); return tierDifference || String(left.title).localeCompare(String(right.title)); }); const requestedAnchor = window.location.hash.slice(1); const requestedIndex = requestedAnchor ? findings.findIndex(finding => stableAnchor(finding.node && finding.node.id || finding.ruleId || finding.title) === requestedAnchor) : -1; if (requestedIndex >= visibleLimit) visibleLimit = requestedIndex + 1; const visibleFindings = findings.slice(0, visibleLimit); $('finding-count').textContent = `${number(visibleFindings.length)} rendered · ${number(findings.length)} match · ${number((report.findings || []).length)} total`; const filtersActive = query || activeTiers.size !== tiers.length || adapterFilter !== 'all' || blockerFilter !== 'all' || outcomeFilter !== 'all'; if (!findings.length) empty(host, filtersActive ? 'No findings match these filters. Reset filters to restore the full report.' : 'No findings were reported.'); else visibleFindings.forEach(finding => host.append(renderFinding(finding))); const loadMore = $('load-more'); loadMore.hidden = visibleFindings.length >= findings.length; loadMore.textContent = `Show ${number(Math.min(pageSize, findings.length - visibleFindings.length))} more findings`; const filterSummary = [`${findings.length} of ${(report.findings || []).length} findings`, `tiers ${[...activeTiers].join(', ') || 'none'}`]; if (adapterFilter !== 'all') filterSummary.push(`adapter ${adapterName(adapterFilter)}`); if (blockerFilter !== 'all') filterSummary.push(blockerFilter === 'with' ? 'with blockers' : 'without blockers'); if (outcomeFilter !== 'all') filterSummary.push(outcomeFilter === 'none' ? 'without outcome' : `outcome ${labelFor('outcomeStatus', outcomeFilter)}`); if (query) filterSummary.push(`search "${query}"`); $('print-context').textContent = `Printed finding snapshot: ${filterSummary.join(' · ')}.`; const hashTarget = requestedAnchor && document.getElementById(requestedAnchor); if (hashTarget && hashTarget.tagName === 'DETAILS') { hashTarget.open = true; openFindingIds.add(hashTarget.dataset.findingId); hashTarget.scrollIntoView({ block: 'start' }); } };
      let searchTimer = null;
      $('search').addEventListener('input', () => { window.clearTimeout(searchTimer); searchTimer = window.setTimeout(() => renderFindings(true), 120); });
      for (const id of ['sort', 'adapter-filter', 'blocker-filter', 'outcome-filter']) $(id).addEventListener('change', () => renderFindings(true));
      $('reset-filters').addEventListener('click', () => { $('search').value = ''; $('sort').value = 'tier'; $('adapter-filter').value = 'all'; $('blocker-filter').value = 'all'; $('outcome-filter').value = 'all'; activeTiers.clear(); tiers.forEach(tier => { activeTiers.add(tier); tierButtons.get(tier).setAttribute('aria-pressed', 'true'); }); renderFindings(true); $('search').focus(); });
      $('load-more').addEventListener('click', () => { visibleLimit += pageSize; renderFindings(); });
      window.addEventListener('hashchange', () => renderFindings());
      let prePrintLimit = pageSize; window.addEventListener('beforeprint', () => { prePrintLimit = visibleLimit; visibleLimit = Number.MAX_SAFE_INTEGER; renderFindings(); }); window.addEventListener('afterprint', () => { visibleLimit = prePrintLimit; renderFindings(); });
      renderFindings(true);

      if (!apply) { $('apply-section').hidden = true; }
      else {
        $('apply-section').hidden = false;
        const summary = $('apply-summary');
        addMetricGroup(summary, 'Finding outcomes', [['Rounds', apply.rounds], ['Committed', apply.findings && apply.findings.committed], ['Rejected and recovered', apply.findings && apply.findings.rejectedRecovered], ['Blocked', apply.findings && apply.findings.blocked], ['Skipped because of a dependency', apply.findings && apply.findings.skippedDependency], ['Remaining', apply.findings && apply.findings.remaining]]);
        addMetricGroup(summary, 'Physical actions', [['Declared', apply.actions && apply.actions.declared], ['Committed', apply.actions && apply.actions.committed], ['Rolled back', apply.actions && apply.actions.rolledBack], ['Failed and recovered', apply.actions && apply.actions.failedRecovered], ['Source bytes removed (not app savings)', formatBytes(apply.sourceBytesRemoved)]]);
        addMetricGroup(summary, 'Transactions', [['Begun', transactions.begun], ['Committed', transactions.committed], ['Rollback verified', transactions.rolledBackVerified], ['Recovery required', transactions.recoveryRequired], ['Non-terminal', transactions.nonTerminal], ['Verification attempts', apply.verificationAttempts]]);
        const outcomes = apply.findingOutcomes;
        if (Array.isArray(outcomes)) {
          const container = $('apply-outcomes');
          append(container, 'h3', '', 'Per-finding outcomes');
          if (!outcomes.length) empty(container, 'No per-finding outcomes were recorded.');
          else outcomes.forEach(outcome => {
            const snapshot = outcome.finding || {};
            const node = snapshot.node || {};
            const status = outcome.status ? labelFor('outcomeStatus', outcome.status) : Array.isArray(outcome.states) ? outcome.states.map(state => labelFor('outcomeStatus', state)).join(', ') : labelFor('outcomeStatus', outcome.states || 'recorded');
            const item = append(container, 'section', 'outcome-card');
            append(item, 'h3', '', `${snapshot.title || outcome.findingId || 'Finding'} · ${status}`);
            const outcomeRows = [['Rule ID', snapshot.ruleId], ['Confidence', snapshot.confidence], ['Path', node.projectRelativeOrigin || node.origin], ['Transaction ID', outcome.transactionId], ['Round', outcome.round], ['Reason', outcome.reason], ['Related node IDs', outcome.relatedNodeIds], ...(outcome.rollbackVerified === true ? [['Rollback verified', 'Yes']] : outcome.rollbackVerified === false ? [['Rollback verified', 'No — recovery required']] : [])].filter(([, content]) => content !== undefined && content !== null && content !== '');
            if (outcomeRows.length) addRows(item, outcomeRows);
            const auditEntries = [['Reason code', outcome.reasonCode], ['Proposed action', labelFor('action', snapshot.proposedAction)], ['Why not safe', snapshot.whyNotSafe], ['Unreachable in', snapshot.unreachableIn], ['Reachable in', snapshot.reachableIn], ['Retained in', snapshot.retainedIn], ['Auxiliary retained in', snapshot.auxiliaryRetainedIn]].filter(([, content]) => content !== undefined && content !== null && content !== '');
            const domainRows = detailRows(snapshot.details, snapshot);
            if (snapshot.predicates || auditEntries.length || domainRows.length || (snapshot.classificationReasons || []).length || (snapshot.protectionReasons || []).length || (snapshot.evidence || []).length || (snapshot.blockerIds || snapshot.blockers || []).length || (snapshot.measurements || []).length) {
              const audit = append(item, 'section');
              append(audit, 'h3', '', 'Finding audit detail');
              if (auditEntries.length) addRows(audit, auditEntries);
              if (domainRows.length) { append(audit, 'h3', '', 'Domain details'); addRows(audit, domainRows); }
              if (snapshot.predicates) addRows(audit, Object.entries(snapshot.predicates).map(([key, state]) => [labelFor('predicate', key), state ? 'Passed' : 'Not satisfied']));
              if ((snapshot.classificationReasons || []).length) addList(audit, 'Classification reasons', snapshot.classificationReasons, reason => labelFor('classification', reason));
              if ((snapshot.protectionReasons || []).length) addList(audit, 'Protection reasons', snapshot.protectionReasons, reason => labelFor('classification', reason));
              if ((snapshot.blockerIds || snapshot.blockers || []).length) addList(audit, 'Blockers', snapshot.blockerIds || snapshot.blockers, blocker => blockerText(typeof blocker === 'string' ? findBlocker(blocker) : blocker));
              if ((snapshot.evidence || []).length) addList(audit, 'Evidence', snapshot.evidence, evidenceText);
              if ((snapshot.measurements || []).length) addList(audit, 'Measurements', snapshot.measurements, measurement => measurementText(measurement, snapshot.reportingAdapterId));
            }
          });
        }
      }
      showStatusWarnings();
      const verification = $('verification');
      if (!(report.verificationAttempts || []).length) empty(verification, 'No verification attempts were recorded.');
      else { const timeline = append(verification, 'div', 'timeline'); report.verificationAttempts.forEach(attempt => { const item = append(timeline, 'details', 'timeline-item'); item.open = !attempt.accepted || attempt.purpose === 'rollback'; const summary = append(item, 'summary'); append(summary, 'h3', '', `${labelFor('verificationPurpose', attempt.purpose)} · ${attempt.accepted ? 'Accepted' : 'Not accepted'}`); const body = append(item, 'div', 'details'); addRows(body, compactRows([['Available', attempt.available ? 'Yes' : 'No'], ['Complete', attempt.complete ? 'Yes' : 'No'], ['Round', attempt.round], ['Wave ID', attempt.waveId], ['Transaction ID', attempt.transactionId], ['Transaction count', (attempt.transactionIds || []).length || undefined], ['Transaction IDs', attempt.transactionIds], ['New failures', attempt.newFailureCount], ['Infrastructure failures', attempt.infrastructureFailureCount], ['Policy hash', attempt.policyHash], ['Required steps', attempt.requiredStepIds], ['Observed steps', attempt.observedStepIds], ['Working directory', attempt.workingDirectory], ['Toolchain', attempt.toolchainIdentity]])); const steps = append(body, 'section'); append(steps, 'h3', '', 'Verification steps'); if (!(attempt.steps || []).length) empty(steps, 'No verification steps were recorded.'); else (attempt.steps || []).forEach(step => addRows(steps, [[humanizeIdentifier(step.id), `${step.passed ? 'Passed' : 'Failed'} · ${step.available ? 'available' : 'unavailable'} · exit ${step.exitCode} · ${duration(step.elapsedMicros)}`]])); }); }
      const coverageHost = $('coverage');
      const configuredTargets = coverage.targetMatrix && coverage.targetMatrix.targets || [];
      addRows(coverageHost, [['Analysis mode', analysisMode], ['Target matrix', coverage.targetMatrix && coverage.targetMatrix.complete ? 'Complete' : 'Incomplete'], ['Configured targets', configuredTargets.length], ['Target source', coverage.targetMatrix && readableCode(coverage.targetMatrix.source)], ['Internal boundary', coverage.roots && coverage.roots.internalBoundaryComplete ? 'Complete' : 'Incomplete'], ['External consumers covered', coverage.roots && coverage.roots.externalConsumersCovered ? 'Yes' : 'No'], ['Root mode', coverage.roots && labelFor('rootMode', coverage.roots.mode)], ['Root source', coverage.roots && readableCode(coverage.roots.source)], ['Final analysis pass ID', finalPass && finalPass.id], ['Graph nodes', finalPass && graph.nodes], ['Graph edges', finalPass && graph.edges], ['Graph roots', finalPass && graph.roots], ['Graph dangling edges', finalPass && graph.danglingEdges], ['Graph dangling roots', finalPass && graph.danglingRoots], ['Failed adapters', failedAdapters.map(adapter => adapter.name || adapter.id)], ['Blockers recorded', blockerStats.recorded], ['Active unique blockers', blockerStats.activeUnique], ['Affected findings', blockerStats.affectedFindings]]);
      const blockersByProducer = Object.entries(blockerStats.byProducer || {}); if (blockersByProducer.length) { const blockerSection = append(coverageHost, 'section'); append(blockerSection, 'h3', '', 'Active blockers by producer'); addRows(blockerSection, blockersByProducer.map(([producer, count]) => [adapterName(producer), count])); }
      addList(coverageHost, 'Target configurations', configuredTargets, targetText, false);
      addList(coverageHost, 'Public entry points', coverage.roots && coverage.roots.publicEntrypoints, null, false);
      const coverageIssues = [...(coverage.targetMatrix && coverage.targetMatrix.issues || []), ...(coverage.roots && coverage.roots.issues || [])];
      addList(coverageHost, 'Coverage issues', coverageIssues, knownClassificationLabel);
      const diagnostics = $('diagnostics');
      append(diagnostics, 'h3', '', 'Diagnostics');
      if (!(report.diagnostics || []).length) empty(diagnostics, 'No diagnostics were recorded.');
      else report.diagnostics.forEach(diagnostic => { const row = append(diagnostics, 'div', 'row'); append(row, 'strong', '', humanizeIdentifier(diagnostic.code)); append(row, 'span', '', `${diagnostic.phase ? humanizeIdentifier(diagnostic.phase) + ': ' : ''}${diagnostic.message}`); });
      const adapters = $('adapters');
      const adapterPasses = report.execution && report.execution.analysisPasses || [];
      if (!adapterPasses.length) empty(adapters, 'No analysis passes were recorded.');
      else adapterPasses.forEach(pass => { const section = append(adapters, 'section'); append(section, 'h3', '', `${labelFor('analysisPass', pass.purpose)} · ${duration(pass.elapsedMicros)}`); if (!(pass.adapters || []).length) empty(section, 'No adapter records.'); else pass.adapters.forEach(adapter => { const contributions = adapter.contributions || {}; const row = append(section, 'div', 'row'); append(row, 'strong', '', adapter.name || adapter.id); append(row, 'span', '', `${labelFor('adapterStatus', adapter.status)} · ${humanizeIdentifier(adapter.role || 'reporting')} · ${duration(adapter.elapsedMicros)} · ${number(contributions.nodes)} nodes · ${number(contributions.edges)} edges · ${number(contributions.evidence)} evidence · ${number(contributions.blockers)} blockers`); }); });
      const measurements = $('measurements');
      append(measurements, 'h3', '', 'Measurements');
      const entries = statistics.measurements || [];
      if (!entries.length) empty(measurements, 'No measurements were recorded.');
      else entries.forEach(measurement => { const row = append(measurements, 'div', 'row'); append(row, 'strong', '', measurementLabel(measurement.adapterId, measurement.kind)); append(row, 'span', '', formatMeasurement(measurement)); });
      const exclusions = $('exclusions'); const exclusionStats = statistics.exclusions || {}; append(exclusions, 'h3', '', 'Observed exclusions'); addRows(exclusions, [['Policy version', exclusionStats.policyVersion], ['Total observed', exclusionStats.totalObserved]]); const exclusionReasons = Object.entries(exclusionStats.byReason || {}); if (exclusionReasons.length) addRows(exclusions, exclusionReasons.map(([reason, count]) => [humanizeIdentifier(reason), count]));
      $('render-fallback').hidden = true;
      document.documentElement.classList.remove('report-pending');
      document.documentElement.classList.add('report-ready');
    })();
  </script>
</body>
</html>''';
  }

  static String _escapeForScript(String json) => json
      .replaceAll('&', r'\u0026')
      .replaceAll('<', r'\u003c')
      .replaceAll('>', r'\u003e')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');

  static String _fallbackMarkup(RunReport report) {
    final statistics = report.finalFindingStatistics;
    final finalPass = report.analysisPasses.isEmpty
        ? null
        : report.analysisPasses.last;
    final apply = report.applyStatistics;
    final warnings = <String>[
      if (report.status == RunStatus.recoveryRequired ||
          (apply?.transactionsRecoveryRequired ?? 0) > 0 ||
          (apply?.transactionsNonTerminal ?? 0) > 0)
        'Recovery is required. Do not treat this apply run as complete.',
      if (report.partialApplied)
        'The legacy partialApplied flag marks an uncertain working-copy state. '
            'Inspect recovery evidence; do not infer that committed changes remain.',
      if (!report.targetMatrix.isComplete)
        'The configured target matrix is incomplete.',
      if (!report.rootCoverage.internalBoundaryComplete)
        'Entry-point coverage inside the selected boundary is incomplete.',
      if (!report.rootCoverage.externalConsumersCovered)
        'External consumers were not scanned.',
      if ((finalPass?.danglingEdgeCount ?? 0) > 0)
        'The final graph contains unresolved edges; automatic guidance is unsafe.',
      if ((finalPass?.danglingRootCount ?? 0) > 0)
        'The final graph contains unresolved roots; automatic guidance is unsafe.',
    ];
    final buffer = StringBuffer()
      ..write(
        '<section id="render-fallback" class="card render-fallback" '
        'role="status"><h2>Static audit summary</h2>'
        '<p class="notice">The interactive renderer did not finish. '
        'This safety summary remains available without JavaScript.</p>',
      )
      ..write('<div class="fallback-meta">')
      ..write('<span><strong>Command:</strong> ')
      ..write(_escapeHtml(report.identity.command.name.toUpperCase()))
      ..write('</span><span><strong>Status:</strong> ')
      ..write(_escapeHtml(_runStatusLabel(report.status)))
      ..write('</span><span><strong>Exit code:</strong> ')
      ..write(report.exitCode)
      ..write('</span><span><strong>Package:</strong> ')
      ..write(_escapeHtml(report.packageName))
      ..write('</span></div>');
    for (final warning in warnings) {
      buffer
        ..write('<p class="danger"><strong>Warning:</strong> ')
        ..write(_escapeHtml(warning))
        ..write('</p>');
    }
    buffer
      ..write('<p><strong>Findings:</strong> ${statistics.total} · ')
      ..write('SAFE ${statistics.byTier['SAFE'] ?? 0} · ')
      ..write('HIGH ${statistics.byTier['HIGH'] ?? 0} · ')
      ..write('REVIEW ${statistics.byTier['REVIEW'] ?? 0} · ')
      ..write('PROTECTED ${statistics.byTier['PROTECTED'] ?? 0}</p>');
    if (apply != null) {
      buffer
        ..write('<p><strong>Apply:</strong> ')
        ..write('${apply.findingsCommitted} committed · ')
        ..write('${apply.findingsRejectedRecovered} rejected and recovered · ')
        ..write('${apply.findingsRemaining} remaining · ')
        ..write('${apply.transactionsRecoveryRequired} recovery required</p>');
    }
    if (report.findings.isEmpty) {
      buffer.write('<p>No findings were reported.</p>');
    } else {
      buffer.write('<ul class="fallback-findings">');
      for (final finding in report.findings) {
        buffer
          ..write('<li><strong>')
          ..write(_escapeHtml(finding.confidence.label))
          ..write(' · ')
          ..write(_escapeHtml(finding.title))
          ..write('</strong><br><span class="notice">')
          ..write(_escapeHtml(finding.node.origin.toString()))
          ..write(' · ')
          ..write(_escapeHtml(finding.ruleId))
          ..write('</span>');
        if (finding.retainedIn.isNotEmpty) {
          buffer
            ..write('<br><span class="notice">Retained by configured targets: ')
            ..write(_escapeHtml(finding.retainedIn.join(', ')))
            ..write('</span>');
        }
        if (finding.auxiliaryRetainedIn.isNotEmpty) {
          buffer
            ..write('<br><span class="notice">Retained by auxiliary contexts: ')
            ..write(_escapeHtml(finding.auxiliaryRetainedIn.join(', ')))
            ..write('</span>');
        }
        buffer.write('</li>');
      }
      buffer.write('</ul>');
    }
    buffer.write('</section>');
    return buffer.toString();
  }

  static String _runStatusLabel(RunStatus status) => switch (status) {
    RunStatus.completed => 'Completed',
    RunStatus.noChanges => 'No changes',
    RunStatus.dryRun => 'Dry run',
    RunStatus.safeStopped => 'Stopped safely',
    RunStatus.infrastructureFailure => 'Infrastructure failure',
    RunStatus.recoveryRequired => 'Recovery required',
    RunStatus.internalError => 'Internal error',
    RunStatus.interrupted => 'Interrupted',
  };

  static String _escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

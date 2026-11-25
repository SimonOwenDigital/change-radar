import * as React from 'react';
import {
  makeStyles,
  tokens,
  Badge,
  Button,
  Card,
  Caption1,
  Dialog,
  DialogActions,
  DialogBody,
  DialogContent,
  DialogSurface,
  DialogTitle,
  Label,
  Link,
  MessageBar,
  MessageBarActions,
  MessageBarBody,
  Select,
  Spinner,
  Subtitle2,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHeader,
  TableHeaderCell,
  TableRow,
  Text,
  Title2,
  ToggleButton,
} from '@fluentui/react-components';
import { ArrowClockwiseRegular, ChevronDownRegular, ChevronRightRegular, DismissRegular, EyeRegular, ListRegular, OpenRegular, WarningRegular } from '@fluentui/react-icons';
import type {
  DataTable,
  GeneratedComponentProps,
  ReadableTableRow,
  WritableTableRow,
  crdr_asset,
  crdr_assessment,
  crdr_collectionrun,
  crdr_exposure,
  crdr_signal,
  crdr_solution,
  crdr_solutionmember,
  crdr_signalfingerprint,
  crdr_assetfingerprint,
  crdr_config,
} from './RuntimeTypes';

// ENGINE:BEGIN
// Radar logic (ADR 0012). Mirrors engine/ChangeRadar.Radar.psm1 and must reproduce tests/radar/radar.json.
// Pure functions: no React, no Dataverse, no clock. "today" is always passed in as a UTC day (epoch ms).

type EngineLive = { estateImpact?: string | null; overrideImpact?: string | null } | null | undefined;
type EngineSignal = {
  id?: string;
  title?: string;
  source?: string | null;
  horizon?: string | null;
  keyDate?: string | null;
  dateLabel?: string | null;
  actionRequired?: boolean | null;
  genericImpact?: string | null;
  nature?: string | null;
  live?: EngineLive;
};
type ItemImpact = { impact: string; basis: string };
type RadarSummary = {
  incidentsActive: number;
  actionRequired: number;
  highImpact: number;
  retiring: number;
  futureRoadmap: number;
  nextDeadline: { id: string | undefined; keyDate: string; title: string | undefined } | null;
  headline: string;
};

const DAY_MS = 86400000;
const HIGH_IMPACTS = ['high', 'critical'];
const RETIRING_NATURES = ['deprecation', 'breaking'];

// A date-only string (yyyy-MM-dd) or an ISO date-time, read as a UTC calendar day. Never local time.
function toUtcDayMs(value: string | null | undefined): number | null {
  if (!value) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(value));
  if (!m) return null;
  if (String(value).length > 10) {
    const t = Date.parse(String(value));
    if (isNaN(t)) return null;
    const d = new Date(t);
    return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
  }
  return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
}

function formatUtcDay(ms: number): string {
  const d = new Date(ms);
  const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(d.getUTCDate()).padStart(2, '0');
  return d.getUTCFullYear() + '-' + mm + '-' + dd;
}

function getDaysToLand(keyDate: string | null | undefined, todayMs: number): number | null {
  const kd = toUtcDayMs(keyDate);
  if (kd === null) return null;
  return Math.round((kd - todayMs) / DAY_MS);
}

// landed (past), next30 (0-30 days), m1to3 (31-91), m3to6 (92-183), later (184 or more), nodate (no key date).
function getTimeBucket(keyDate: string | null | undefined, todayMs: number): string {
  const d = getDaysToLand(keyDate, todayMs);
  if (d === null) return 'nodate';
  if (d < 0) return 'landed';
  if (d <= 30) return 'next30';
  if (d <= 91) return 'm1to3';
  if (d <= 183) return 'm3to6';
  return 'later';
}

// Live override, else live estate rating (when the estate still has exposure), else the signal's generic rating.
function getItemImpact(signal: EngineSignal | null | undefined, live: EngineLive): ItemImpact {
  const ov = live ? live.overrideImpact : null;
  const est = live ? live.estateImpact : null;
  const gen = signal ? signal.genericImpact : null;
  if (ov) return { impact: String(ov), basis: 'override' };
  if (est && est !== 'none') return { impact: String(est), basis: 'estate' };
  if (gen) return { impact: String(gen), basis: 'generic' };
  return { impact: 'unrated', basis: 'none' };
}

// shipped, retiring, imminent, future; 'none' for incidents (they stay in the Now tile).
function getTimelineRow(signal: EngineSignal, todayMs: number): string {
  if (signal.source === 'graph_health') return 'none';
  const d = getDaysToLand(signal.keyDate, todayMs);
  const launched = signal.source === 'roadmap' && String(signal.dateLabel || '').toLowerCase().indexOf('launched') === 0;
  if (launched || (d !== null && d < 0 && !signal.actionRequired)) return 'shipped';
  if (RETIRING_NATURES.indexOf(String(signal.nature || '')) >= 0) return 'retiring';
  if (signal.horizon === 'now' || signal.horizon === 'imminent') return 'imminent';
  return 'future';
}

function formatRadarHeadline(actionRequired: number, highImpact: number, next: { keyDate: string; title: string | undefined } | null): string {
  const a = actionRequired === 0 ? 'No items need action' : actionRequired === 1 ? '1 item needs action' : actionRequired + ' items need action';
  const h = highImpact === 0 ? 'none are rated high impact' : highImpact === 1 ? '1 is rated high impact' : highImpact + ' are rated high impact';
  const n = next ? 'The next deadline is ' + next.keyDate + ': ' + next.title + '.' : 'No upcoming deadline.';
  return a + ', and ' + h + '. ' + n;
}

function isRetiringItem(signal: EngineSignal, todayMs: number): boolean {
  if (RETIRING_NATURES.indexOf(String(signal.nature || '')) < 0) return false;
  const d = getDaysToLand(signal.keyDate, todayMs);
  return !!signal.actionRequired || d === null || d >= 0;
}

function compareTitles(a: string | undefined, b: string | undefined): number {
  return String(a || '').localeCompare(String(b || ''), 'en', { sensitivity: 'base' });
}

// Tile counts and headline over active signals (each may carry a 'live' assessment).
function getRadarSummary(signals: EngineSignal[], todayMs: number): RadarSummary {
  const items = signals.filter((s) => s.source !== 'graph_health');
  const incidents = signals.filter((s) => s.source === 'graph_health' && s.horizon === 'now').length;
  const action = items.filter((s) => !!s.actionRequired);
  const high = items.filter((s) => HIGH_IMPACTS.indexOf(getItemImpact(s, s.live).impact) >= 0).length;
  const retiring = items.filter((s) => isRetiringItem(s, todayMs)).length;
  const future = items.filter((s) => s.source === 'roadmap' && s.horizon === 'future').length;
  const upcoming = action
    .filter((s) => {
      const d = getDaysToLand(s.keyDate, todayMs);
      return d !== null && d >= 0;
    })
    .sort((a, b) => ((toUtcDayMs(a.keyDate) as number) - (toUtcDayMs(b.keyDate) as number)) || compareTitles(a.title, b.title));
  const next = upcoming.length > 0 ? upcoming[0] : null;
  const nextOut = next ? { id: next.id, keyDate: formatUtcDay(toUtcDayMs(next.keyDate) as number), title: next.title } : null;
  return {
    incidentsActive: incidents,
    actionRequired: action.length,
    highImpact: high,
    retiring,
    futureRoadmap: future,
    nextDeadline: nextOut,
    headline: formatRadarHeadline(action.length, high, nextOut),
  };
}

// Timeline grouping (display only; cases in tests/radar/radar.json "bins" and "windows"). UTC days; weeks start on Monday.
type TimelineGranularity = 'week' | 'month';
type TimelinePreset = 'next90' | 'next12m' | 'past90';
type TimelineWindow = { from: number; to: number; granularity: TimelineGranularity };

function getTimelineBin(dayMs: number, granularity: TimelineGranularity): number {
  const d = new Date(dayMs);
  if (granularity === 'month') return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1);
  const sinceMonday = (d.getUTCDay() + 6) % 7;
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - sinceMonday);
}

function getTimelineWindow(preset: TimelinePreset, todayMs: number): TimelineWindow {
  if (preset === 'next12m') return { from: getTimelineBin(todayMs, 'month'), to: todayMs + 365 * DAY_MS, granularity: 'month' };
  if (preset === 'past90') return { from: todayMs - 90 * DAY_MS, to: todayMs, granularity: 'week' };
  return { from: getTimelineBin(todayMs, 'week'), to: todayMs + 90 * DAY_MS, granularity: 'week' };
}

function getTimelineBins(w: TimelineWindow): number[] {
  const bins: number[] = [];
  let b = getTimelineBin(w.from, w.granularity);
  const last = getTimelineBin(w.to, w.granularity);
  while (b <= last) {
    bins.push(b);
    const d = new Date(b);
    b = w.granularity === 'month' ? Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1) : b + 7 * DAY_MS;
  }
  return bins;
}

// Patterns (ADR 0012 addendum, 2026-11-22): items landing from 90 days before today onwards; no key date is kept
// (landing unknown, not old); showOlder keeps everything.
const PATTERN_WINDOW_DAYS = 90;
function inPatternWindow(keyDate: string | null | undefined, todayMs: number, showOlder: boolean): boolean {
  if (showOlder) return true;
  const kd = toUtcDayMs(keyDate);
  return kd === null || kd >= todayMs - PATTERN_WINDOW_DAYS * DAY_MS;
}
// Solution view (ADR 0020; engine ChangeRadar.Solutions.psm1). Group keys per asset: its solutions' unique names
// (makers' first, each part by display name), else '(not in a solution)' when its environment has Dataverse detail,
// else '(solution not known)'.
type SolMember = { assetid: string; uniquename: string; displayname?: string; microsoft?: boolean };
type SolInfo = { uniquename: string; displayname: string; microsoft: boolean };
type SolExposure = { assetid: string; signal: string; impact: string; keyDate: string | null; actionRequired: boolean };
type SolSummaryRow = { uniquename: string; displayname: string; microsoft: boolean; assets: number; items: number; highest: string | null; nextDeadline: string | null; action: number };
const NOT_IN_SOLUTION = '(not in a solution)';
const SOLUTION_NOT_KNOWN = '(solution not known)';
const SOL_IMPACT_RANK: Record<string, number> = { none: 0, low: 1, medium: 2, high: 3, critical: 4 };

function getSolutionGroups(assets: Array<{ assetid: string; environmentid: string }>, membership: SolMember[], detailEnvironments: string[]): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  assets.forEach((a) => {
    const mine = membership
      .filter((m) => m.assetid === a.assetid)
      .slice()
      .sort((x, y) => (x.microsoft ? 1 : 0) - (y.microsoft ? 1 : 0) || (x.displayname || '').localeCompare(y.displayname || ''));
    out[a.assetid] = mine.length > 0
      ? mine.map((m) => m.uniquename)
      : [detailEnvironments.indexOf(a.environmentid) >= 0 ? NOT_IN_SOLUTION : SOLUTION_NOT_KNOWN];
  });
  return out;
}

function getSolutionSummary(solutions: SolInfo[], membership: SolMember[], exposures: SolExposure[], todayMs: number): SolSummaryRow[] {
  const rows = solutions.map((s) => {
    const assets: Record<string, true> = {};
    membership.forEach((m) => { if (m.uniquename === s.uniquename) assets[m.assetid] = true; });
    const ex = exposures.filter((x) => assets[x.assetid]);
    const distinct = (list: string[]) => Array.from(new Set(list)).length;
    let highest: string | null = null;
    ex.forEach((x) => {
      if (!(x.impact in SOL_IMPACT_RANK)) return;
      if (highest === null || SOL_IMPACT_RANK[x.impact] > SOL_IMPACT_RANK[highest]) highest = x.impact;
    });
    const future = ex
      .map((x) => toUtcDayMs(x.keyDate))
      .filter((d): d is number => d !== null && d >= todayMs)
      .sort((a, b) => a - b);
    return {
      uniquename: s.uniquename,
      displayname: s.displayname,
      microsoft: s.microsoft,
      assets: distinct(ex.map((x) => x.assetid)),
      items: distinct(ex.map((x) => x.signal)),
      highest,
      nextDeadline: future.length > 0 ? formatUtcDay(future[0]) : null,
      action: distinct(ex.filter((x) => x.actionRequired).map((x) => x.signal)),
    };
  });
  const rank = (r: SolSummaryRow) => (r.highest ? SOL_IMPACT_RANK[r.highest] : -1);
  return rows.sort((a, b) => rank(b) - rank(a) || b.items - a.items || a.displayname.localeCompare(b.displayname));
}

// demo_data (ADR 0022; engine Test-DemoDataOn): off, false, no or 0 (any case, trimmed) switch demo data off; no value
// leaves it on.
function isDemoDataOn(value: string | null | undefined): boolean {
  const v = (value || '').trim().toLowerCase();
  return ['off', 'false', 'no', '0'].indexOf(v) < 0;
}

// Which estate the page shows (Simon 2026-11-24, 'Demo replaces live'; engine Get-EstateShown, tests/config estateShown):
// the demo organisation while demo data is on, the live estate while it's off. One at a time: never mixed.
// With no demo data loaded, the live estate whatever the setting, never an empty demo one.
function estateShown(value: string | null | undefined, loaded: boolean): 'synthetic' | 'live' {
  return loaded && isDemoDataOn(value) ? 'synthetic' : 'live';
}

// What the header's demo data switch writes to demo_data (engine Get-DemoDataValue; tests/config demoToggle).
function demoDataValue(on: boolean): string {
  return on ? 'on' : 'off';
}

// Related signals (Simon, 2026-11-24; engine Get-RelatedSignals): an accepted signal fingerprint on one of the related
// facets whose value a component of the solution also has (no case). Signals that affect the solution are left out.
type RelFingerprint = { facet: string; value: string };
const RELATED_FACETS = ['connector', 'capability', 'model', 'setting', 'harness', 'auth_mode'];
function getRelatedSignals(
  solutionAssets: string[],
  assetFingerprints: Array<RelFingerprint & { assetid: string }>,
  signalFingerprints: Array<RelFingerprint & { signal: string; status: string }>,
  affects: string[],
  facets: string[],
): Array<{ signal: string; links: string[] }> {
  const inSolution: Record<string, true> = {};
  solutionAssets.forEach((a) => { inSolution[a] = true; });
  const have: Record<string, true> = {};
  assetFingerprints.forEach((f) => {
    if (inSolution[f.assetid] && facets.indexOf(f.facet) >= 0) have[f.facet + '|' + (f.value || '').toLowerCase()] = true;
  });
  const links: Record<string, Record<string, true>> = {};
  signalFingerprints.forEach((f) => {
    if (f.status !== 'accepted' || affects.indexOf(f.signal) >= 0) return;
    const k = f.facet + '|' + (f.value || '').toLowerCase();
    if (!have[k]) return;
    (links[f.signal] = links[f.signal] || {})[k.replace('|', ': ')] = true;
  });
  return Object.keys(links).sort().map((s) => ({ signal: s, links: Object.keys(links[s]).sort() }));
}
// ENGINE:END

// ---------------------------------------------------------------------------------------------
// The page error block (rules.md, Missing Error Handling), unchanged apart from PAGE_NAME.

type PageErrorKind = 'read' | 'write' | 'indeterminate' | 'network' | 'render';
type PageErrorView = {
  operation: string;
  message: string;
  fallbackKey: string;
  code?: string;
  kind: PageErrorKind;
  retry?: () => void;
};
type PageErrorTelemetry = {
  trackException?: (error: unknown, properties?: Record<string, unknown>) => void;
};

const PAGE_NAME = 'Radar';

const ERROR_COPY: Record<string, string> = {
  'error.read': 'Unable to load data. Please try again.',
  'error.write': 'The change could not be saved. Refresh before trying again.',
  'error.network': 'The request did not go through. You can try again.',
  'error.indeterminate': "We couldn't confirm this completed — refresh before retrying.",
  'error.render': 'This page hit a problem and could not render. Refresh the page.',
  'error.tryAgain': 'Try again',
};

function translate(key: string): string {
  return ERROR_COPY[key] || key;
}

function reportPageError(
  pageName: string,
  operation: string,
  code: unknown,
  message: unknown,
  kind: PageErrorKind,
  retry?: () => void,
  appInsights?: PageErrorTelemetry,
): PageErrorView {
  const fields: Record<string, unknown> = {};
  for (const path of ['code', 'errorCode', 'message', 'error.code', 'error.message']) {
    try {
      let value: unknown = message;
      for (const part of path.split('.')) {
        value = value !== null && typeof value === 'object' ? (value as Record<string, unknown>)[part] : undefined;
      }
      fields[path] = value;
    } catch {
      fields[path] = undefined;
    }
  }
  let normalizedCode = '';
  for (const candidate of [code, fields['code'], fields['errorCode'], fields['error.code']]) {
    const text = typeof candidate === 'string' ? candidate : typeof candidate === 'number' && Number.isFinite(candidate) ? String(candidate) : '';
    normalizedCode = text.replace(/[\s\u0000-\u001f\u007f-\u009f]+/g, ' ').trim().slice(0, 80);
    if (normalizedCode) break;
  }
  let normalizedMessage = '';
  for (const candidate of [message, fields['message'], fields['error.message']]) {
    const line = typeof candidate === 'string' ? candidate.trim().split(/[\r\n\u2028\u2029]/)[0].replace(/[\s\u0000-\u001f\u007f-\u009f]+/g, ' ').trim() : '';
    if (!line || /^\[object [^\]]*\]$/.test(line) || /^at\s.*(?::\d+:\d+\)?|\((?:native|<anonymous>)\))$/.test(line)) continue;
    normalizedMessage = line.length > 300 ? line.slice(0, 299) + '\u2026' : line;
    break;
  }
  console.error('[' + String(pageName).replace(/[\r\n\]]/g, '') + '] ' + operation + ' failed', { code: normalizedCode, message: normalizedMessage });
  void appInsights;
  const quiet = kind === 'indeterminate' || kind === 'render';
  const view: PageErrorView = { operation, message: quiet ? '' : normalizedMessage, fallbackKey: 'error.' + kind, kind };
  if (normalizedCode) view.code = normalizedCode;
  if (typeof retry === 'function' && (kind === 'read' || kind === 'network')) view.retry = retry;
  return view;
}

function PageErrorBar(props: { error: PageErrorView | null }) {
  const { error } = props;
  if (!error) return null;
  return (
    <MessageBar intent="error">
      <MessageBarBody>{error.message || translate(error.fallbackKey)}</MessageBarBody>
      {error.retry && (
        <MessageBarActions>
          <Button onClick={error.retry}>{translate('error.tryAgain')}</Button>
        </MessageBarActions>
      )}
    </MessageBar>
  );
}

class PageErrorBoundary extends React.Component<
  { children: React.ReactNode; appInsights?: PageErrorTelemetry },
  { failed: boolean }
> {
  public state = { failed: false };

  public static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true };
  }

  public componentDidCatch(error: Error): void {
    reportPageError(PAGE_NAME, 'render', undefined, error, 'render');
  }

  public render(): React.ReactNode {
    if (this.state.failed) {
      return (
        <MessageBar intent="error">
          <MessageBarBody>{translate('error.render')}</MessageBarBody>
        </MessageBar>
      );
    }
    return this.props.children;
  }
}

// ---------------------------------------------------------------------------------------------
// Lookup references (rules.md, Lookup references), unchanged.

type LookupReference = { table: string; id: string };
type LookupNormalization =
  | { state: 'unset' }
  | { state: 'resolved'; reference: LookupReference }
  | { state: 'needs-target'; id: string }
  | { state: 'invalid' };

const LOOKUP_GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const LOOKUP_QUALIFIED = /^\/([a-z_][a-z0-9_]*)\(([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\)$/;

function normalizeLookupReference(
  row: unknown,
  property: string,
  allowedTargets: readonly string[],
): LookupNormalization {
  if (typeof row !== 'object' || row === null || Array.isArray(row) || allowedTargets.length === 0) return { state: 'invalid' };
  const record = row as Record<string, unknown>;
  if (!Object.prototype.hasOwnProperty.call(record, property)) return { state: 'invalid' };
  const raw = record[property];
  if (raw === null) return { state: 'unset' };
  if (typeof raw !== 'string') return { state: 'invalid' };
  const value = raw.trim();
  const qualified = LOOKUP_QUALIFIED.exec(value);
  if (!qualified && !LOOKUP_GUID.test(value)) return { state: 'invalid' };
  const prefix = qualified ? qualified[1] : undefined;
  const id = (qualified ? qualified[2] : value).toLowerCase();
  if (prefix !== undefined && !allowedTargets.includes(prefix)) return { state: 'invalid' };
  const annotationKey = `${property}@Microsoft.Dynamics.CRM.lookuplogicalname`;
  let annotation: string | undefined;
  if (Object.prototype.hasOwnProperty.call(record, annotationKey)) {
    const named = record[annotationKey];
    if (typeof named !== 'string' || !allowedTargets.includes(named)) return { state: 'invalid' };
    annotation = named;
  }
  if (annotation !== undefined && prefix !== undefined && annotation !== prefix) return { state: 'invalid' };
  const table = annotation ?? prefix ?? (allowedTargets.length === 1 ? allowedTargets[0] : undefined);
  return table === undefined ? { state: 'needs-target', id } : { state: 'resolved', reference: { table, id } };
}

// ---------------------------------------------------------------------------------------------
// Choice values (schema.json order; option value = 169890000 + ordinal) and labels.

const SOURCE_CODES: Record<number, string> = {
  169890000: 'graph_mc', 169890001: 'graph_health', 169890002: 'roadmap', 169890003: 'blog', 169890004: 'community_archive', 169890005: 'manual', 169890006: 'feed',
};
const SOURCE_LABELS: Record<string, string> = {
  graph_mc: 'Message Center', graph_health: 'Service health', roadmap: 'Roadmap', blog: 'Blog', community_archive: 'Community archive', manual: 'Manual', feed: 'Feeds (Learn pages and blogs)',
};
const SOURCE_ORDER = ['graph_mc', 'graph_health', 'roadmap', 'feed', 'blog', 'community_archive', 'manual'];
const HORIZON_CODES: Record<number, string> = { 169890000: 'now', 169890001: 'imminent', 169890002: 'future' };
const HORIZON_OPTIONS: Array<{ value: string; label: string }> = [
  { value: 'now', label: 'Now' },
  { value: 'imminent', label: 'Imminent' },
  { value: 'future', label: 'Future' },
];
const IMPACT_CODES: Record<number, string> = { 169890000: 'none', 169890001: 'low', 169890002: 'medium', 169890003: 'high', 169890004: 'critical' };
const IMPACT_LABELS: Record<string, string> = { none: 'None', low: 'Low', medium: 'Medium', high: 'High', critical: 'Critical', unrated: 'Not yet rated' };
const IMPACT_RANK: Record<string, number> = { critical: 5, high: 4, medium: 3, low: 2, none: 1, unrated: 0 };
const IMPACT_TYPE_CODES: Record<number, string> = { 169890000: 'risk', 169890001: 'opportunity', 169890002: 'risk_and_opportunity' };
const IMPACT_TYPE_LABELS: Record<string, string> = { risk: 'Risk', opportunity: 'Opportunity', risk_and_opportunity: 'Risk and opportunity' };
const NATURE_CODES: Record<number, string> = {
  169890000: 'breaking', 169890001: 'deprecation', 169890002: 'behaviour_change', 169890003: 'new_capability', 169890004: 'licensing', 169890005: 'incident', 169890006: 'informational',
};
const ASSET_SOURCE_LIVE = 169890000;
const ASSET_SOURCE_SYNTHETIC = 169890002;
const ASSET_SOURCE_LABELS: Record<number, string> = { 169890000: 'Live', 169890001: 'Fixture', 169890002: 'Synthetic' };
const ENV_TYPE_LABELS: Record<number, string> = { 169890000: 'Production', 169890001: 'Sandbox', 169890002: 'Developer', 169890003: 'Default', 169890004: 'Trial' };
const TIER_LABELS: Record<number, string> = { 169890000: 'Full', 169890001: 'Reader', 169890002: 'Maker', 169890003: 'Public' };
const TIER_MEANING: Record<number, string> = {
  169890000: 'Full access: every source is read, and the estate covers the whole tenant.',
  169890001: 'Reader access: Message Center through your own access; the estate covers only environments you can reach.',
  169890002: 'Maker access: public sources only; the estate covers only what you own or can see.',
  169890003: 'Public access: public sources only; no estate, so every rating is generic.',
};
const TIER_LIMIT_ORDER: Record<number, number> = { 169890003: 0, 169890002: 1, 169890001: 2, 169890000: 3 };
const THEMES = [
  'Copilot Credits and consumption',
  'Capability moving into Copilot',
  'Governance and controls',
  'Agents and Work IQ platform',
  'Maker experience',
  'Copilot for end users',
  'AI models and lifecycle',
  'Other',
];
// seed/themes.csv also has 'Service incidents' (a rule theme). This page lists service health incidents only in the
// active incidents tile, never as items, so that theme would always be empty here and is left out.
const NOT_THEMED = '__none';
const NOT_RATED = '__none';

// Simon, 2026-11-24: 'Later or landed' split into Landed and Later; items without a key date are counted beside the grid.
const BUCKETS: Array<{ key: string; label: string }> = [
  { key: 'landed', label: 'Landed' },
  { key: 'next30', label: 'Next 30 days' },
  { key: 'm1to3', label: '1–3 months' },
  { key: 'm3to6', label: '3–6 months' },
  { key: 'later', label: 'Later' },
];
const MATRIX_ROWS: Array<{ key: string; label: string }> = [
  { key: 'high', label: 'High or critical' },
  { key: 'medium', label: 'Medium' },
  { key: 'low', label: 'Low' },
  { key: 'none', label: 'Rated no impact' },
  { key: 'unrated', label: 'Not yet rated' },
];
const TIMELINE_ROWS: Array<{ key: string; label: string }> = [
  { key: 'imminent', label: 'Imminent' },
  { key: 'retiring', label: 'Retiring' },
  { key: 'shipped', label: 'Shipped' },
  { key: 'future', label: 'Future' },
];
const CELL_LIMIT = 8;
const TABLE_LIMIT = 20;

type SignalRow = ReadableTableRow<crdr_signal>;
type AssessmentRow = ReadableTableRow<crdr_assessment>;
type ExposureRow = ReadableTableRow<crdr_exposure>;
type AssetRow = ReadableTableRow<crdr_asset>;
type RunRow = ReadableTableRow<crdr_collectionrun>;
type SolutionRow = ReadableTableRow<crdr_solution>;
type MemberRow = ReadableTableRow<crdr_solutionmember>;
type SignalFpRow = ReadableTableRow<crdr_signalfingerprint>;
type AssetFpRow = ReadableTableRow<crdr_assetfingerprint>;
type ConfigRow = ReadableTableRow<crdr_config>;

type RawBundle = {
  signals: SignalRow[];
  assessments: AssessmentRow[];
  exposures: ExposureRow[];
  assets: AssetRow[];
  hasDemoData: boolean;
  runs: RunRow[];
  solutions: SolutionRow[];
  members: MemberRow[];
  signalFps: SignalFpRow[];
  assetFps: AssetFpRow[];
  demoData: string | null;
  demoConfigId: string | null; // the demo_data row, so the header switch can change it (null: no row, demo data on)
};

// A solution as the page shows it: one per source and unique name (a solution deployed to several environments is one
// solution here), plus the two catch-all groups. Live and demo never share a key.
type SolutionOption = { key: string; source: number; uniquename: string; label: string; microsoft: boolean; catchAll: boolean };

type AssessmentView = {
  source: number | null;
  estateImpact: string | null;
  overrideImpact: string | null;
  rationale: string;
  action: string;
  assessedOn: number;
};

type Item = {
  id: string;
  ref: string;
  title: string;
  summary: string;
  products: string[];
  productsText: string;
  source: string;
  horizon: string | null;
  keyDate: string | null;
  dateLabel: string;
  actionRequired: boolean;
  genericImpact: string | null;
  nature: string | null;
  impactType: string | null;
  risk: string;
  opportunity: string;
  audience: string;
  theme: string | null;
  watched: boolean;
  confidence: string;
  url: string;
  live: AssessmentView | null;
  impact: ItemImpact;
  solutionKeys: string[];
  // Solutions this signal is related to (not affects): solution key -> links such as 'connector: shared_teams'.
  related: Record<string, string[]>;
};

type EstateEntry = {
  key: string;
  item: Item;
  sourceLabel: string;
  assetCount: number;
  byType: Array<{ label: string; count: number }>;
  byEnv: Array<{ label: string; count: number }>;
  assessment: AssessmentView | null;
  impact: string;
  assetIds: string[];
  source: number;
};

// solutionScope: '' = signals that affect the solution and signals related to it; 'affects' = exposures only.
type Filters = { tile: string; horizon: string; source: string; product: string; theme: string; impactType: string; watched: string; solution: string; solutionScope: string };
const EMPTY_FILTERS: Filters = { tile: '', horizon: '', source: '', product: '', theme: '', impactType: '', watched: '', solution: '', solutionScope: '' };
const FACET_CODES: Record<number, string> = {
  169890000: 'product', 169890001: 'resource_type', 169890002: 'connector', 169890003: 'capability', 169890004: 'auth_mode',
  169890005: 'harness', 169890006: 'setting', 169890007: 'environment_type', 169890008: 'model',
};
const FINGERPRINT_ACCEPTED = 169890000;
const RELATED_FACET_FILTER = RELATED_FACETS.map((f) => {
  const code = Object.keys(FACET_CODES).filter((c) => FACET_CODES[Number(c)] === f)[0];
  return 'crdr_facet eq ' + code;
}).join(' or ');

// ---------------------------------------------------------------------------------------------
// Row mapping helpers.

function codeOf(value: unknown, map: Record<number, string>): string | null {
  const n = typeof value === 'number' ? value : typeof value === 'string' && value !== '' ? Number(value) : NaN;
  return isNaN(n) ? null : map[n] || null;
}

function isTrue(value: unknown): boolean {
  return value === true || value === 1 || value === '1' || value === 'true';
}

function textOf(value: unknown): string {
  return typeof value === 'string' ? value : value === null || value === undefined ? '' : String(value);
}

// A date-only column may arrive as a yyyy-MM-dd string, an ISO string, or a Date the host built either at UTC
// midnight or at local midnight. Return the calendar day as yyyy-MM-dd.
function toDayString(value: unknown): string | null {
  if (value === null || value === undefined || value === '') return null;
  if (value instanceof Date) {
    if (isNaN(value.getTime())) return null;
    const utcMidnight = value.getUTCHours() === 0 && value.getUTCMinutes() === 0;
    const ms = utcMidnight
      ? Date.UTC(value.getUTCFullYear(), value.getUTCMonth(), value.getUTCDate())
      : Date.UTC(value.getFullYear(), value.getMonth(), value.getDate());
    return formatUtcDay(ms);
  }
  const s = String(value);
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  const ms = toUtcDayMs(s);
  return ms === null ? null : formatUtcDay(ms);
}

function timeOf(value: unknown): number {
  if (value instanceof Date) return value.getTime();
  const t = Date.parse(textOf(value));
  return isNaN(t) ? 0 : t;
}

function stripHtml(html: string): string {
  const named: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
  const text = html
    .replace(/<(br|\/p|\/li|\/h\d)[^>]*>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&(#\d+|#x[0-9a-f]+|[a-z]+);/gi, (whole, ent: string) => {
      if (ent[0] === '#') {
        const code = ent[1] === 'x' || ent[1] === 'X' ? parseInt(ent.slice(2), 16) : parseInt(ent.slice(1), 10);
        return isNaN(code) ? whole : String.fromCharCode(code);
      }
      return named[ent.toLowerCase()] ?? whole;
    });
  return text.replace(/\s+/g, ' ').trim();
}

function cut(text: string, max: number): string {
  return text.length > max ? text.slice(0, max - 1).trimEnd() + '\u2026' : text;
}

function splitProducts(value: string): string[] {
  const parts = value.split(/[;,]/).map((p) => p.trim()).filter((p) => p !== '');
  return Array.from(new Set(parts));
}

function lookupId(row: unknown, property: string, target: string): string | null {
  const n = normalizeLookupReference(row, property, [target]);
  return n.state === 'resolved' ? n.reference.id : null;
}

function toAssessmentView(row: AssessmentRow): AssessmentView {
  const r = row as unknown as Record<string, unknown>;
  return {
    source: typeof r.crdr_source === 'number' ? (r.crdr_source as number) : r.crdr_source ? Number(r.crdr_source) : null,
    estateImpact: codeOf(r.crdr_estateimpact, IMPACT_CODES),
    overrideImpact: codeOf(r.crdr_overrideimpact, IMPACT_CODES),
    rationale: textOf(r.crdr_rationale),
    action: textOf(r.crdr_recommendedaction),
    assessedOn: timeOf(r.crdr_assessedon),
  };
}

function utcTodayMs(): number {
  const now = new Date();
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
}

function formatDisplayDate(day: string | null): string {
  const ms = toUtcDayMs(day);
  if (ms === null) return 'No date';
  return new Date(ms).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
}

function countBy(labels: string[]): Array<{ label: string; count: number }> {
  const counts: Record<string, number> = {};
  labels.forEach((l) => { counts[l] = (counts[l] || 0) + 1; });
  return Object.keys(counts)
    .map((label) => ({ label, count: counts[label] }))
    .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
}

function byDateThenTitle(a: Item, b: Item): number {
  const da = toUtcDayMs(a.keyDate);
  const db = toUtcDayMs(b.keyDate);
  if (da !== db) {
    if (da === null) return 1;
    if (db === null) return -1;
    return da - db;
  }
  return compareTitles(a.title, b.title);
}

function impactRow(impact: string): string {
  if (impact === 'high' || impact === 'critical') return 'high';
  if (impact === 'medium' || impact === 'low' || impact === 'none') return impact;
  return 'unrated';
}

function themeKey(item: Item): string {
  if (!item.theme) return NOT_THEMED;
  return THEMES.indexOf(item.theme) >= 0 ? item.theme : 'Other';
}

function impactBadgeColour(impact: string): 'danger' | 'warning' | 'success' | 'informative' {
  if (impact === 'high' || impact === 'critical') return 'danger';
  if (impact === 'medium') return 'warning';
  if (impact === 'low') return 'success';
  return 'informative';
}

function basisLabel(basis: string): string {
  if (basis === 'override') return 'override';
  if (basis === 'estate') return 'estate rating';
  if (basis === 'generic') return 'generic rating';
  return 'not yet rated';
}

function passesTile(item: Item, tile: string, todayMs: number): boolean {
  if (!tile) return true;
  if (tile === 'now') return false;
  if (tile === 'action') return item.actionRequired;
  if (tile === 'high') return HIGH_IMPACTS.indexOf(item.impact.impact) >= 0;
  if (tile === 'retiring') return isRetiringItem(item, todayMs);
  if (tile === 'future') return item.source === 'roadmap' && item.horizon === 'future';
  return true;
}

function passesBar(item: Item, f: Filters): boolean {
  if (f.solution && item.solutionKeys.indexOf(f.solution) < 0 && (f.solutionScope === 'affects' || !item.related[f.solution])) return false;
  if (f.horizon && item.horizon !== f.horizon) return false;
  if (f.source && item.source !== f.source) return false;
  if (f.product && item.products.indexOf(f.product) < 0) return false;
  if (f.theme && themeKey(item) !== f.theme) return false;
  // Watch list (ADR 0015): signals a topic put on the list, or someone marked Watched.
  if (f.watched === 'watched' && !item.watched) return false;
  if (f.impactType) {
    if (f.impactType === NOT_RATED) { if (item.impactType) return false; }
    else if (item.impactType !== f.impactType) return false;
  }
  return true;
}

function openSignalForm(id: string, onError: (view: PageErrorView) => void): void {
  try {
    const xrm = (window as unknown as { Xrm?: { Navigation?: { openForm?: (o: unknown) => Promise<unknown> } } }).Xrm;
    const result = xrm?.Navigation?.openForm?.({ entityName: 'crdr_signal', entityId: id });
    if (result && typeof (result as Promise<unknown>).catch === 'function') {
      (result as Promise<unknown>).catch((error) => onError(reportPageError(PAGE_NAME, 'openSignal', undefined, error, 'read')));
    }
  } catch (error) {
    onError(reportPageError(PAGE_NAME, 'openSignal', undefined, error, 'read'));
  }
}

// ---------------------------------------------------------------------------------------------
// Data loading: one cached bundle, de-duplicated across the host double-mount (data-caching.md).

const winAny = window as any;
// v3: the bundle gained solutions and members (v2, ADR 0020) fingerprints for related signals (v3) the demo_data switch (v4) and its row id for the header switch (v5); a bundle cached by an earlier version must not be reused.
const CACHE_KEY = '__ppRadarHome_bundleCache_v5';
const INFLIGHT_KEY = '__ppRadarHome_bundleInflight_v5';

async function readAllRows<T>(first: DataTable<T>): Promise<T[]> {
  let page = first;
  const rows: T[] = page.rows.slice();
  while (page.hasMoreRows && page.loadMoreRows) {
    page = await page.loadMoreRows();
    page.rows.forEach((r) => rows.push(r));
  }
  return rows;
}

async function loadBundle(dataApi: GeneratedComponentProps['dataApi']): Promise<RawBundle> {
  const results = await Promise.allSettled([
    dataApi
      .queryTable('crdr_signal', {
        select: [
          'crdr_signalid', 'crdr_title', 'crdr_source', 'crdr_externalid', 'crdr_summary', 'crdr_products', 'crdr_horizon', 'crdr_keydate',
          'crdr_datelabel', 'crdr_actionrequired', 'crdr_url', 'crdr_genericimpact', 'crdr_nature', 'crdr_impacttype', 'crdr_risk',
          'crdr_opportunity', 'crdr_audience', 'crdr_theme', 'crdr_ratingconfidence', 'crdr_watched',
        ],
        filter: 'statecode eq 0',
        pageSize: 500,
      })
      .then((t) => readAllRows(t)),
    dataApi
      .queryTable('crdr_assessment', {
        select: ['crdr_assessmentid', '_crdr_signal_value', 'crdr_source', 'crdr_estateimpact', 'crdr_overrideimpact', 'crdr_rationale', 'crdr_recommendedaction', 'crdr_assessedon'],
        pageSize: 500,
      })
      .then((t) => readAllRows(t)),
    dataApi
      .queryTable('crdr_exposure', {
        select: ['crdr_exposureid', '_crdr_signal_value', '_crdr_asset_value', 'crdr_source', 'crdr_status'],
        filter: 'crdr_status eq 169890000 or crdr_status eq 169890001',
        pageSize: 500,
      })
      .then((t) => readAllRows(t)),
    dataApi.queryTable('crdr_asset', { select: ['crdr_assetid'], filter: 'crdr_source ne 169890000', pageSize: 1 }),
    dataApi.queryTable('crdr_collectionrun', { select: ['crdr_collectionrunid', 'crdr_collector', 'crdr_accesstier', 'crdr_startedon'], orderBy: 'crdr_startedon desc', pageSize: 500 }),
    dataApi
      .queryTable('crdr_solution', { select: ['crdr_solutionid', 'crdr_name', 'crdr_uniquename', 'crdr_environmentid', 'crdr_microsoft', 'crdr_source'], pageSize: 500 })
      .then((t) => readAllRows(t)),
    dataApi
      .queryTable('crdr_solutionmember', { select: ['crdr_solutionmemberid', '_crdr_asset_value', '_crdr_solution_value'], pageSize: 500 })
      .then((t) => readAllRows(t)),
    dataApi
      .queryTable('crdr_signalfingerprint', {
        select: ['crdr_signalfingerprintid', '_crdr_signal_value', 'crdr_facet', 'crdr_value'],
        filter: 'crdr_status eq ' + FINGERPRINT_ACCEPTED + ' and (' + RELATED_FACET_FILTER + ')',
        pageSize: 500,
      })
      .then((t) => readAllRows(t)),
    dataApi.queryTable('crdr_config', { select: ['crdr_configid', 'crdr_value'], filter: "crdr_key eq 'demo_data'", pageSize: 1 }),
    dataApi
      .queryTable('crdr_assetfingerprint', { select: ['crdr_assetfingerprintid', '_crdr_asset_value', 'crdr_facet', 'crdr_value'], filter: RELATED_FACET_FILTER, pageSize: 500 })
      .then((t) => readAllRows(t)),
  ]);
  const operations = ['loadSignals', 'loadAssessments', 'loadExposures', 'loadDemoBadge', 'loadCollectionRuns', 'loadSolutions', 'loadSolutionMembers', 'loadSignalFingerprints', 'loadDemoSwitch', 'loadAssetFingerprints'];
  let firstFailure: { operation: string; reason: unknown } | null = null;
  results.forEach((r, i) => {
    if (r.status === 'rejected' && !firstFailure) firstFailure = { operation: operations[i], reason: r.reason };
  });
  if (firstFailure) throw firstFailure;
  const signals = (results[0] as PromiseFulfilledResult<SignalRow[]>).value;
  const assessments = (results[1] as PromiseFulfilledResult<AssessmentRow[]>).value;
  const exposures = (results[2] as PromiseFulfilledResult<ExposureRow[]>).value;
  const demo = (results[3] as PromiseFulfilledResult<DataTable<AssetRow>>).value;
  const runs = (results[4] as PromiseFulfilledResult<DataTable<RunRow>>).value.rows;
  const solutions = (results[5] as PromiseFulfilledResult<SolutionRow[]>).value;
  const members = (results[6] as PromiseFulfilledResult<MemberRow[]>).value;
  const signalFps = (results[7] as PromiseFulfilledResult<SignalFpRow[]>).value;
  const demoRows = (results[8] as PromiseFulfilledResult<DataTable<ConfigRow>>).value.rows;
  const assetFps = (results[9] as PromiseFulfilledResult<AssetFpRow[]>).value;
  const demoData = demoRows.length > 0 ? textOf((demoRows[0] as unknown as Record<string, unknown>).crdr_value) : null;
  const demoConfigId = demoRows.length > 0 ? textOf((demoRows[0] as unknown as Record<string, unknown>).crdr_configid) || null : null;

  // Assets behind the open exposures (the data API reads one table at a time).
  const assetIds = Array.from(new Set(exposures.map((e) => lookupId(e, '_crdr_asset_value', 'crdr_asset')).filter((id): id is string => !!id)));
  const assets: AssetRow[] = [];
  for (let i = 0; i < assetIds.length; i += 15) {
    const chunk = assetIds.slice(i, i + 15);
    try {
      const page = await dataApi.queryTable('crdr_asset', {
        select: ['crdr_assetid', 'crdr_name', 'crdr_resourcetype', 'crdr_environmenttype', 'crdr_environmentid', 'crdr_source'],
        filter: chunk.map((id) => 'crdr_assetid eq ' + id).join(' or '),
        pageSize: 50,
      });
      (await readAllRows(page)).forEach((a) => assets.push(a));
    } catch (reason) {
      throw { operation: 'loadAssets', reason };
    }
  }
  return { signals, assessments, exposures, assets, hasDemoData: demo.rows.length > 0, runs, solutions, members, signalFps, assetFps, demoData, demoConfigId };
}

// ---------------------------------------------------------------------------------------------
// Styles.

const useStyles = makeStyles({
  root: {
    height: '100%',
    overflowY: 'auto',
    boxSizing: 'border-box',
    position: 'relative',
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalL,
    padding: tokens.spacingHorizontalL,
    color: tokens.colorNeutralForeground1,
    backgroundColor: tokens.colorNeutralBackground2,
  },
  header: { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: tokens.spacingHorizontalM, flexShrink: 0 },
  headerTitle: { marginRight: 'auto' },
  note: { color: tokens.colorNeutralForeground3 },
  headline: { fontSize: tokens.fontSizeBase500, lineHeight: tokens.lineHeightBase500, fontWeight: tokens.fontWeightSemibold, flexShrink: 0 },
  tiles: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: tokens.spacingHorizontalM, flexShrink: 0 },
  tile: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'flex-start',
    height: 'auto',
    minHeight: '84px',
    padding: tokens.spacingHorizontalM,
    textAlign: 'left',
  },
  tileCount: { fontSize: tokens.fontSizeHero800, lineHeight: tokens.lineHeightHero800, fontWeight: tokens.fontWeightSemibold },
  filters: { display: 'flex', flexWrap: 'wrap', alignItems: 'flex-end', gap: tokens.spacingHorizontalM, flexShrink: 0 },
  filter: { display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalXXS, minWidth: '160px' },
  card: { flexShrink: 0, display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalM },
  sectionHead: { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: tokens.spacingHorizontalM },
  sectionTitle: { marginRight: 'auto' },
  sectionH2: { marginTop: '0', marginBottom: '0', marginRight: 'auto' },
  sectionToggle: {
    border: 'none',
    backgroundColor: 'transparent',
    padding: '0',
    display: 'inline-flex',
    alignItems: 'center',
    gap: tokens.spacingHorizontalS,
    textAlign: 'left',
    cursor: 'pointer',
    color: tokens.colorNeutralForeground1,
    fontFamily: tokens.fontFamilyBase,
    ':hover': { color: tokens.colorBrandForeground1 },
    ':focus-visible': { outline: '2px solid ' + tokens.colorStrokeFocus2 },
  },
  sectionBody: { display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalM },
  sectionTools: { display: 'flex', flexWrap: 'wrap', gap: tokens.spacingHorizontalS, justifyContent: 'flex-end' },
  scrollX: { overflowX: 'auto' },
  itemButton: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'flex-start',
    gap: '2px',
    width: '100%',
    textAlign: 'left',
    cursor: 'pointer',
    padding: '4px 6px 4px 10px',
    border: 'none',
    borderRadius: tokens.borderRadiusSmall,
    backgroundColor: tokens.colorNeutralBackground1,
    color: tokens.colorNeutralForeground1,
    fontFamily: tokens.fontFamilyBase,
    fontSize: tokens.fontSizeBase200,
    boxShadow: tokens.shadow2,
    ':hover': { backgroundColor: tokens.colorNeutralBackground1Hover },
    ':focus-visible': { outline: '2px solid ' + tokens.colorStrokeFocus2, outlineOffset: '1px' },
  },
  itemMeta: { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: '4px', color: tokens.colorNeutralForeground3, fontSize: tokens.fontSizeBase100 },
  actionMark: { color: tokens.colorPaletteRedForeground1, fontWeight: tokens.fontWeightSemibold, display: 'inline-flex', alignItems: 'center', gap: '2px' },
  themes: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: tokens.spacingHorizontalM },
  theme: { display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalXS, padding: tokens.spacingHorizontalS, backgroundColor: tokens.colorNeutralBackground3, borderRadius: tokens.borderRadiusMedium },
  themeHead: { display: 'flex', alignItems: 'baseline', gap: tokens.spacingHorizontalS },
  tlControls: { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: tokens.spacingHorizontalS },
  tlScroll: { overflowX: 'auto', maxWidth: '100%' },
  tlTable: { borderCollapse: 'collapse', width: '100%', minWidth: '720px', tableLayout: 'fixed' },
  mxRowHead: { width: '130px', textAlign: 'left', paddingTop: tokens.spacingVerticalS, paddingBottom: tokens.spacingVerticalS, paddingRight: tokens.spacingHorizontalS, fontWeight: tokens.fontWeightSemibold, color: tokens.colorNeutralForeground2, fontSize: tokens.fontSizeBase200 },
  tlRowHead: { width: '96px', textAlign: 'left', paddingTop: tokens.spacingVerticalS, paddingBottom: tokens.spacingVerticalS, paddingRight: tokens.spacingHorizontalS, fontWeight: tokens.fontWeightSemibold, color: tokens.colorNeutralForeground2, fontSize: tokens.fontSizeBase200 },
  tlHead: { fontWeight: tokens.fontWeightRegular, fontSize: tokens.fontSizeBase100, color: tokens.colorNeutralForeground3, textAlign: 'center', paddingBottom: tokens.spacingVerticalXS, verticalAlign: 'bottom' },
  tlHeadNow: { fontWeight: tokens.fontWeightSemibold, fontSize: tokens.fontSizeBase100, color: tokens.colorBrandForeground1, textAlign: 'center', paddingBottom: tokens.spacingVerticalXS, verticalAlign: 'bottom', backgroundColor: tokens.colorBrandBackground2 },
  tlNowTag: { display: 'block', fontSize: tokens.fontSizeBase100, fontWeight: tokens.fontWeightRegular },
  tlCell: { textAlign: 'center', paddingTop: '4px', paddingBottom: '4px', borderTopWidth: '1px', borderTopStyle: 'solid', borderTopColor: tokens.colorNeutralStroke3 },
  tlCellNow: { textAlign: 'center', paddingTop: '4px', paddingBottom: '4px', borderTopWidth: '1px', borderTopStyle: 'solid', borderTopColor: tokens.colorNeutralStroke3, backgroundColor: tokens.colorBrandBackground2 },
  tlPill: {
    display: 'inline-flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
    minWidth: '40px', minHeight: '32px', paddingLeft: '6px', paddingRight: '6px',
    borderTopStyle: 'solid', borderRightStyle: 'solid', borderBottomStyle: 'solid', borderLeftStyle: 'solid',
    borderRadius: tokens.borderRadiusLarge, cursor: 'pointer', fontFamily: tokens.fontFamilyBase, color: tokens.colorNeutralForeground1,
    ':hover': { boxShadow: tokens.shadow4 },
    ':focus-visible': { outline: '2px solid ' + tokens.colorStrokeFocus2 },
  },
  tlCount: { fontSize: tokens.fontSizeBase300, fontWeight: tokens.fontWeightSemibold, lineHeight: tokens.lineHeightBase300 },
  tlAction: { fontSize: '10px', lineHeight: '12px', color: tokens.colorPaletteRedForeground1, fontWeight: tokens.fontWeightSemibold, whiteSpace: 'nowrap' },
  tlPanel: { display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalS, padding: tokens.spacingHorizontalM, backgroundColor: tokens.colorNeutralBackground3, borderRadius: tokens.borderRadiusMedium },
  tlPanelItem: { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: tokens.spacingHorizontalS },
  srOnly: { position: 'absolute', width: '1px', height: '1px', overflow: 'hidden', clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap' },
  legend: { display: 'flex', flexWrap: 'wrap', gap: tokens.spacingHorizontalM, color: tokens.colorNeutralForeground3, fontSize: tokens.fontSizeBase200 },
  table: { minWidth: '980px', tableLayout: 'fixed' },
  solTable: { minWidth: '760px', tableLayout: 'fixed' },
  scopeBar: { display: 'flex', flexWrap: 'wrap', alignItems: 'center', justifyContent: 'space-between', gap: tokens.spacingHorizontalM, padding: tokens.spacingHorizontalM, backgroundColor: tokens.colorNeutralBackground3, borderRadius: tokens.borderRadiusMedium },
  solBlock: { display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalXS, paddingTop: tokens.spacingVerticalS, borderTopWidth: '1px', borderTopStyle: 'solid', borderTopColor: tokens.colorNeutralStroke3 },
  cellText: { display: 'flex', flexDirection: 'column', gap: '2px', paddingTop: tokens.spacingVerticalXS, paddingBottom: tokens.spacingVerticalXS, whiteSpace: 'normal', overflowWrap: 'anywhere' },
  muted: { color: tokens.colorNeutralForeground3 },
  linkButton: {
    border: 'none',
    backgroundColor: 'transparent',
    padding: '0',
    textAlign: 'left',
    cursor: 'pointer',
    color: tokens.colorBrandForegroundLink,
    fontFamily: tokens.fontFamilyBase,
    fontSize: tokens.fontSizeBase300,
    fontWeight: tokens.fontWeightSemibold,
    ':hover': { textDecorationLine: 'underline' },
    ':focus-visible': { outline: '2px solid ' + tokens.colorStrokeFocus2 },
  },
  estateGrid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: tokens.spacingHorizontalM },
  estateCard: { display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalXS, padding: tokens.spacingHorizontalM, backgroundColor: tokens.colorNeutralBackground1, borderRadius: tokens.borderRadiusMedium, boxShadow: tokens.shadow4 },
  badges: { display: 'flex', flexWrap: 'wrap', gap: '4px', alignItems: 'center' },
  incidentList: { display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalXS },
  list: { margin: '0', paddingLeft: tokens.spacingHorizontalL, display: 'flex', flexDirection: 'column', gap: '2px' },
});

// ---------------------------------------------------------------------------------------------
// Sub-components.

function typeBarStyle(impactType: string | null): React.CSSProperties {
  const risk = tokens.colorPaletteRedForeground1;
  const opp = tokens.colorPaletteTealBorderActive;
  if (impactType === 'risk') return { borderLeft: '4px solid ' + risk };
  if (impactType === 'opportunity') return { borderLeft: '4px solid ' + opp };
  if (impactType === 'risk_and_opportunity') {
    return { borderLeft: '4px solid transparent', borderImage: 'linear-gradient(to bottom, ' + risk + ' 50%, ' + opp + ' 50%) 1' };
  }
  return { borderLeft: '4px solid ' + tokens.colorNeutralStroke1 };
}

function ItemChip(props: { item: Item; onOpen: (id: string) => void }) {
  const styles = useStyles();
  const { item, onOpen } = props;
  const typeLabel = item.impactType ? IMPACT_TYPE_LABELS[item.impactType] : 'Not rated';
  const label = item.ref + ': ' + item.title + '. ' + typeLabel + (item.actionRequired ? '. Action required' : '') + '. Opens the signal.';
  return (
    <button type="button" className={styles.itemButton} style={typeBarStyle(item.impactType)} title={item.title} aria-label={label} onClick={() => onOpen(item.id)}>
      <span>{cut(item.title, 60)}</span>
      <span className={styles.itemMeta}>
        <span>{item.ref}</span>
        <span>· {typeLabel}</span>
        {item.actionRequired && (
          <span className={styles.actionMark}>
            <WarningRegular aria-hidden="true" /> Action
          </span>
        )}
      </span>
    </button>
  );
}

function ItemList(props: { cellKey: string; items: Item[]; expanded: Record<string, boolean>; onToggle: (key: string) => void; onOpen: (id: string) => void }) {
  const { cellKey, items, expanded, onToggle, onOpen } = props;
  const open = !!expanded[cellKey];
  const shown = open ? items : items.slice(0, CELL_LIMIT);
  const hidden = items.length - shown.length;
  return (
    <>
      {shown.map((item) => (
        <ItemChip key={item.id} item={item} onOpen={onOpen} />
      ))}
      {items.length > CELL_LIMIT && (
        <Button size="small" appearance="subtle" onClick={() => onToggle(cellKey)}>
          {open ? 'Show fewer' : 'Show ' + hidden + ' more'}
        </Button>
      )}
    </>
  );
}

function ImpactBadge(props: { impact: string; prefix?: string }) {
  return (
    <Badge appearance="tint" color={impactBadgeColour(props.impact)}>
      {(props.prefix ? props.prefix + ': ' : '') + (IMPACT_LABELS[props.impact] || props.impact)}
    </Badge>
  );
}

type TimelinePoint = { id: string; title: string; ref: string; row: string; day: number; action: boolean; impact: string };
type TimelineCell = { row: string; bin: number };

const TIMELINE_PRESETS: Array<{ key: TimelinePreset; label: string }> = [
  { key: 'next90', label: 'Next 90 days' },
  { key: 'next12m', label: 'Next 12 months' },
  { key: 'past90', label: 'Past 90 days' },
];
const MONTH_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const MONTH_LONG = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

function binLabel(ms: number, g: TimelineGranularity): string {
  const d = new Date(ms);
  return g === 'month' ? MONTH_SHORT[d.getUTCMonth()] + ' ' + String(d.getUTCFullYear()).slice(2) : d.getUTCDate() + ' ' + MONTH_SHORT[d.getUTCMonth()];
}

function binLongLabel(ms: number, g: TimelineGranularity): string {
  const d = new Date(ms);
  return g === 'month' ? MONTH_LONG[d.getUTCMonth()] + ' ' + d.getUTCFullYear() : 'week of ' + d.getUTCDate() + ' ' + MONTH_LONG[d.getUTCMonth()] + ' ' + d.getUTCFullYear();
}

function rowPillStyle(row: string, action: boolean, selected: boolean): React.CSSProperties {
  const bg: Record<string, string> = {
    retiring: tokens.colorPaletteBerryBackground2,
    imminent: tokens.colorPaletteDarkOrangeBackground2,
    future: tokens.colorPaletteBlueBackground2,
    shipped: tokens.colorPaletteGreenBackground2,
  };
  const edge = action ? tokens.colorPaletteRedBorder2 : tokens.colorNeutralStroke1;
  return {
    backgroundColor: bg[row] || tokens.colorNeutralBackground3,
    borderTopColor: edge, borderRightColor: edge, borderBottomColor: edge, borderLeftColor: edge,
    borderTopWidth: action ? '2px' : '1px', borderRightWidth: action ? '2px' : '1px', borderBottomWidth: action ? '2px' : '1px', borderLeftWidth: action ? '2px' : '1px',
    outline: selected ? '2px solid ' + tokens.colorBrandStroke1 : 'none',
    outlineOffset: '2px',
  };
}

function TimelineGrid(props: {
  points: TimelinePoint[];
  bins: number[];
  granularity: TimelineGranularity;
  rows: Array<{ key: string; label: string }>;
  todayMs: number;
  selected: TimelineCell | null;
  onSelect: (cell: TimelineCell | null) => void;
}) {
  const styles = useStyles();
  const { points, bins, granularity, rows, todayMs, selected, onSelect } = props;
  const cells = React.useMemo(() => {
    const map: Record<string, TimelinePoint[]> = {};
    points.forEach((p) => {
      const k = p.row + '|' + getTimelineBin(p.day, granularity);
      (map[k] = map[k] || []).push(p);
    });
    return map;
  }, [points, granularity]);
  const todayBin = getTimelineBin(todayMs, granularity);
  return (
    <div className={styles.tlScroll}>
      <table className={styles.tlTable}>
        <caption className={styles.srOnly}>Items by timeline row and {granularity === 'month' ? 'month' : 'week'}. Select a count to list its items.</caption>
        <thead>
          <tr>
            <th scope="col" className={styles.tlRowHead}><span className={styles.srOnly}>Row</span></th>
            {bins.map((b) => (
              <th key={b} scope="col" className={b === todayBin ? styles.tlHeadNow : styles.tlHead}>
                {binLabel(b, granularity)}
                {b === todayBin && <span className={styles.tlNowTag}>{granularity === 'month' ? 'This month' : 'This week'}</span>}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.key}>
              <th scope="row" className={styles.tlRowHead}>{r.label}</th>
              {bins.map((b) => {
                const list = cells[r.key + '|' + b] || [];
                const action = list.filter((p) => p.action).length;
                const isSel = !!selected && selected.row === r.key && selected.bin === b;
                return (
                  <td key={b} className={b === todayBin ? styles.tlCellNow : styles.tlCell}>
                    {list.length > 0 && (
                      <button
                        type="button"
                        className={styles.tlPill}
                        style={rowPillStyle(r.key, action > 0, isSel)}
                        aria-pressed={isSel}
                        aria-label={r.label + ', ' + binLongLabel(b, granularity) + ': ' + list.length + (list.length === 1 ? ' item' : ' items') + (action ? ', ' + action + ' need action' : '')}
                        title={list.slice(0, 5).map((p) => p.ref + ': ' + p.title).join('\n') + (list.length > 5 ? '\n\u2026 and ' + (list.length - 5) + ' more' : '')}
                        onClick={() => onSelect(isSel ? null : { row: r.key, bin: b })}
                      >
                        <span className={styles.tlCount}>{list.length}</span>
                        {action > 0 && <span className={styles.tlAction}>{action + ' action'}</span>}
                      </button>
                    )}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------
// The page.

// The priority matrix as counts, in the style of the timeline grid (Simon, 2026-11-24): rows are impact, columns are
// time to land, and each pill is the number of items; a red outline and "action" mean some need action.
type MatrixCell = { row: string; col: string };
const MATRIX_PILL_BG: Record<string, string> = {
  high: tokens.colorPaletteRedBackground1,
  medium: tokens.colorPaletteMarigoldBackground2,
  low: tokens.colorPaletteLightGreenBackground2,
  none: tokens.colorNeutralBackground3,
  unrated: tokens.colorNeutralBackground2,
};
function MatrixGrid(props: { cells: Record<string, Item[]>; selected: MatrixCell | null; onSelect: (cell: MatrixCell | null) => void }) {
  const styles = useStyles();
  const { cells, selected, onSelect } = props;
  return (
    <div className={styles.tlScroll}>
      <table className={styles.tlTable}>
        <caption className={styles.srOnly}>Items by impact and time to land. Select a count to list its items.</caption>
        <thead>
          <tr>
            <th scope="col" className={styles.mxRowHead}><span className={styles.srOnly}>Impact</span></th>
            {BUCKETS.map((b) => <th key={b.key} scope="col" className={styles.tlHead}>{b.label}</th>)}
          </tr>
        </thead>
        <tbody>
          {MATRIX_ROWS.map((r) => (
            <tr key={r.key}>
              <th scope="row" className={styles.mxRowHead}>{r.label}</th>
              {BUCKETS.map((b) => {
                const list = cells[r.key + '|' + b.key] || [];
                const action = list.filter((i) => i.actionRequired).length;
                const isSel = !!selected && selected.row === r.key && selected.col === b.key;
                const edge = action > 0 ? tokens.colorPaletteRedBorder2 : tokens.colorNeutralStroke1;
                const width = action > 0 ? '2px' : '1px';
                return (
                  <td key={b.key} className={styles.tlCell}>
                    {list.length > 0 && (
                      <button
                        type="button"
                        className={styles.tlPill}
                        style={{
                          backgroundColor: MATRIX_PILL_BG[r.key] || tokens.colorNeutralBackground3,
                          borderTopColor: edge, borderRightColor: edge, borderBottomColor: edge, borderLeftColor: edge,
                          borderTopWidth: width, borderRightWidth: width, borderBottomWidth: width, borderLeftWidth: width,
                          outline: isSel ? '2px solid ' + tokens.colorBrandStroke1 : 'none', outlineOffset: '2px',
                        }}
                        aria-pressed={isSel}
                        aria-label={r.label + ' impact, ' + b.label + ': ' + list.length + (list.length === 1 ? ' item' : ' items') + (action ? ', ' + action + ' need action' : '')}
                        title={list.slice(0, 5).map((i) => i.ref + ': ' + i.title).join('\n') + (list.length > 5 ? '\n… and ' + (list.length - 5) + ' more' : '')}
                        onClick={() => onSelect(isSel ? null : { row: r.key, col: b.key })}
                      >
                        <span className={styles.tlCount}>{list.length}</span>
                        {action > 0 && <span className={styles.tlAction}>{action + ' action'}</span>}
                      </button>
                    )}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// A card whose body can be collapsed; the choice is remembered per viewer (browser storage, best effort).
// v3: the default changed (Simon, 2026-11-24), so earlier saved choices are ignored once.
const SECTIONS_KEY = 'changeRadar.radar.collapsedSections.v3';
const SECTION_IDS = ['matrix', 'timeline', 'solutions', 'patterns', 'imminent', 'estate'];
// By default the two overview visuals are open and every detailed section is collapsed, so a viewer sees where to go next.
const DEFAULT_COLLAPSED: Record<string, boolean> = { matrix: false, timeline: false, solutions: true, patterns: true, imminent: true, estate: true };
function readCollapsed(): Record<string, boolean> {
  try {
    const raw = window.localStorage.getItem(SECTIONS_KEY);
    const parsed = raw ? JSON.parse(raw) : null;
    return parsed && typeof parsed === 'object' ? { ...DEFAULT_COLLAPSED, ...(parsed as Record<string, boolean>) } : { ...DEFAULT_COLLAPSED };
  } catch (_e) {
    return { ...DEFAULT_COLLAPSED };
  }
}
function writeCollapsed(value: Record<string, boolean>) {
  try { window.localStorage.setItem(SECTIONS_KEY, JSON.stringify(value)); } catch (_e) { /* storage unavailable: the choice lasts this visit only */ }
}

function Section(props: { id: string; title: string; summary?: string; collapsed: boolean; onToggle: () => void; actions?: React.ReactNode; children: React.ReactNode }) {
  const styles = useStyles();
  const titleId = props.id + '-title';
  const bodyId = props.id + '-body';
  return (
    <Card className={styles.card} aria-labelledby={titleId}>
      <div className={styles.sectionHead}>
        <h2 className={styles.sectionH2} id={titleId}>
          <button type="button" className={styles.sectionToggle} aria-expanded={!props.collapsed} aria-controls={props.collapsed ? undefined : bodyId} onClick={props.onToggle}>
            {props.collapsed ? <ChevronRightRegular aria-hidden="true" /> : <ChevronDownRegular aria-hidden="true" />}
            <Subtitle2 as="span">{props.title}</Subtitle2>
          </button>
        </h2>
        {props.collapsed ? (props.summary ? <Caption1 className={styles.muted}>{props.summary}</Caption1> : null) : props.actions}
      </div>
      {!props.collapsed && <div id={bodyId} className={styles.sectionBody}>{props.children}</div>}
    </Card>
  );
}

function PageBody(props: GeneratedComponentProps) {
  const { dataApi } = props;
  const styles = useStyles();
  const dataReady = !!dataApi;
  const [reloadKey, setReloadKey] = React.useState(0);
  const [{ bundle, loading, error }, setData] = React.useState<{ bundle: RawBundle | null; loading: boolean; error: PageErrorView | null }>(() => {
    const cached = winAny[CACHE_KEY] as RawBundle | undefined;
    return { bundle: cached ?? null, loading: cached === undefined, error: null };
  });
  const [navError, setNavError] = React.useState<PageErrorView | null>(null);
  const [filters, setFilters] = React.useState<Filters>(EMPTY_FILTERS);
  const [expanded, setExpanded] = React.useState<Record<string, boolean>>({});
  const [timelineAsList, setTimelineAsList] = React.useState(false);
  const [estateBySolution, setEstateBySolution] = React.useState(false);
  const [patternsShowOlder, setPatternsShowOlder] = React.useState(false);
  const [collapsed, setCollapsed] = React.useState<Record<string, boolean>>(() => readCollapsed());
  const toggleSection = (id: string) => setCollapsed((prev) => { const next = { ...prev, [id]: !prev[id] }; writeCollapsed(next); return next; });
  const setAllSections = (value: boolean) => {
    const next: Record<string, boolean> = {};
    SECTION_IDS.forEach((id) => { next[id] = value; });
    writeCollapsed(next);
    setCollapsed(next);
  };
  const [timelinePreset, setTimelinePreset] = React.useState<TimelinePreset>('next90');
  const [timelineCell, setTimelineCell] = React.useState<TimelineCell | null>(null);
  const [matrixCell, setMatrixCell] = React.useState<MatrixCell | null>(null);
  const todayMs = React.useMemo(() => utcTodayMs(), [reloadKey]);

  function reload() {
    delete winAny[CACHE_KEY];
    delete winAny[INFLIGHT_KEY];
    setData({ bundle: null, loading: true, error: null });
    setReloadKey((k) => k + 1);
  }

  // Demo data switch (Simon 2026-11-24): writes crdr_config demo_data after a confirmation. Dataverse decides who may:
  // the Change Radar Admin role (and System Administrator) can write settings, the User role can't (install test,
  // Test-UserRole), so a refused write is explained rather than guessed from roles in the page.
  const [demoAsk, setDemoAsk] = React.useState<boolean | null>(null); // the state the person asked for, awaiting confirmation
  const [demoSaving, setDemoSaving] = React.useState(false);
  const [demoNote, setDemoNote] = React.useState<{ intent: 'success' | 'warning' | 'error'; text: string } | null>(null);
  async function saveDemo(on: boolean) {
    if (!bundle) return;
    const value = demoDataValue(on);
    setDemoSaving(true);
    setDemoNote(null);
    try {
      let id = bundle.demoConfigId;
      if (id) {
        // WritableTableRow lists every writable column as required; a partial row still checks names and types.
        const patch: Partial<WritableTableRow<crdr_config>> = { crdr_value: value };
        await dataApi.updateRow('crdr_config', id, patch as WritableTableRow<crdr_config>);
      } else {
        const row: Partial<WritableTableRow<crdr_config>> = { crdr_key: 'demo_data', crdr_value: value };
        const created = await dataApi.createRow('crdr_config', row as WritableTableRow<crdr_config>);
        id = String(created);
      }
      const next: RawBundle = { ...bundle, demoData: value, demoConfigId: id };
      winAny[CACHE_KEY] = next;
      setData({ bundle: next, loading: false, error: null });
      setDemoNote({ intent: 'success', text: on
        ? 'Demo data is on: this page now shows the demo organisation instead of your live estate. The nightly runs include it again.'
        : 'Demo data is off: this page shows your live estate, and the nightly runs leave the demo organisation out. Nothing was deleted.' });
    } catch (reason) {
      const detail = (() => { try { return JSON.stringify(reason) + String(reason); } catch (_e) { return String(reason); } })().toLowerCase();
      const refused = detail.indexOf('privilege') >= 0 || detail.indexOf('403') >= 0 || detail.indexOf('0x80040220') >= 0 || detail.indexOf('access') >= 0;
      setDemoNote(refused
        ? { intent: 'warning', text: 'Only Change Radar admins can switch demo data. Nothing was changed.' }
        : { intent: 'error', text: 'Demo data could not be switched. Nothing was changed; refresh and try again.' });
    } finally {
      setDemoSaving(false);
      setDemoAsk(null);
    }
  }

  React.useEffect(() => {
    if (!dataReady) return;
    const cached = winAny[CACHE_KEY] as RawBundle | undefined;
    if (cached !== undefined) {
      if (bundle !== cached) setData({ bundle: cached, loading: false, error: null });
      return;
    }
    let cancelled = false;
    let inflight = winAny[INFLIGHT_KEY] as Promise<RawBundle> | undefined;
    if (!inflight) {
      inflight = loadBundle(dataApi)
        .then((b) => {
          winAny[CACHE_KEY] = b;
          return b;
        })
        .finally(() => { if (winAny[INFLIGHT_KEY] === inflight) delete winAny[INFLIGHT_KEY]; });
      winAny[INFLIGHT_KEY] = inflight;
    }
    inflight
      .then((b) => { if (!cancelled) setData({ bundle: b, loading: false, error: null }); })
      .catch((failure: { operation?: string; reason?: unknown }) => {
        if (cancelled) return;
        const operation = failure && failure.operation ? failure.operation : 'loadRadar';
        const reason = failure && 'reason' in failure ? failure.reason : failure;
        setData({ bundle: null, loading: false, error: reportPageError(PAGE_NAME, operation, undefined, reason, 'read', reload) });
      });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dataReady, reloadKey]);

  // Signals with their live assessment and effective impact.
  const model = React.useMemo(() => {
    const empty = { items: [] as Item[], incidents: [] as Item[], all: [] as Item[], estateLive: [] as EstateEntry[], estateDemo: [] as EstateEntry[], tier: '', tierNote: '', products: [] as string[], solutionOptions: [] as SolutionOption[], assetGroups: {} as Record<string, string[]>, demoOn: true, showingDemo: false };
    if (!bundle) return empty;
    const assessmentsBySignal: Record<string, AssessmentView[]> = {};
    bundle.assessments.forEach((row) => {
      const sid = lookupId(row, '_crdr_signal_value', 'crdr_signal');
      if (!sid) return;
      (assessmentsBySignal[sid] = assessmentsBySignal[sid] || []).push(toAssessmentView(row));
    });
    const latestFor = (sid: string, source: number): AssessmentView | null => {
      const list = (assessmentsBySignal[sid] || []).filter((a) => a.source === source);
      if (list.length === 0) return null;
      return list.slice().sort((a, b) => b.assessedOn - a.assessedOn)[0];
    };
    // Solutions (ADR 0020): each exposed asset's group keys (source|unique name, or source|catch-all), then each
    // signal's keys from its open exposures. An environment has Dataverse detail when it has any solution row.
    const solutionInfo: Record<string, { source: number; uniquename: string; label: string; microsoft: boolean }> = {};
    const detailEnvs: string[] = [];
    // demo_data off (ADR 0022): synthetic exposures and solutions are left out of every section; nothing is deleted.
    const demoOn = isDemoDataOn(bundle.demoData);
    // One estate at a time (Simon 2026-11-24, 'Demo replaces live'): the demo organisation while demo data is on, the live
    // estate while it's off. Every rating, exposure, solution and asset below is that estate's, so the tiles, headline,
    // matrix, timeline and lists all follow the switch, and live and synthetic are never mixed (CLAUDE.md).
    const shownSource = estateShown(bundle.demoData, bundle.hasDemoData) === 'synthetic' ? ASSET_SOURCE_SYNTHETIC : ASSET_SOURCE_LIVE;
    const sourceOfRow = (row: unknown): number => { const v = Number((row as Record<string, unknown>).crdr_source); return isNaN(v) ? ASSET_SOURCE_LIVE : v; };
    // The live view keeps fixture (test) assets in their own table, as before; the demo view is the demo organisation only.
    const visible = (src: number): boolean => (shownSource === ASSET_SOURCE_SYNTHETIC ? src === ASSET_SOURCE_SYNTHETIC : src !== ASSET_SOURCE_SYNTHETIC);
    const exposures = bundle.exposures.filter((e) => visible(sourceOfRow(e)));
    (bundle.solutions || []).filter((row) => visible(sourceOfRow(row))).forEach((row) => {
      const r = row as unknown as Record<string, unknown>;
      const src = Number(r.crdr_source);
      const source = isNaN(src) ? ASSET_SOURCE_LIVE : src;
      const key = source + '|' + textOf(r.crdr_uniquename);
      solutionInfo[textOf(r.crdr_solutionid).toLowerCase()] = { source, uniquename: key, label: textOf(r.crdr_name) || textOf(r.crdr_uniquename), microsoft: isTrue(r.crdr_microsoft) };
      const env = textOf(r.crdr_environmentid).toLowerCase();
      if (env && detailEnvs.indexOf(env) < 0) detailEnvs.push(env);
    });
    const memberships: SolMember[] = [];
    (bundle.members || []).forEach((row) => {
      const aid = lookupId(row, '_crdr_asset_value', 'crdr_asset');
      const s = solutionInfo[lookupId(row, '_crdr_solution_value', 'crdr_solution') || ''];
      if (aid && s) memberships.push({ assetid: aid, uniquename: s.uniquename, displayname: s.label, microsoft: s.microsoft });
    });
    const exposedAssets = bundle.assets.map((a) => {
      const r = a as unknown as Record<string, unknown>;
      const src = Number(r.crdr_source);
      return { assetid: textOf(r.crdr_assetid).toLowerCase(), environmentid: textOf(r.crdr_environmentid).toLowerCase(), source: isNaN(src) ? ASSET_SOURCE_LIVE : src };
    }).filter((a) => visible(a.source));
    // Demo data is generated with its solutions, so a demo environment is always known: an asset there with none is
    // "not in a solution", never "not known".
    exposedAssets.forEach((a) => { if (a.source !== ASSET_SOURCE_LIVE && a.environmentid && detailEnvs.indexOf(a.environmentid) < 0) detailEnvs.push(a.environmentid); });
    const rawGroups = getSolutionGroups(exposedAssets, memberships, detailEnvs);
    const assetSource: Record<string, number> = {};
    exposedAssets.forEach((a) => { assetSource[a.assetid] = a.source; });
    const assetGroups: Record<string, string[]> = {};
    Object.keys(rawGroups).forEach((aid) => {
      assetGroups[aid] = rawGroups[aid].map((g) => (g === NOT_IN_SOLUTION || g === SOLUTION_NOT_KNOWN ? assetSource[aid] + '|' + g : g));
    });
    const signalSolutions: Record<string, Record<string, true>> = {};
    exposures.forEach((e) => {
      const sid = lookupId(e, '_crdr_signal_value', 'crdr_signal');
      const aid = lookupId(e, '_crdr_asset_value', 'crdr_asset');
      if (!sid || !aid || !assetGroups[aid]) return;
      const set = (signalSolutions[sid] = signalSolutions[sid] || {});
      assetGroups[aid].forEach((k) => { set[k] = true; });
    });
    const optionByKey: Record<string, SolutionOption> = {};
    Object.keys(solutionInfo).forEach((id) => {
      const s = solutionInfo[id];
      if (!optionByKey[s.uniquename]) optionByKey[s.uniquename] = { key: s.uniquename, source: s.source, uniquename: s.uniquename.slice(s.uniquename.indexOf('|') + 1), label: s.label, microsoft: s.microsoft, catchAll: false };
    });
    Object.keys(assetGroups).forEach((aid) => assetGroups[aid].forEach((k) => {
      const name = k.slice(k.indexOf('|') + 1);
      if (!optionByKey[k] && (name === NOT_IN_SOLUTION || name === SOLUTION_NOT_KNOWN)) {
        optionByKey[k] = { key: k, source: assetSource[aid], uniquename: name, label: name === NOT_IN_SOLUTION ? 'Not in a solution' : 'Solution not known', microsoft: false, catchAll: true };
      }
    }));
    const solutionOptions = Object.keys(optionByKey).map((k) => optionByKey[k]).sort((a, b) =>
      (a.source === ASSET_SOURCE_LIVE ? 0 : 1) - (b.source === ASSET_SOURCE_LIVE ? 0 : 1) || a.source - b.source
      || (a.catchAll ? 2 : a.microsoft ? 1 : 0) - (b.catchAll ? 2 : b.microsoft ? 1 : 0) || a.label.localeCompare(b.label));
    // Related signals per solution (Simon, 2026-11-24): shares a connector, capability, model, setting, harness or
    // authentication mode with any component of the solution, and doesn't already affect it.
    const assetFpRows = (bundle.assetFps || []).map((row) => {
      const r = row as unknown as Record<string, unknown>;
      return { assetid: lookupId(row, '_crdr_asset_value', 'crdr_asset') || '', facet: FACET_CODES[Number(r.crdr_facet)] || '', value: textOf(r.crdr_value) };
    });
    const signalFpRows = (bundle.signalFps || []).map((row) => {
      const r = row as unknown as Record<string, unknown>;
      return { signal: lookupId(row, '_crdr_signal_value', 'crdr_signal') || '', facet: FACET_CODES[Number(r.crdr_facet)] || '', value: textOf(r.crdr_value), status: 'accepted' };
    });
    const relatedBySignal: Record<string, Record<string, string[]>> = {};
    solutionOptions.filter((o) => !o.catchAll).forEach((o) => {
      const solAssets = memberships.filter((m) => m.uniquename === o.key).map((m) => m.assetid);
      if (solAssets.length === 0) return;
      const affects = Object.keys(signalSolutions).filter((sid) => signalSolutions[sid][o.key]);
      getRelatedSignals(solAssets, assetFpRows, signalFpRows, affects, RELATED_FACETS).forEach((rel) => {
        (relatedBySignal[rel.signal] = relatedBySignal[rel.signal] || {})[o.key] = rel.links;
      });
    });

    const all: Item[] = bundle.signals.map((row) => {
      const r = row as unknown as Record<string, unknown>;
      const id = textOf(r.crdr_signalid).toLowerCase();
      const live = latestFor(id, shownSource); // the shown estate's rating (live, or the demo organisation's)
      const productsText = textOf(r.crdr_products);
      const base = {
        id,
        ref: textOf(r.crdr_externalid),
        title: textOf(r.crdr_title),
        summary: stripHtml(textOf(r.crdr_summary)),
        products: splitProducts(productsText),
        productsText,
        source: codeOf(r.crdr_source, SOURCE_CODES) || 'manual',
        horizon: codeOf(r.crdr_horizon, HORIZON_CODES),
        keyDate: toDayString(r.crdr_keydate),
        dateLabel: textOf(r.crdr_datelabel),
        actionRequired: isTrue(r.crdr_actionrequired),
        genericImpact: codeOf(r.crdr_genericimpact, IMPACT_CODES),
        nature: codeOf(r.crdr_nature, NATURE_CODES),
        impactType: codeOf(r.crdr_impacttype, IMPACT_TYPE_CODES),
        risk: textOf(r.crdr_risk),
        opportunity: textOf(r.crdr_opportunity),
        audience: textOf(r.crdr_audience),
        theme: textOf(r.crdr_theme) || null,
        watched: isTrue(r.crdr_watched),
        confidence: textOf(r.crdr_ratingconfidence),
        url: textOf(r.crdr_url),
        live,
      };
      return { ...base, impact: getItemImpact(base, live), solutionKeys: Object.keys(signalSolutions[id] || {}), related: relatedBySignal[id] || {} };
    });
    const items = all.filter((i) => i.source !== 'graph_health');
    const incidents = all.filter((i) => i.source === 'graph_health' && i.horizon === 'now').sort(byDateThenTitle);
    const byId: Record<string, Item> = {};
    all.forEach((i) => { byId[i.id] = i; });

    // Estate: open exposures, grouped per signal (live) and per signal and source (demo); never mixed.
    const assetById: Record<string, AssetRow> = {};
    bundle.assets.forEach((a) => { assetById[textOf((a as unknown as Record<string, unknown>).crdr_assetid).toLowerCase()] = a; });
    const groups: Record<string, { item: Item; source: number; assets: Record<string, true> }> = {};
    exposures.forEach((e) => {
      const sid = lookupId(e, '_crdr_signal_value', 'crdr_signal');
      const item = sid ? byId[sid] : undefined;
      if (!item || item.source === 'graph_health') return;
      const src = Number((e as unknown as Record<string, unknown>).crdr_source);
      const source = isNaN(src) ? ASSET_SOURCE_LIVE : src;
      const key = item.id + '|' + source;
      const g = (groups[key] = groups[key] || { item, source, assets: {} });
      const aid = lookupId(e, '_crdr_asset_value', 'crdr_asset');
      g.assets[aid || 'unknown:' + textOf((e as unknown as Record<string, unknown>).crdr_exposureid)] = true;
    });
    const toEntry = (key: string): EstateEntry => {
      const g = groups[key];
      const ids = Object.keys(g.assets);
      const types = ids.map((aid) => {
        const a = assetById[aid] as unknown as Record<string, unknown> | undefined;
        return a && textOf(a.crdr_resourcetype) ? textOf(a.crdr_resourcetype) : 'Unknown';
      });
      const envs = ids.map((aid) => {
        const a = assetById[aid] as unknown as Record<string, unknown> | undefined;
        const v = a ? Number(a.crdr_environmenttype) : NaN;
        return ENV_TYPE_LABELS[v] || 'Unknown';
      });
      const live = g.source === ASSET_SOURCE_LIVE;
      const assessment = live ? g.item.live : latestFor(g.item.id, g.source);
      const impact = live ? g.item.impact.impact : getItemImpact(g.item, assessment).impact;
      return {
        key,
        item: g.item,
        sourceLabel: ASSET_SOURCE_LABELS[g.source] || 'Unknown source',
        assetCount: ids.length,
        byType: countBy(types),
        byEnv: countBy(envs),
        assessment,
        impact,
        assetIds: ids,
        source: g.source,
      };
    };
    const byImpactThenDate = (a: EstateEntry, b: EstateEntry) => (IMPACT_RANK[b.impact] || 0) - (IMPACT_RANK[a.impact] || 0) || byDateThenTitle(a.item, b.item);
    const keys = Object.keys(groups);
    const estateLive = keys.filter((k) => groups[k].source === ASSET_SOURCE_LIVE).map(toEntry).sort(byImpactThenDate);
    const estateDemo = keys.filter((k) => groups[k].source !== ASSET_SOURCE_LIVE).map(toEntry).sort(byImpactThenDate);

    // Access tier: the latest run of each collector; the most limited first.
    const latestRun: Record<string, RunRow> = {};
    bundle.runs.forEach((run) => {
      const r = run as unknown as Record<string, unknown>;
      const c = textOf(r.crdr_collector) || 'unnamed collector';
      const prev = latestRun[c] as unknown as Record<string, unknown> | undefined;
      if (!prev || timeOf(r.crdr_startedon) > timeOf(prev.crdr_startedon)) latestRun[c] = run;
    });
    const tiers = Object.keys(latestRun).map((c) => ({ collector: c, tier: Number((latestRun[c] as unknown as Record<string, unknown>).crdr_accesstier) }));
    let tier = 'Access tier: unknown (no collection runs yet)';
    let tierNote = 'No collection has run yet, so coverage is unknown.';
    if (tiers.length > 0) {
      const distinct = Array.from(new Set(tiers.map((t) => t.tier)));
      if (distinct.length === 1) {
        tier = 'Access tier: ' + (TIER_LABELS[distinct[0]] || 'unknown');
        tierNote = TIER_MEANING[distinct[0]] || 'Coverage is unknown.';
      } else {
        tierNote = 'Coverage differs by collector, so some sources or parts of the estate are missing; the most limited is listed first.';
        tier = 'Access tiers: ' + tiers
          .slice()
          .sort((a, b) => (TIER_LIMIT_ORDER[a.tier] ?? 9) - (TIER_LIMIT_ORDER[b.tier] ?? 9) || a.collector.localeCompare(b.collector))
          .map((t) => t.collector + ' ' + (TIER_LABELS[t.tier] || 'unknown'))
          .join('; ');
      }
    }
    const products = Array.from(new Set(items.reduce((acc: string[], i) => acc.concat(i.products), []))).sort((a, b) => a.localeCompare(b));
    return { items, incidents, all, estateLive, estateDemo, tier, tierNote, products, solutionOptions, assetGroups, demoOn, showingDemo: shownSource === ASSET_SOURCE_SYNTHETIC };
  }, [bundle]);

  const summary = React.useMemo(() => getRadarSummary(model.all, todayMs), [model, todayMs]);

  const filtered = React.useMemo(
    () => model.items.filter((i) => passesTile(i, filters.tile, todayMs) && passesBar(i, filters)).sort(byDateThenTitle),
    [model, filters, todayMs],
  );
  const filteredIds = React.useMemo(() => {
    const ids: Record<string, true> = {};
    filtered.forEach((i) => { ids[i.id] = true; });
    return ids;
  }, [filtered]);

  const matrix = React.useMemo(() => {
    const cells: Record<string, Item[]> = {};
    filtered.forEach((i) => {
      const key = impactRow(i.impact.impact) + '|' + getTimeBucket(i.keyDate, todayMs);
      (cells[key] = cells[key] || []).push(i);
    });
    return cells;
  }, [filtered, todayMs]);
  const matrixUndated = (matrix['high|nodate'] || []).length + (matrix['medium|nodate'] || []).length + (matrix['low|nodate'] || []).length + (matrix['none|nodate'] || []).length + (matrix['unrated|nodate'] || []).length;
  const matrixSelection = React.useMemo(() => {
    if (!matrixCell) return null;
    const list = (matrix[matrixCell.row + '|' + matrixCell.col] || []).slice()
      .sort((a, b) => (a.actionRequired === b.actionRequired ? byDateThenTitle(a, b) : a.actionRequired ? -1 : 1));
    if (list.length === 0) return null;
    const row = MATRIX_ROWS.filter((r) => r.key === matrixCell.row)[0];
    const col = BUCKETS.filter((b) => b.key === matrixCell.col)[0];
    return { label: (row ? row.label : matrixCell.row) + ' impact, ' + (col ? col.label : matrixCell.col), list };
  }, [matrixCell, matrix]);

  const patternItems = React.useMemo(() => filtered.filter((i) => inPatternWindow(i.keyDate, todayMs, patternsShowOlder)), [filtered, todayMs, patternsShowOlder]);
  const patterns = React.useMemo(() => {
    const groups: Record<string, Item[]> = {};
    patternItems.forEach((i) => {
      const k = themeKey(i);
      (groups[k] = groups[k] || []).push(i);
    });
    return THEMES.concat([NOT_THEMED]).map((t) => ({ key: t, label: t === NOT_THEMED ? 'Not yet themed' : t, items: groups[t] || [] }));
  }, [patternItems]);

  const timeline = React.useMemo(() => {
    const w = getTimelineWindow(timelinePreset, todayMs);
    const bins = getTimelineBins(w);
    const shipped90From = todayMs - 90 * DAY_MS;
    let earlier = 0;
    let later = 0;
    let undated = 0;
    let shipped90 = 0;
    const points: TimelinePoint[] = [];
    filtered.forEach((i) => {
      const row = getTimelineRow(i, todayMs);
      if (row === 'none') return;
      const day = toUtcDayMs(i.keyDate);
      if (day === null) { undated += 1; return; }
      if (row === 'shipped' && day >= shipped90From && day <= todayMs) shipped90 += 1;
      if (row === 'shipped' && timelinePreset !== 'past90') return;
      if (day < w.from) { earlier += 1; return; }
      if (day > w.to) { later += 1; return; }
      points.push({ id: i.id, title: i.title, ref: i.ref, row, day, action: i.actionRequired, impact: i.impact.impact });
    });
    const rows = (timelinePreset === 'past90' ? ['shipped', 'retiring', 'imminent'] : ['retiring', 'imminent', 'future'])
      .map((k) => TIMELINE_ROWS.filter((r) => r.key === k)[0]);
    return { points, bins, granularity: w.granularity, rows, earlier, later, undated, shipped90 };
  }, [filtered, todayMs, timelinePreset]);

  const timelineSelection = React.useMemo(() => {
    if (!timelineCell) return null;
    const list = timeline.points
      .filter((p) => p.row === timelineCell.row && getTimelineBin(p.day, timeline.granularity) === timelineCell.bin)
      .sort((a, b) => (a.action === b.action ? a.day - b.day || compareTitles(a.title, b.title) : a.action ? -1 : 1));
    if (list.length === 0) return null;
    const row = TIMELINE_ROWS.filter((r) => r.key === timelineCell.row)[0];
    return { label: (row ? row.label : timelineCell.row) + ', ' + binLongLabel(timelineCell.bin, timeline.granularity), list };
  }, [timelineCell, timeline]);

  const imminent = React.useMemo(() => filtered.filter((i) => i.horizon === 'now' || i.horizon === 'imminent'), [filtered]);
  const estateLive = React.useMemo(() => model.estateLive.filter((e) => filteredIds[e.item.id]), [model, filteredIds]);
  const estateDemo = React.useMemo(() => model.estateDemo.filter((e) => filteredIds[e.item.id]), [model, filteredIds]);
  // By solution (ADR 0020): per-solution summary from the filtered estate, live and demo kept apart.
  const solutionView = React.useMemo(() => {
    const membership: SolMember[] = [];
    Object.keys(model.assetGroups).forEach((aid) => model.assetGroups[aid].forEach((k) => membership.push({ assetid: aid, uniquename: k })));
    const build = (live: boolean) => {
      const exposures: SolExposure[] = [];
      (live ? estateLive : estateDemo).forEach((e) => e.assetIds.forEach((aid) => {
        exposures.push({ assetid: aid, signal: e.item.id + '|' + e.source, impact: e.impact, keyDate: e.item.keyDate, actionRequired: e.item.actionRequired });
      }));
      const opts = model.solutionOptions.filter((o) => (o.source === ASSET_SOURCE_LIVE) === live);
      return getSolutionSummary(opts.map((o) => ({ uniquename: o.key, displayname: o.label, microsoft: o.microsoft })), membership, exposures, todayMs);
    };
    return { live: build(true), demo: build(false) };
  }, [model, estateLive, estateDemo, todayMs]);
  const solutionLabel = (key: string) => { const o = model.solutionOptions.filter((x) => x.key === key)[0]; return o ? o.label : key; };
  const itemById = React.useMemo(() => {
    const m: Record<string, Item> = {};
    model.all.forEach((i) => { m[i.id] = i; });
    return m;
  }, [model]);
  // How an item relates to the chosen solution: it affects it (an exposure) or is related (shares a facet).
  const relationOf = (item: Item | undefined): React.ReactNode => {
    if (!filters.solution || !item) return null;
    if (item.solutionKeys.indexOf(filters.solution) >= 0) return <Badge appearance="tint" color="danger">Affects this solution</Badge>;
    const links = item.related[filters.solution];
    return links ? <Badge appearance="outline" color="informative">{'Related: ' + links.join(', ')}</Badge> : null;
  };
  const solutionScope = React.useMemo(() => {
    if (!filters.solution) return null;
    const affects = model.items.filter((i) => i.solutionKeys.indexOf(filters.solution) >= 0).length;
    const related = model.items.filter((i) => i.solutionKeys.indexOf(filters.solution) < 0 && !!i.related[filters.solution]).length;
    return { affects, related };
  }, [model, filters.solution]);
  const relatedCountBySolution = React.useMemo(() => {
    const counts: Record<string, number> = {};
    filtered.forEach((i) => Object.keys(i.related).forEach((k) => { counts[k] = (counts[k] || 0) + 1; }));
    return counts;
  }, [filtered]);
  const renderSolutionTable = (rows: SolSummaryRow[], caption: string) => {
    const rel = (r: SolSummaryRow) => relatedCountBySolution[r.uniquename] || 0;
    const busy = rows.filter((r) => r.items > 0 || rel(r) > 0);
    const quiet = rows.filter((r) => r.items === 0 && rel(r) === 0);
    return (
      <>
        {busy.length === 0 ? <Text>No solution has an open exposure or a related signal that matches the filters.</Text> : (
          <div className={styles.scrollX}>
            <Table className={styles.solTable} size="small" aria-label={caption}>
              <TableHeader>
                <TableRow>
                  <TableHeaderCell style={{ width: '28%' }}>Solution</TableHeaderCell>
                  <TableHeaderCell style={{ width: '12%' }}>Exposed assets</TableHeaderCell>
                  <TableHeaderCell style={{ width: '9%' }}>Affects</TableHeaderCell>
                  <TableHeaderCell style={{ width: '9%' }}>Related</TableHeaderCell>
                  <TableHeaderCell style={{ width: '15%' }}>Highest impact</TableHeaderCell>
                  <TableHeaderCell style={{ width: '15%' }}>Next deadline</TableHeaderCell>
                  <TableHeaderCell style={{ width: '13%' }}>Need action</TableHeaderCell>
                </TableRow>
              </TableHeader>
              <TableBody>
                {busy.map((r) => (
                  <TableRow key={r.uniquename}>
                    <TableCell>
                      <button type="button" className={styles.linkButton} aria-pressed={filters.solution === r.uniquename}
                        onClick={() => setFilter('solution', filters.solution === r.uniquename ? '' : r.uniquename)}
                        aria-label={r.displayname + ': ' + (filters.solution === r.uniquename ? 'clear the solution filter' : 'show only this solution in every section')}>
                        {r.displayname}
                      </button>
                      {r.microsoft && <Caption1 className={styles.muted}>{' · Microsoft'}</Caption1>}
                    </TableCell>
                    <TableCell>{r.assets}</TableCell>
                    <TableCell>{r.items}</TableCell>
                    <TableCell>{rel(r)}</TableCell>
                    <TableCell>{r.highest ? <ImpactBadge impact={r.highest} /> : <Caption1 className={styles.muted}>Not rated</Caption1>}</TableCell>
                    <TableCell>{r.nextDeadline ? formatDisplayDate(r.nextDeadline) : '—'}</TableCell>
                    <TableCell>{r.action > 0 ? <span className={styles.actionMark}>{r.action}</span> : 0}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
        {quiet.length > 0 && <Caption1 className={styles.muted}>{'No open exposures or related signals: ' + quiet.map((r) => r.displayname).join(', ') + '.'}</Caption1>}
      </>
    );
  };
  const renderEstateBySolution = (entries: EstateEntry[], live: boolean) => {
    const opts = model.solutionOptions.filter((o) => (o.source === ASSET_SOURCE_LIVE) === live);
    const blocks = opts.map((o) => {
      const rows = entries
        .map((e) => ({ e, inSol: e.assetIds.filter((aid) => (model.assetGroups[aid] || []).indexOf(o.key) >= 0).length }))
        .filter((x) => x.inSol > 0);
      return { o, rows };
    }).filter((b) => b.rows.length > 0);
    if (blocks.length === 0) return <Text>No exposures match the filters.</Text>;
    return blocks.map((b) => (
      <section key={b.o.key} className={styles.solBlock} aria-label={b.o.label + ': ' + b.rows.length + ' signals'}>
        <Text weight="semibold">{b.o.label + (b.o.microsoft ? ' (Microsoft)' : '') + ' · ' + b.rows.length + (b.rows.length === 1 ? ' signal' : ' signals')}</Text>
        <ul className={styles.list}>
          {b.rows.map(({ e, inSol }) => (
            <li key={e.key} className={styles.tlPanelItem}>
              <button type="button" className={styles.linkButton} onClick={() => open(e.item.id)}>{e.item.title}</button>
              <ImpactBadge impact={e.impact} prefix={live ? 'Impact' : 'Demo estate'} />
              <Caption1 className={styles.muted}>{e.item.ref + ' · ' + formatDisplayDate(e.item.keyDate) + ' · ' + inSol + ' of ' + e.assetCount + (e.assetCount === 1 ? ' exposed asset' : ' exposed assets') + ' in this solution'}</Caption1>
              {e.item.actionRequired && <span className={styles.actionMark}>Action required</span>}
            </li>
          ))}
        </ul>
      </section>
    ));
  };

  const filtersActive = filters.tile !== '' || filters.horizon !== '' || filters.source !== '' || filters.product !== '' || filters.theme !== '' || filters.impactType !== '' || filters.watched !== '' || filters.solution !== '';
  const open = (id: string) => openSignalForm(id, setNavError);
  const toggleCell = (key: string) => setExpanded((prev) => ({ ...prev, [key]: !prev[key] }));
  const setFilter = (name: keyof Filters, value: string) => setFilters((prev) => ({ ...prev, [name]: value }));
  const toggleTile = (tile: string) => setFilters((prev) => ({ ...prev, tile: prev.tile === tile ? '' : tile }));

  const tiles: Array<{ key: string; label: string; count: number; hint: string }> = [
    { key: 'now', label: 'Now', count: summary.incidentsActive, hint: 'Active service incidents' },
    { key: 'action', label: 'Action required', count: summary.actionRequired, hint: 'Items that need someone to act' },
    { key: 'high', label: 'High impact', count: summary.highImpact, hint: 'Rated high or critical' },
    { key: 'retiring', label: 'Retiring', count: summary.retiring, hint: 'Deprecations and breaking changes' },
    { key: 'future', label: 'Future', count: summary.futureRoadmap, hint: 'Roadmap items further out' },
  ];
  const resultText = filters.tile === 'now'
    ? summary.incidentsActive + ' active incidents shown'
    : filtered.length + ' of ' + model.items.length + ' items match the filters';

  const renderEstate = (entries: EstateEntry[], demo: boolean) => (
    <div className={styles.estateGrid}>
      {entries.map((e) => (
        <div key={e.key} className={styles.estateCard}>
          <button type="button" className={styles.linkButton} onClick={() => open(e.item.id)} aria-label={e.item.ref + ': ' + e.item.title + '. Opens the signal.'}>
            {e.item.title}
          </button>
          <div className={styles.badges}>
            <ImpactBadge impact={e.impact} prefix={demo ? 'Demo estate' : 'Impact'} />
            {demo && <Badge appearance="outline" color="warning">{'Demo data: ' + e.sourceLabel}</Badge>}
            <Caption1 className={styles.muted}>{e.item.ref + ' · ' + formatDisplayDate(e.item.keyDate)}</Caption1>
          </div>
          <Text size={200}>
            {e.assetCount + (e.assetCount === 1 ? ' asset: ' : ' assets: ') + e.byType.map((t) => t.label + ' ' + t.count).join(', ')}
          </Text>
          <Text size={200} className={styles.muted}>{'Environments: ' + e.byEnv.map((t) => t.label + ' ' + t.count).join(', ')}</Text>
          {e.assessment && (e.assessment.rationale || e.assessment.action) ? (
            <>
              <Caption1 className={styles.muted}>LLM assessment (in-tenant)</Caption1>
              {e.assessment.rationale && <Text size={200}>{e.assessment.rationale}</Text>}
              {e.assessment.action && <Text size={200}><strong>Recommended action: </strong>{e.assessment.action}</Text>}
            </>
          ) : (
            <Caption1 className={styles.muted}>No estate assessment yet.</Caption1>
          )}
        </div>
      ))}
    </div>
  );

  return (
    <div className={styles.root}>
      <header className={styles.header}>
        <Title2 as="h1" className={styles.headerTitle}>Change Radar</Title2>
        <Badge appearance="tint" color="brand">{model.tier || 'Access tier: loading'}</Badge>
        {bundle && bundle.hasDemoData && (
          <Switch
            label={model.demoOn ? 'Demo data on' : 'Demo data off'}
            checked={model.demoOn}
            disabled={demoSaving || loading}
            onChange={(_e, d) => setDemoAsk(!!d.checked)}
            aria-describedby="demo-data-hint"
          />
        )}
        <span id="demo-data-hint" hidden>On: this page shows the synthetic demo organisation instead of your live estate, and the nightly runs include it. Off: your live estate. Change Radar admins only.</span>
        <Button appearance="subtle" icon={<ArrowClockwiseRegular />} onClick={reload} disabled={loading}>Refresh</Button>
      </header>
      <Dialog open={demoAsk !== null} onOpenChange={(_e, d) => { if (!d.open && !demoSaving) setDemoAsk(null); }}>
        <DialogSurface>
          <DialogBody>
            <DialogTitle>{demoAsk ? 'Turn demo data on?' : 'Turn demo data off?'}</DialogTitle>
            <DialogContent>
              {demoAsk ? (
                <Text>This page shows the synthetic demo organisation instead of your live estate: every count, chart and list becomes the demo estate's. The next nightly runs also match and rate it, which uses AI Builder or Copilot Credits. For evaluation, training and screenshots only, never production.</Text>
              ) : (
                <Text>This page shows your live estate again, and the nightly runs leave the demo organisation out of matching and rating, so no credits are spent on it. Nothing is deleted: you can turn it back on, or remove it with setup/Remove-DemoData.ps1.</Text>
              )}
            </DialogContent>
            <DialogActions>
              <Button appearance="secondary" onClick={() => setDemoAsk(null)} disabled={demoSaving}>Cancel</Button>
              <Button appearance="primary" onClick={() => { if (demoAsk !== null) void saveDemo(demoAsk); }} disabled={demoSaving}>
                {demoSaving ? 'Saving…' : demoAsk ? 'Turn on' : 'Turn off'}
              </Button>
            </DialogActions>
          </DialogBody>
        </DialogSurface>
      </Dialog>
      {demoNote && (
        <MessageBar intent={demoNote.intent} aria-live="polite">
          <MessageBarBody>{demoNote.text}</MessageBarBody>
          <MessageBarActions containerAction={<Button appearance="transparent" icon={<DismissRegular />} aria-label="Dismiss" onClick={() => setDemoNote(null)} />} />
        </MessageBar>
      )}
      <Caption1 className={styles.note}>
        {(model.tierNote ? model.tierNote + ' ' : '') + 'Ratings are LLM assessments (in-tenant), not fact. Dates are UTC days. Today: ' + formatDisplayDate(formatUtcDay(todayMs)) + '.'}
      </Caption1>
      <PageErrorBar error={error} />
      <PageErrorBar error={navError} />
      {bundle && model.showingDemo && (
        <MessageBar intent="warning">
          <MessageBarBody>
            <strong>Showing the demo organisation.</strong> Every count, chart and list on this page is the synthetic demo estate's (its exposures, ratings and solutions), not your tenant's. Switch demo data off to see your live estate.
          </MessageBarBody>
        </MessageBar>
      )}
      {loading && <Spinner label="Loading the radar" />}
      {!loading && bundle && (
        <>
          <p className={styles.headline}>{summary.headline}</p>

          <nav aria-label="Radar tiles" className={styles.tiles}>
            {tiles.map((t) => (
              <ToggleButton
                key={t.key}
                className={styles.tile}
                checked={filters.tile === t.key}
                aria-pressed={filters.tile === t.key}
                aria-label={t.label + ': ' + t.count + '. ' + t.hint + '. ' + (filters.tile === t.key ? 'Filter on; press to clear.' : 'Press to filter the sections below.')}
                onClick={() => toggleTile(t.key)}
              >
                <span className={styles.tileCount}>{t.count}</span>
                <span>{t.label}</span>
                <Caption1>{t.hint}</Caption1>
              </ToggleButton>
            ))}
          </nav>

          {filters.tile === 'now' && (
            <Card className={styles.card} aria-labelledby="incidents-title">
              <Subtitle2 as="h2" id="incidents-title">Active incidents</Subtitle2>
              {model.incidents.length === 0 ? (
                <Text>No active incidents.</Text>
              ) : (
                <div className={styles.incidentList}>
                  {model.incidents.map((i) => (
                    <div key={i.id}>
                      <button type="button" className={styles.linkButton} onClick={() => open(i.id)}>{i.title}</button>
                      <Caption1 className={styles.muted}>{' · ' + (i.productsText || 'No product') + ' · ' + i.dateLabel + ' · ' + i.ref}</Caption1>
                    </div>
                  ))}
                </div>
              )}
            </Card>
          )}

          <section aria-label="Filters" className={styles.filters}>
            <div className={styles.filter}>
              <Label htmlFor="flt-horizon">Horizon</Label>
              <Select id="flt-horizon" value={filters.horizon} onChange={(_, d) => setFilter('horizon', d.value)}>
                <option value="">All horizons</option>
                {HORIZON_OPTIONS.map((h) => <option key={h.value} value={h.value}>{h.label}</option>)}
              </Select>
            </div>
            <div className={styles.filter}>
              <Label htmlFor="flt-source">Source</Label>
              <Select id="flt-source" value={filters.source} onChange={(_, d) => setFilter('source', d.value)}>
                <option value="">All sources</option>
                {SOURCE_ORDER.filter((s) => s !== 'graph_health' && model.items.some((i) => i.source === s)).map((s) => <option key={s} value={s}>{SOURCE_LABELS[s]}</option>)}
              </Select>
            </div>
            <div className={styles.filter}>
              <Label htmlFor="flt-product">Product</Label>
              <Select id="flt-product" value={filters.product} onChange={(_, d) => setFilter('product', d.value)}>
                <option value="">All products</option>
                {model.products.map((p) => <option key={p} value={p}>{p}</option>)}
              </Select>
            </div>
            <div className={styles.filter}>
              <Label htmlFor="flt-theme">Theme</Label>
              <Select id="flt-theme" value={filters.theme} onChange={(_, d) => setFilter('theme', d.value)}>
                <option value="">All themes</option>
                {THEMES.map((t) => <option key={t} value={t}>{t}</option>)}
                <option value={NOT_THEMED}>Not yet themed</option>
              </Select>
            </div>
            <div className={styles.filter}>
              <Label htmlFor="flt-type">Impact type</Label>
              <Select id="flt-type" value={filters.impactType} onChange={(_, d) => setFilter('impactType', d.value)}>
                <option value="">All types</option>
                <option value="risk">Risk</option>
                <option value="opportunity">Opportunity</option>
                <option value="risk_and_opportunity">Risk and opportunity</option>
                <option value={NOT_RATED}>Not rated</option>
              </Select>
            </div>
            <div className={styles.filter}>
              <Label htmlFor="flt-watched">Watch list</Label>
              <Select id="flt-watched" value={filters.watched} onChange={(_, d) => setFilter('watched', d.value)}>
                <option value="">All items</option>
                <option value="watched">{'Watched only (' + model.items.filter((i) => i.watched).length + ')'}</option>
              </Select>
            </div>
            <div className={styles.filter}>
              <Label htmlFor="flt-solution">Solution</Label>
              <Select id="flt-solution" value={filters.solution} onChange={(_, d) => setFilter('solution', d.value)}>
                <option value="">All solutions</option>
                {!model.showingDemo && (
                  <optgroup label="Your estate">
                    {model.solutionOptions.filter((o) => o.source === ASSET_SOURCE_LIVE).map((o) => <option key={o.key} value={o.key}>{o.label + (o.microsoft ? ' (Microsoft)' : '')}</option>)}
                  </optgroup>
                )}
                {model.solutionOptions.some((o) => o.source !== ASSET_SOURCE_LIVE) && (
                  <optgroup label={model.showingDemo ? 'Demo organisation' : 'Test fixtures'}>
                    {model.solutionOptions.filter((o) => o.source !== ASSET_SOURCE_LIVE).map((o) => <option key={o.key} value={o.key}>{o.label}</option>)}
                  </optgroup>
                )}
              </Select>
            </div>
            <Button appearance="secondary" disabled={!filtersActive} onClick={() => setFilters(EMPTY_FILTERS)}>Clear filters</Button>
            <Text role="status" aria-live="polite">{resultText}</Text>
          </section>
          {filters.solution && solutionScope && (
            <div className={styles.scopeBar} role="group" aria-label="Solution scope">
              <Text>
                <strong>{solutionLabel(filters.solution)}</strong>
                {': ' + solutionScope.affects + (solutionScope.affects === 1 ? ' signal affects it' : ' signals affect it') + ' (an exposure on one of its components)'}
                {filters.solution.indexOf('(') < 0 ? ', ' + solutionScope.related + ' related (they share a connector, capability, model, setting, harness or authentication mode with a component).' : '.'}
              </Text>
              {filters.solution.indexOf('(') < 0 && (
                <Switch label="Include related signals" checked={filters.solutionScope !== 'affects'} onChange={(_, d) => setFilter('solutionScope', d.checked ? '' : 'affects')} />
              )}
            </div>
          )}

          <div className={styles.sectionTools} role="group" aria-label="Show or hide sections">
            <Button size="small" appearance="subtle" icon={<ChevronDownRegular />} onClick={() => setAllSections(false)}>Expand all</Button>
            <Button size="small" appearance="subtle" icon={<ChevronRightRegular />} onClick={() => setAllSections(true)}>Collapse all</Button>
          </div>

          <Section
            id="matrix"
            title="Priority matrix: impact against time to land"
            collapsed={!!collapsed.matrix}
            onToggle={() => toggleSection('matrix')}
            summary={filtered.length + ' items'}
          >
            <div className={styles.legend}>
              <span>Each count is the items at that impact landing in that window; a red outline and "action" mean some need action. Select a count to list its items.</span>
              {matrixUndated > 0 && <span>{matrixUndated + ' without a date are not shown.'}</span>}
            </div>
            <MatrixGrid cells={matrix} selected={matrixSelection ? matrixCell : null} onSelect={setMatrixCell} />
            {matrixSelection && (
              <section className={styles.tlPanel} aria-label={'Items: ' + matrixSelection.label}>
                <div className={styles.sectionHead}>
                  <Text weight="semibold" className={styles.sectionTitle}>{matrixSelection.label + ' (' + matrixSelection.list.length + ')'}</Text>
                  <Button size="small" appearance="subtle" icon={<DismissRegular />} onClick={() => setMatrixCell(null)}>Close</Button>
                </div>
                <ul className={styles.list}>
                  {matrixSelection.list.map((i) => (
                    <li key={i.id} className={styles.tlPanelItem}>
                      <button type="button" className={styles.linkButton} onClick={() => open(i.id)}>{i.title}</button>
                      <Caption1 className={styles.muted}>{i.ref + ' · ' + formatDisplayDate(i.keyDate)}</Caption1>
                      <ImpactBadge impact={i.impact.impact} />
                      {i.actionRequired && <span className={styles.actionMark}>Action required</span>}
                      {relationOf(i)}
                    </li>
                  ))}
                </ul>
              </section>
            )}
          </Section>


          <Section
            id="timeline"
            title="What lands when"
            collapsed={!!collapsed.timeline}
            onToggle={() => toggleSection('timeline')}
            summary={(TIMELINE_PRESETS.find((p) => p.key === timelinePreset) || TIMELINE_PRESETS[0]).label + ': ' + timeline.points.length + ' items'}
            actions={
              <ToggleButton icon={<ListRegular />} checked={timelineAsList} aria-pressed={timelineAsList} onClick={() => setTimelineAsList(!timelineAsList)}>
                Show as a list
              </ToggleButton>
            }
          >
            <div className={styles.tlControls} role="group" aria-label="Timeline range">
              {TIMELINE_PRESETS.map((p) => (
                <ToggleButton key={p.key} size="small" checked={timelinePreset === p.key} aria-pressed={timelinePreset === p.key} onClick={() => { setTimelinePreset(p.key); setTimelineCell(null); }}>
                  {p.label}
                </ToggleButton>
              ))}
            </div>
            <div className={styles.legend}>
              <span>{'Each count is the items landing that ' + (timeline.granularity === 'month' ? 'month' : 'week') + '; a red outline and "action" mean some need action. Select a count to list its items.'}</span>
              {timelinePreset !== 'past90' && (
                <span>
                  {timeline.shipped90 + ' shipped in the last 90 days: '}
                  <button type="button" className={styles.linkButton} onClick={() => { setTimelinePreset('past90'); setTimelineCell(null); }}>show Past 90 days</button>
                </span>
              )}
              <span>{'Outside this range: ' + timeline.earlier + ' earlier, ' + timeline.later + ' later' + (timeline.undated ? ', ' + timeline.undated + ' without a date' : '') + '.'}</span>
            </div>
            {timelineAsList ? (
              timeline.rows.map((r) => {
                const pts = timeline.points.filter((p) => p.row === r.key).sort((a, b) => a.day - b.day);
                return (
                  <div key={r.key}>
                    <Text weight="semibold">{r.label + ' (' + pts.length + ')'}</Text>
                    <ul className={styles.list}>
                      {pts.map((p) => (
                        <li key={p.id}>
                          <button type="button" className={styles.linkButton} onClick={() => open(p.id)}>{p.title}</button>
                          <Caption1 className={styles.muted}>{' · ' + formatDisplayDate(formatUtcDay(p.day)) + ' · ' + p.ref + (p.action ? ' · Action required' : '')}</Caption1>
                        </li>
                      ))}
                    </ul>
                  </div>
                );
              })
            ) : (
              <>
                <TimelineGrid
                  points={timeline.points}
                  bins={timeline.bins}
                  granularity={timeline.granularity}
                  rows={timeline.rows}
                  todayMs={todayMs}
                  selected={timelineSelection ? timelineCell : null}
                  onSelect={setTimelineCell}
                />
                {timelineSelection && (
                  <section className={styles.tlPanel} aria-label={'Items: ' + timelineSelection.label}>
                    <div className={styles.sectionHead}>
                      <Text weight="semibold" className={styles.sectionTitle}>{timelineSelection.label + ' (' + timelineSelection.list.length + ')'}</Text>
                      <Button size="small" appearance="subtle" icon={<DismissRegular />} onClick={() => setTimelineCell(null)}>Close</Button>
                    </div>
                    <ul className={styles.list}>
                      {timelineSelection.list.map((p) => (
                        <li key={p.id} className={styles.tlPanelItem}>
                          <button type="button" className={styles.linkButton} onClick={() => open(p.id)}>{p.title}</button>
                          <Caption1 className={styles.muted}>{p.ref + ' · ' + formatDisplayDate(formatUtcDay(p.day))}</Caption1>
                          <ImpactBadge impact={p.impact} />
                          {p.action && <span className={styles.actionMark}>Action required</span>}
                          {relationOf(itemById[p.id])}
                        </li>
                      ))}
                    </ul>
                  </section>
                )}
              </>
            )}
          </Section>

          <Section
            id="solutions"
            title="By solution"
            collapsed={!!collapsed.solutions}
            onToggle={() => toggleSection('solutions')}
            summary={model.showingDemo
              ? solutionView.demo.filter((r) => r.items > 0).length + ' solutions with exposures in the demo organisation'
              : solutionView.live.filter((r) => r.items > 0).length + ' solutions with live exposures' + (solutionView.demo.some((r) => r.items > 0) ? ', ' + solutionView.demo.filter((r) => r.items > 0).length + ' in test fixtures' : '')}
          >
            <Caption1 className={styles.muted}>
              Affects: signals with an open exposure on one of the solution's components. Related: signals that share a connector, capability, model, setting, harness or authentication mode with a component, without an exposure. A solution deployed to several environments is one row. Select a solution to show only it in every section; select it again to clear.
            </Caption1>
            {!model.showingDemo && renderSolutionTable(solutionView.live, 'Solutions in your estate')}
            {solutionView.demo.length > 0 && (
              <>
                <div className={styles.sectionHead}>
                  <Subtitle2 as="h3">{model.showingDemo ? 'Demo organisation' : 'Test fixtures'}</Subtitle2>
                  <Badge appearance="filled" color="warning">Not your estate</Badge>
                </div>
                {renderSolutionTable(solutionView.demo, model.showingDemo ? 'Solutions in the demo organisation' : 'Solutions in test fixtures')}
              </>
            )}
            {filters.solution && <Caption1>{'Showing only: ' + solutionLabel(filters.solution) + '.'}</Caption1>}
          </Section>
          <Section
            id="patterns"
            title="Patterns across the items"
            collapsed={!!collapsed.patterns}
            onToggle={() => toggleSection('patterns')}
            summary={patternItems.length + ' items in ' + patterns.filter((p) => p.items.length > 0).length + ' themes'}
            actions={<Switch label="Show older items" checked={patternsShowOlder} onChange={(_, d) => setPatternsShowOlder(!!d.checked)} />}
          >
            <Caption1 className={styles.muted}>
              {patternsShowOlder
                ? 'All ' + filtered.length + ' items, whenever they landed.'
                : patternItems.length + ' of ' + filtered.length + ' items: those landing from ' + PATTERN_WINDOW_DAYS + ' days ago onwards, and those with no date. ' + (filtered.length - patternItems.length) + ' older items are hidden.'}
            </Caption1>
            <div className={styles.themes}>
              {patterns.map((p) => (
                <section key={p.key} className={styles.theme} aria-label={p.label + ': ' + p.items.length + ' items'}>
                  <div className={styles.themeHead}>
                    <Text weight="semibold">{p.label}</Text>
                    <Badge appearance="tint" color="informative">{p.items.length}</Badge>
                  </div>
                  {p.items.length === 0 ? <Caption1 className={styles.muted}>No items.</Caption1> : <ItemList cellKey={'p|' + p.key} items={p.items} expanded={expanded} onToggle={toggleCell} onOpen={open} />}
                </section>
              ))}
            </div>
          </Section>

          <Section
            id="imminent"
            title={'Imminent (' + imminent.length + ')'}
            collapsed={!!collapsed.imminent}
            onToggle={() => toggleSection('imminent')}
          >
            <Caption1 className={styles.muted}>Now and Imminent items, soonest first.</Caption1>
            {imminent.length === 0 ? (
              <Text>No imminent items match the filters.</Text>
            ) : (
              <div className={styles.scrollX}>
                <Table className={styles.table} aria-labelledby="imminent-title" size="small">
                  <TableHeader>
                    <TableRow>
                      <TableHeaderCell style={{ width: '12%' }}>When</TableHeaderCell>
                      <TableHeaderCell style={{ width: '13%' }}>Product</TableHeaderCell>
                      <TableHeaderCell style={{ width: '30%' }}>Item</TableHeaderCell>
                      <TableHeaderCell style={{ width: '15%' }}>Impact</TableHeaderCell>
                      <TableHeaderCell style={{ width: '22%' }}>Risk and opportunity (LLM assessment)</TableHeaderCell>
                      <TableHeaderCell style={{ width: '8%' }}>Ref</TableHeaderCell>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(expanded['imminent'] ? imminent : imminent.slice(0, TABLE_LIMIT)).map((i) => (
                      <TableRow key={i.id}>
                        <TableCell>
                          <div className={styles.cellText}>
                            <Text weight="semibold">{formatDisplayDate(i.keyDate)}</Text>
                            <Caption1 className={styles.muted}>{i.dateLabel}</Caption1>
                            {i.actionRequired && <Badge appearance="filled" color="danger" icon={<WarningRegular />}>Action</Badge>}
                          </div>
                        </TableCell>
                        <TableCell><div className={styles.cellText}><Text size={200}>{i.productsText || 'Not stated'}</Text></div></TableCell>
                        <TableCell>
                          <div className={styles.cellText}>
                            <button type="button" className={styles.linkButton} onClick={() => open(i.id)} aria-label={i.title + '. Opens the signal.'}>{i.title}</button>
                            {i.watched && <Badge appearance="tint" color="brand" icon={<EyeRegular />}>Watched</Badge>}
                            <Caption1 className={styles.muted}>{cut(i.summary, 300)}</Caption1>
                          </div>
                        </TableCell>
                        <TableCell>
                          <div className={styles.cellText}>
                            <div className={styles.badges}>
                              <ImpactBadge impact={i.impact.impact} />
                              {i.impact.basis !== 'generic' && i.genericImpact && <ImpactBadge impact={i.genericImpact} prefix="Generic" />}
                            </div>
                            <Caption1 className={styles.muted}>{'Basis: ' + basisLabel(i.impact.basis)}</Caption1>
                            {i.impactType && <Caption1>{IMPACT_TYPE_LABELS[i.impactType]}</Caption1>}
                            {i.audience && <Caption1 className={styles.muted}>{i.audience}</Caption1>}
                          </div>
                        </TableCell>
                        <TableCell>
                          <div className={styles.cellText}>
                            {i.risk && <Text size={200}><strong>Risk: </strong>{i.risk}</Text>}
                            {i.opportunity && <Text size={200}><strong>Opportunity: </strong>{i.opportunity}</Text>}
                            {!i.risk && !i.opportunity && <Caption1 className={styles.muted}>Not yet rated</Caption1>}
                            {i.confidence && <Caption1 className={styles.muted}>{'Confidence: ' + i.confidence}</Caption1>}
                          </div>
                        </TableCell>
                        <TableCell>
                          <div className={styles.cellText}>
                            {i.url ? (
                              <Link href={i.url} target="_blank" rel="noopener noreferrer" aria-label={i.ref + ' (opens the source in a new tab)'}>
                                {i.ref} <OpenRegular aria-hidden="true" />
                              </Link>
                            ) : (
                              <Text size={200}>{i.ref}</Text>
                            )}
                          </div>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
            {imminent.length > TABLE_LIMIT && (
              <Button appearance="secondary" onClick={() => toggleCell('imminent')}>
                {expanded['imminent'] ? 'Show the first ' + TABLE_LIMIT : 'Show all ' + imminent.length + ' imminent items'}
              </Button>
            )}
          </Section>

          <Section
            id="estate"
            title={model.showingDemo ? 'The demo organisation\'s estate' : 'Your estate'}
            collapsed={!!collapsed.estate}
            onToggle={() => toggleSection('estate')}
            summary={model.showingDemo
              ? estateDemo.length + ' signals with exposures in the demo organisation'
              : estateLive.length + ' signals with live exposures' + (estateDemo.length ? ', ' + estateDemo.length + ' in test fixtures' : '')}
            actions={<Switch label="Group by solution" checked={estateBySolution} onChange={(_, d) => setEstateBySolution(!!d.checked)} />}
          >
            <Caption1 className={styles.muted}>
              {estateBySolution
                ? 'Signals with open exposures, under each solution that holds an exposed asset. An asset in two solutions appears under both.'
                : 'Signals with open exposures (new or confirmed), and the affected assets.'}
            </Caption1>
            {!model.showingDemo && (estateLive.length === 0 ? <Text>No live exposures match the filters.</Text> : estateBySolution ? renderEstateBySolution(estateLive, true) : renderEstate(estateLive, false))}
            {model.showingDemo && estateDemo.length === 0 && <Text>No exposures in the demo organisation match the filters.</Text>}
            {estateDemo.length > 0 && (
              <>
                <div className={styles.sectionHead}>
                  <Subtitle2 as="h3">{model.showingDemo ? 'Demo organisation' : 'Test fixtures'}</Subtitle2>
                  <Badge appearance="filled" color="warning">Not your estate</Badge>
                </div>
                <Caption1 className={styles.muted}>{model.showingDemo
                  ? 'The synthetic demo organisation: every count and chart on this page is its estate while demo data is on.'
                  : 'Test assets, kept apart from your estate and never counted in its ratings.'}</Caption1>
                {estateBySolution ? renderEstateBySolution(estateDemo, false) : renderEstate(estateDemo, true)}
              </>
            )}
          </Section>
        </>
      )}
    </div>
  );
}

const GeneratedComponent = (props: GeneratedComponentProps) => (
  <PageErrorBoundary>
    <PageBody {...props} />
  </PageErrorBoundary>
);

export default GeneratedComponent;

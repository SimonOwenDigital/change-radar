import * as React from 'react';
import {
  makeStyles,
  tokens,
  Badge,
  Button,
  Caption1,
  Card,
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
  Tab,
  TabList,
  Text,
  Title2,
} from '@fluentui/react-components';
import { ArrowClockwiseRegular, ArrowUndoRegular, CheckmarkRegular, DismissRegular, OpenRegular, WarningRegular } from '@fluentui/react-icons';
import type {
  DataTable,
  GeneratedComponentProps,
  ReadableTableRow,
  crdr_config,
  crdr_exposure,
  crdr_facetvalue,
  crdr_rule,
  crdr_signal,
  crdr_signalfingerprint,
} from './RuntimeTypes';

// ENGINE:BEGIN
// Pure functions: what a review decision does to matching at the next match run. They mirror engine
// Find-Exposures (engine/ChangeRadar.Matching.psm1): only accepted rows count; rows are grouped by group;
// facets within a group are ANDed and values within a facet are ORed; a facet with no active rule is
// ignored; a group matches assets only with at least one trigger clause; setting-role facets are tenant
// setting checks; values compare case-insensitively. Cases: tests/review/review.json.

type ReviewStatus = 'accepted' | 'review' | 'rejected';
type ReviewDecision = 'accept' | 'reject' | 'review';
type EffectKind = 'opens' | 'closes' | 'narrows' | 'widens' | 'setting-added' | 'setting-removed' | 'none';
type ReviewRow = { id: string; group: string; facet: string; value: string; status: ReviewStatus };
type ReviewRule = { facet: string; role: string };
type ReviewVocabularyEntry = { facet: string; value: string };
type ReviewExposure = { group: string; status: string; source: string };
type ReviewInput = {
  rows: ReviewRow[];
  rules: ReviewRule[];
  vocabulary: ReviewVocabularyEntry[];
  exposures: ReviewExposure[];
  target: string;
  decision: ReviewDecision;
};
type ReviewEffect = {
  kind: EffectKind;
  notInVocabulary: boolean;
  signalLeftEmpty: boolean;
  groupOpen: { live: number; other: number };
  otherTriggerGroups: string[];
};

const OPEN_EXPOSURE_STATUSES = ['new', 'confirmed'];

function statusAfter(decision: ReviewDecision): ReviewStatus {
  return decision === 'accept' ? 'accepted' : decision === 'reject' ? 'rejected' : 'review';
}

function roleOf(rules: ReviewRule[], facet: string): string | null {
  for (const r of rules) if (r.facet === facet) return r.role;
  return null;
}

// Facet -> sorted, lower-cased, de-duplicated values, from the accepted rows of one group (facets with a rule only).
function buildClauses(rows: ReviewRow[], rules: ReviewRule[], group: string): Record<string, string[]> {
  const clauses: Record<string, string[]> = {};
  for (const r of rows) {
    if (r.status !== 'accepted' || r.group !== group || !roleOf(rules, r.facet)) continue;
    const v = String(r.value).trim().toLowerCase();
    const list = clauses[r.facet] || (clauses[r.facet] = []);
    if (list.indexOf(v) < 0) list.push(v);
  }
  Object.keys(clauses).forEach((k) => clauses[k].sort());
  return clauses;
}

function hasTrigger(clauses: Record<string, string[]>, rules: ReviewRule[]): boolean {
  return Object.keys(clauses).some((f) => roleOf(rules, f) === 'trigger' && clauses[f].length > 0);
}

function sameValues(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

function compareGroups(a: string, b: string): number {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' });
}

function previewEffect(input: ReviewInput): ReviewEffect {
  const { rows, rules, vocabulary, exposures, target, decision } = input;
  const row = rows.filter((r) => r.id === target)[0];
  const none: ReviewEffect = { kind: 'none', notInVocabulary: false, signalLeftEmpty: false, groupOpen: { live: 0, other: 0 }, otherTriggerGroups: [] };
  if (!row) return none;
  const next = statusAfter(decision);
  const after = rows.map((r) => (r.id === target ? { id: r.id, group: r.group, facet: r.facet, value: r.value, status: next } : r));
  const before = buildClauses(rows, rules, row.group);
  const afterClauses = buildClauses(after, rules, row.group);
  const role = roleOf(rules, row.facet);

  let kind: EffectKind = 'none';
  if (role) {
    const was = before[row.facet] || [];
    const now = afterClauses[row.facet] || [];
    if (!sameValues(was, now)) {
      if (role === 'setting') {
        kind = now.length > was.length ? 'setting-added' : 'setting-removed';
      } else {
        const triggerBefore = hasTrigger(before, rules);
        const triggerAfter = hasTrigger(afterClauses, rules);
        if (!triggerBefore && triggerAfter) kind = 'opens';
        else if (triggerBefore && !triggerAfter) kind = 'closes';
        else if (!triggerBefore && !triggerAfter) kind = 'none';
        else if (was.length === 0) kind = 'narrows';
        else if (now.length === 0) kind = 'widens';
        else kind = now.length > was.length ? 'widens' : 'narrows';
      }
    }
  }

  const value = String(row.value).trim().toLowerCase();
  const notInVocabulary = !vocabulary.some((v) => v.facet === row.facet && String(v.value).trim().toLowerCase() === value);
  const acceptedBefore = rows.some((r) => r.status === 'accepted');
  const acceptedAfter = after.some((r) => r.status === 'accepted');
  const groupOpen = { live: 0, other: 0 };
  for (const e of exposures) {
    if (e.group !== row.group || OPEN_EXPOSURE_STATUSES.indexOf(e.status) < 0) continue;
    if (e.source === 'live') groupOpen.live++;
    else groupOpen.other++;
  }
  const groups: string[] = [];
  for (const r of after) if (r.group !== row.group && groups.indexOf(r.group) < 0) groups.push(r.group);
  const otherTriggerGroups = groups.filter((g) => hasTrigger(buildClauses(after, rules, g), rules)).sort(compareGroups);
  return { kind, notInVocabulary, signalLeftEmpty: acceptedBefore && !acceptedAfter, groupOpen, otherTriggerGroups };
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

const PAGE_NAME = 'Fingerprint review';

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

const FACET_CODES: Record<number, string> = {
  169890000: 'product', 169890001: 'resource_type', 169890002: 'connector', 169890003: 'capability',
  169890004: 'auth_mode', 169890005: 'harness', 169890006: 'setting', 169890007: 'environment_type',
};
const FACET_LABELS: Record<string, string> = {
  product: 'Product', resource_type: 'Resource type', connector: 'Connector', capability: 'Capability',
  auth_mode: 'Auth mode', harness: 'Harness', setting: 'Setting', environment_type: 'Environment type',
};
const FACET_ORDER = ['product', 'resource_type', 'environment_type', 'harness', 'connector', 'capability', 'auth_mode', 'setting'];
const ROLE_CODES: Record<number, string> = { 169890000: 'scope', 169890001: 'trigger', 169890002: 'setting' };
const ROLE_LABELS: Record<string, string> = { scope: 'scope', trigger: 'trigger', setting: 'setting check' };
const STATUS_CODES: Record<number, ReviewStatus> = { 169890000: 'accepted', 169890001: 'review', 169890002: 'rejected' };
const STATUS_VALUES: Record<ReviewStatus, number> = { accepted: 169890000, review: 169890001, rejected: 169890002 };
const STATUS_LABELS: Record<ReviewStatus, string> = { accepted: 'Accepted', review: 'To review', rejected: 'Rejected' };
const EXTRACTED_CODES: Record<number, string> = { 169890000: 'rule', 169890001: 'llm', 169890002: 'manual' };
const EXTRACTED_LABELS: Record<string, string> = { rule: 'Rule', llm: 'LLM', manual: 'Manual' };
const EXPOSURE_STATUS_CODES: Record<number, string> = { 169890000: 'new', 169890001: 'confirmed', 169890002: 'dismissed', 169890003: 'unmatched' };
const ASSET_SOURCE_CODES: Record<number, string> = { 169890000: 'live', 169890001: 'fixture', 169890002: 'synthetic' };
const THRESHOLD_KEY = 'fingerprint_confidence_threshold';
const DEFAULT_THRESHOLD = 0.7;

type FingerprintRow = ReadableTableRow<crdr_signalfingerprint>;
type SignalRow = ReadableTableRow<crdr_signal>;
type RuleRow = ReadableTableRow<crdr_rule>;
type ExposureRow = ReadableTableRow<crdr_exposure>;
type ConfigRow = ReadableTableRow<crdr_config>;
type VocabularyRow = ReadableTableRow<crdr_facetvalue>;

type Fingerprint = {
  id: string;
  signalId: string | null;
  group: string;
  facet: string;
  value: string;
  extractedBy: string;
  confidence: number | null;
  reason: string;
  status: ReviewStatus;
};
type SignalInfo = { code: string; title: string };
type Audit = { by: string; on: string };
type Bundle = {
  fingerprints: Fingerprint[];
  signals: Record<string, SignalInfo>;
  rules: ReviewRule[];
  vocabulary: ReviewVocabularyEntry[];
  exposuresBySignal: Record<string, ReviewExposure[]>;
  threshold: number;
  thresholdIsDefault: boolean;
  audit: Record<string, Audit> | null;
};

// ---------------------------------------------------------------------------------------------
// Row mapping helpers.

function codeOf<T extends string>(value: unknown, map: Record<number, T>): T | null {
  const n = typeof value === 'number' ? value : typeof value === 'string' && value !== '' ? Number(value) : NaN;
  return isNaN(n) ? null : map[n] || null;
}

function textOf(value: unknown): string {
  return typeof value === 'string' ? value : value === null || value === undefined ? '' : String(value);
}

function numberOf(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  const n = typeof value === 'number' ? value : Number(value);
  return isNaN(n) ? null : n;
}

function lookupId(row: unknown, property: string, target: string): string | null {
  const n = normalizeLookupReference(row, property, [target]);
  return n.state === 'resolved' ? n.reference.id : null;
}

function formatted(row: unknown, property: string): string {
  const r = row as Record<string, unknown>;
  return textOf(r[property + '@OData.Community.Display.V1.FormattedValue']);
}

function toFingerprint(row: FingerprintRow): Fingerprint {
  const r = row as unknown as Record<string, unknown>;
  return {
    id: textOf(r.crdr_signalfingerprintid).toLowerCase(),
    signalId: lookupId(row, '_crdr_signal_value', 'crdr_signal'),
    group: textOf(r.crdr_group).trim() || 'A',
    facet: codeOf(r.crdr_facet, FACET_CODES) || '',
    value: textOf(r.crdr_value),
    extractedBy: codeOf(r.crdr_extractedby, EXTRACTED_CODES) || '',
    confidence: numberOf(r.crdr_confidence),
    reason: textOf(r.crdr_reason),
    status: codeOf(r.crdr_status, STATUS_CODES) || 'review',
  };
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

function describeEffect(effect: ReviewEffect, group: string, role: string | null, signalOpen: number): string {
  const open = effect.groupOpen.live + effect.groupOpen.other;
  const openText = open === 0
    ? 'it has no open exposures'
    : 'up to ' + open + ' open exposure' + (open === 1 ? '' : 's') + ' (' + effect.groupOpen.live + ' live, ' + effect.groupOpen.other + ' demo) will close';
  const others = effect.otherTriggerGroups.length > 0
    ? ' Assets that group ' + effect.otherTriggerGroups.join(' or ') + ' also matches stay open.'
    : '';
  let text: string;
  switch (effect.kind) {
    case 'closes': text = 'Group ' + group + ' stops matching assets: ' + openText + '.' + others; break;
    case 'opens': text = 'Group ' + group + ' starts matching assets: new exposures may appear.'; break;
    case 'widens': text = 'Group ' + group + ' widens: it may match more assets.'; break;
    case 'narrows': text = 'Group ' + group + ' narrows: some exposures may close.'; break;
    case 'setting-added': text = 'Adds a tenant setting check to group ' + group + '.'; break;
    case 'setting-removed': text = 'Removes a tenant setting check from group ' + group + (open > 0 ? ': ' + openText : '') + '.'; break;
    default: text = role ? 'No change to matching.' : 'No change to matching: no active rule uses this facet.';
  }
  if (effect.signalLeftEmpty) {
    text += signalOpen > 0
      ? ' The signal is left with no accepted fingerprint, so all ' + signalOpen + ' of its open exposures will close.'
      : ' The signal is left with no accepted fingerprint.';
  }
  if (effect.notInVocabulary) text += ' This value is not in the vocabulary, so it can\u2019t match any asset.';
  return text;
}

// ---------------------------------------------------------------------------------------------
// Data loading: one cached bundle, de-duplicated across the host double-mount (data-caching.md).

const winAny = window as any;
const CACHE_KEY = '__ppFingerprintReview_bundleCache';
const INFLIGHT_KEY = '__ppFingerprintReview_bundleInflight';

async function readAllRows<T>(first: DataTable<T>): Promise<T[]> {
  let page = first;
  const rows: T[] = page.rows.slice();
  while (page.hasMoreRows && page.loadMoreRows) {
    page = await page.loadMoreRows();
    page.rows.forEach((r) => rows.push(r));
  }
  return rows;
}

// Last changed by / on (A2). Read separately so the page still works if the host declines these system columns.
async function loadAudit(dataApi: GeneratedComponentProps['dataApi']): Promise<Record<string, Audit> | null> {
  try {
    const select = ['crdr_signalfingerprintid', 'modifiedon', '_modifiedby_value'] as unknown as Array<keyof FingerprintRow>;
    const rows = await readAllRows(await dataApi.queryTable('crdr_signalfingerprint', { select: select as any, pageSize: 500 }));
    const audit: Record<string, Audit> = {};
    rows.forEach((row) => {
      const r = row as unknown as Record<string, unknown>;
      const by = formatted(row, '_modifiedby_value');
      const on = formatted(row, 'modifiedon') || textOf(r.modifiedon);
      if (by || on) audit[textOf(r.crdr_signalfingerprintid).toLowerCase()] = { by, on };
    });
    return audit;
  } catch {
    return null;
  }
}

async function loadBundle(dataApi: GeneratedComponentProps['dataApi']): Promise<Bundle> {
  const results = await Promise.allSettled([
    dataApi
      .queryTable('crdr_signalfingerprint', {
        select: ['crdr_signalfingerprintid', 'crdr_name', '_crdr_signal_value', 'crdr_group', 'crdr_facet', 'crdr_value', 'crdr_extractedby', 'crdr_confidence', 'crdr_reason', 'crdr_status'],
        pageSize: 500,
      })
      .then((t) => readAllRows(t)),
    dataApi.queryTable('crdr_rule', { select: ['crdr_ruleid', 'crdr_signalfacet', 'crdr_role', 'crdr_rulecode', 'crdr_name'], filter: 'crdr_active eq true', pageSize: 100 }).then((t) => readAllRows(t)),
    dataApi
      .queryTable('crdr_exposure', {
        select: ['crdr_exposureid', '_crdr_signal_value', 'crdr_group', 'crdr_status', 'crdr_source'],
        filter: 'crdr_status eq 169890000 or crdr_status eq 169890001',
        pageSize: 500,
      })
      .then((t) => readAllRows(t)),
    dataApi.queryTable('crdr_config', { select: ['crdr_configid', 'crdr_value'], filter: "crdr_key eq '" + THRESHOLD_KEY + "'", pageSize: 1 }),
    dataApi.queryTable('crdr_facetvalue', { select: ['crdr_facetvalueid', 'crdr_facet', 'crdr_value'], filter: 'crdr_active eq true', pageSize: 500 }).then((t) => readAllRows(t)),
    loadAudit(dataApi),
  ]);
  const operations = ['loadFingerprints', 'loadRules', 'loadExposures', 'loadThreshold', 'loadVocabulary', 'loadAudit'];
  let firstFailure: { operation: string; reason: unknown } | null = null;
  results.forEach((r, i) => {
    if (r.status === 'rejected' && !firstFailure) firstFailure = { operation: operations[i], reason: r.reason };
  });
  if (firstFailure) throw firstFailure;
  const fingerprints = (results[0] as PromiseFulfilledResult<FingerprintRow[]>).value.map(toFingerprint).filter((f) => f.id);
  const ruleRows = (results[1] as PromiseFulfilledResult<RuleRow[]>).value;
  const exposureRows = (results[2] as PromiseFulfilledResult<ExposureRow[]>).value;
  const configRows = (results[3] as PromiseFulfilledResult<DataTable<ConfigRow>>).value.rows;
  const vocabularyRows = (results[4] as PromiseFulfilledResult<VocabularyRow[]>).value;
  const audit = (results[5] as PromiseFulfilledResult<Record<string, Audit> | null>).value;

  const rules: ReviewRule[] = [];
  ruleRows.forEach((row) => {
    const r = row as unknown as Record<string, unknown>;
    const facet = codeOf(r.crdr_signalfacet, FACET_CODES);
    const role = codeOf(r.crdr_role, ROLE_CODES);
    if (facet && role) rules.push({ facet, role });
  });
  const vocabulary: ReviewVocabularyEntry[] = [];
  vocabularyRows.forEach((row) => {
    const r = row as unknown as Record<string, unknown>;
    const facet = codeOf(r.crdr_facet, FACET_CODES);
    if (facet) vocabulary.push({ facet, value: textOf(r.crdr_value) });
  });
  const exposuresBySignal: Record<string, ReviewExposure[]> = {};
  exposureRows.forEach((row) => {
    const r = row as unknown as Record<string, unknown>;
    const sid = lookupId(row, '_crdr_signal_value', 'crdr_signal');
    if (!sid) return;
    (exposuresBySignal[sid] = exposuresBySignal[sid] || []).push({
      group: textOf(r.crdr_group).trim(),
      status: codeOf(r.crdr_status, EXPOSURE_STATUS_CODES) || '',
      source: codeOf(r.crdr_source, ASSET_SOURCE_CODES) || '',
    });
  });
  const parsed = configRows.length > 0 ? Number(textOf((configRows[0] as unknown as Record<string, unknown>).crdr_value).trim()) : NaN;
  const thresholdIsDefault = isNaN(parsed) || textOf(configRows[0] ? (configRows[0] as unknown as Record<string, unknown>).crdr_value : '').trim() === '';

  // Signals behind the fingerprints (the data API reads one table at a time).
  const signalIds = Array.from(new Set(fingerprints.map((f) => f.signalId).filter((id): id is string => !!id)));
  const signals: Record<string, SignalInfo> = {};
  for (let i = 0; i < signalIds.length; i += 15) {
    const chunk = signalIds.slice(i, i + 15);
    try {
      const page = await dataApi.queryTable('crdr_signal', {
        select: ['crdr_signalid', 'crdr_externalid', 'crdr_title'],
        filter: chunk.map((id) => 'crdr_signalid eq ' + id).join(' or '),
        pageSize: 50,
      });
      (await readAllRows(page)).forEach((s: SignalRow) => {
        const r = s as unknown as Record<string, unknown>;
        signals[textOf(r.crdr_signalid).toLowerCase()] = { code: textOf(r.crdr_externalid), title: textOf(r.crdr_title) };
      });
    } catch (reason) {
      throw { operation: 'loadSignals', reason };
    }
  }
  return { fingerprints, signals, rules, vocabulary, exposuresBySignal, threshold: thresholdIsDefault ? DEFAULT_THRESHOLD : parsed, thresholdIsDefault, audit };
}

// ---------------------------------------------------------------------------------------------
// Styles.

const useStyles = makeStyles({
  root: {
    height: '100%',
    overflowY: 'auto',
    boxSizing: 'border-box',
    position: 'relative',
    contain: 'layout',
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalL,
    padding: tokens.spacingHorizontalL,
    color: tokens.colorNeutralForeground1,
    backgroundColor: tokens.colorNeutralBackground2,
  },
  header: { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: tokens.spacingHorizontalM, flexShrink: 0 },
  headerTitle: { marginRight: 'auto' },
  muted: { color: tokens.colorNeutralForeground3 },
  counts: { display: 'flex', flexWrap: 'wrap', gap: tokens.spacingHorizontalS, alignItems: 'center', flexShrink: 0 },
  filters: { display: 'flex', flexWrap: 'wrap', alignItems: 'flex-end', gap: tokens.spacingHorizontalL, flexShrink: 0 },
  field: { display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalXXS, minWidth: '160px' },
  signal: { display: 'flex', flexDirection: 'column', gap: tokens.spacingVerticalM, flexShrink: 0 },
  signalHead: { display: 'flex', flexWrap: 'wrap', alignItems: 'baseline', gap: tokens.spacingHorizontalS },
  group: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalS,
    paddingLeft: tokens.spacingHorizontalM,
    borderLeftWidth: '3px',
    borderLeftStyle: 'solid',
    borderLeftColor: tokens.colorNeutralStroke2,
  },
  groupHead: { display: 'flex', flexWrap: 'wrap', alignItems: 'baseline', gap: tokens.spacingHorizontalS },
  row: {
    display: 'flex',
    flexDirection: 'column',
    gap: tokens.spacingVerticalXS,
    padding: tokens.spacingHorizontalM,
    backgroundColor: tokens.colorNeutralBackground1,
    borderRadius: tokens.borderRadiusMedium,
    boxShadow: tokens.shadow2,
  },
  rowTop: { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: tokens.spacingHorizontalS },
  facetValue: { fontWeight: tokens.fontWeightSemibold, overflowWrap: 'anywhere' },
  reason: { overflowWrap: 'anywhere' },
  actions: { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: tokens.spacingHorizontalS },
  preview: { color: tokens.colorNeutralForeground2, flexBasis: '100%' },
  warning: { display: 'flex', alignItems: 'center', gap: tokens.spacingHorizontalXS, color: tokens.colorPaletteDarkOrangeForeground1 },
  empty: { display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: tokens.spacingVerticalM, padding: tokens.spacingHorizontalL },
  srOnly: {
    position: 'absolute',
    width: '1px',
    height: '1px',
    overflow: 'hidden',
    clip: 'rect(0 0 0 0)',
    whiteSpace: 'nowrap',
  },
});

// ---------------------------------------------------------------------------------------------
// The page.

type StatusTab = ReviewStatus;
type Pending = { fingerprint: Fingerprint; decision: ReviewDecision; effect: ReviewEffect; text: string };

function PageBody(props: GeneratedComponentProps) {
  const { dataApi } = props;
  const styles = useStyles();
  const dataReady = !!dataApi;
  const [mountNode, setMountNode] = React.useState<HTMLElement | null>(null);
  const setContainer = React.useCallback((node: HTMLDivElement | null) => setMountNode(node), []);
  const [reloadKey, setReloadKey] = React.useState(0);
  const [{ bundle, loading, error }, setData] = React.useState<{ bundle: Bundle | null; loading: boolean; error: PageErrorView | null }>(() => {
    const cached = winAny[CACHE_KEY] as Bundle | undefined;
    return { bundle: cached ?? null, loading: cached === undefined, error: null };
  });
  const [statuses, setStatuses] = React.useState<Record<string, ReviewStatus>>({});
  const [inFlight, setInFlight] = React.useState<Record<string, boolean>>({});
  const [writeError, setWriteError] = React.useState<PageErrorView | null>(null);
  const [navError, setNavError] = React.useState<PageErrorView | null>(null);
  const [announcement, setAnnouncement] = React.useState('');
  const [tab, setTab] = React.useState<StatusTab>('review');
  const [extractedBy, setExtractedBy] = React.useState('');
  const [confirm, setConfirm] = React.useState<Pending | null>(null);

  function reload() {
    delete winAny[CACHE_KEY];
    delete winAny[INFLIGHT_KEY];
    setData({ bundle: null, loading: true, error: null });
    setStatuses({});
    setWriteError(null);
    setReloadKey((k) => k + 1);
  }

  React.useEffect(() => {
    if (!dataReady) return;
    const cached = winAny[CACHE_KEY] as Bundle | undefined;
    if (cached !== undefined) {
      if (bundle !== cached) setData({ bundle: cached, loading: false, error: null });
      return;
    }
    let cancelled = false;
    let inflight = winAny[INFLIGHT_KEY] as Promise<Bundle> | undefined;
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
        const operation = failure && failure.operation ? failure.operation : 'loadFingerprintReview';
        const reason = failure && 'reason' in failure ? failure.reason : failure;
        setData({ bundle: null, loading: false, error: reportPageError(PAGE_NAME, operation, undefined, reason, 'read', reload) });
      });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dataReady, reloadKey]);

  // Fingerprints with any local decisions applied.
  const fingerprints = React.useMemo<Fingerprint[]>(() => {
    if (!bundle) return [];
    return bundle.fingerprints.map((f) => (statuses[f.id] && statuses[f.id] !== f.status ? { ...f, status: statuses[f.id] } : f));
  }, [bundle, statuses]);

  const bySignal = React.useMemo(() => {
    const map: Record<string, Fingerprint[]> = {};
    fingerprints.forEach((f) => {
      const key = f.signalId || '';
      (map[key] = map[key] || []).push(f);
    });
    return map;
  }, [fingerprints]);

  const counts = React.useMemo(() => {
    const c = { review: 0, accepted: 0, acceptedLlm: 0, acceptedManual: 0, rejected: 0 };
    fingerprints.forEach((f) => {
      if (f.status === 'review') c.review++;
      else if (f.status === 'rejected') c.rejected++;
      else {
        c.accepted++;
        if (f.extractedBy === 'llm') c.acceptedLlm++;
        if (f.extractedBy === 'manual') c.acceptedManual++;
      }
    });
    return c;
  }, [fingerprints]);

  const previewFor = React.useCallback((f: Fingerprint, decision: ReviewDecision): ReviewEffect => {
    const rows = (bySignal[f.signalId || ''] || []).map((r) => ({ id: r.id, group: r.group, facet: r.facet, value: r.value, status: r.status }));
    return previewEffect({
      rows,
      rules: bundle ? bundle.rules : [],
      vocabulary: bundle ? bundle.vocabulary : [],
      exposures: bundle && f.signalId ? bundle.exposuresBySignal[f.signalId] || [] : [],
      target: f.id,
      decision,
    });
  }, [bySignal, bundle]);

  // Visible sections: signal -> group -> rows, after the status and extracted-by filters.
  const sections = React.useMemo(() => {
    if (!bundle) return [] as Array<{ signalId: string; info: SignalInfo | null; groups: Array<{ group: string; rows: Fingerprint[] }> }>;
    const visible = fingerprints.filter((f) => f.status === tab && (!extractedBy || f.extractedBy === extractedBy));
    const signalKeys = Array.from(new Set(visible.map((f) => f.signalId || '')));
    const list = signalKeys.map((sid) => {
      const rows = visible.filter((f) => (f.signalId || '') === sid);
      const groups = Array.from(new Set(rows.map((r) => r.group))).sort(compareGroups).map((g) => ({
        group: g,
        rows: rows
          .filter((r) => r.group === g)
          .sort((a, b) => FACET_ORDER.indexOf(a.facet) - FACET_ORDER.indexOf(b.facet) || a.value.localeCompare(b.value)),
      }));
      return { signalId: sid, info: sid ? bundle.signals[sid] || null : null, groups };
    });
    return list.sort((a, b) => {
      if (!a.signalId) return 1;
      if (!b.signalId) return -1;
      return (a.info ? a.info.code : a.signalId).localeCompare(b.info ? b.info.code : b.signalId, undefined, { numeric: true });
    });
  }, [bundle, fingerprints, tab, extractedBy]);

  const visibleCount = sections.reduce((n, s) => n + s.groups.reduce((m, g) => m + g.rows.length, 0), 0);

  function signalLabel(f: Fingerprint): string {
    const info = bundle && f.signalId ? bundle.signals[f.signalId] : null;
    return info ? info.code || info.title : 'a signal';
  }

  function commit(f: Fingerprint, decision: ReviewDecision, effectText: string) {
    const previous = f.status;
    const next = statusAfter(decision);
    setStatuses((s) => ({ ...s, [f.id]: next }));
    setInFlight((s) => ({ ...s, [f.id]: true }));
    setWriteError(null);
    const label = (FACET_LABELS[f.facet] || f.facet) + ' ' + f.value + ' on ' + signalLabel(f);
    dataApi
      .updateRow('crdr_signalfingerprint', f.id, { crdr_status: STATUS_VALUES[next] } as any)
      .then(() => {
        const cached = winAny[CACHE_KEY] as Bundle | undefined;
        if (cached) cached.fingerprints.forEach((c) => { if (c.id === f.id) c.status = next; });
        setInFlight((s) => ({ ...s, [f.id]: false }));
        setAnnouncement(STATUS_LABELS[next] + ': ' + label + '. ' + effectText + ' Takes effect at the next match run.');
      })
      .catch((err: unknown) => {
        setStatuses((s) => ({ ...s, [f.id]: previous }));
        setInFlight((s) => ({ ...s, [f.id]: false }));
        setWriteError(reportPageError(PAGE_NAME, 'setFingerprintStatus', undefined, err, 'write'));
        setAnnouncement('The change to ' + label + ' was not saved.');
      });
  }

  function signalOpenCount(f: Fingerprint): number {
    const list = bundle && f.signalId ? bundle.exposuresBySignal[f.signalId] || [] : [];
    return list.filter((e) => OPEN_EXPOSURE_STATUSES.indexOf(e.status) >= 0).length;
  }

  function describe(f: Fingerprint, decision: ReviewDecision): { effect: ReviewEffect; text: string } {
    const effect = previewFor(f, decision);
    return { effect, text: describeEffect(effect, f.group, bundle ? roleOf(bundle.rules, f.facet) : null, signalOpenCount(f)) };
  }

  function decide(f: Fingerprint, decision: ReviewDecision) {
    const { effect, text } = describe(f, decision);
    if (effect.kind === 'closes' || effect.kind === 'widens') {
      setConfirm({ fingerprint: f, decision, effect, text });
      return;
    }
    commit(f, decision, text);
  }

  const decisionsFor = (f: Fingerprint): ReviewDecision[] => {
    const list: ReviewDecision[] = f.status === 'review' ? ['accept', 'reject'] : f.status === 'accepted' ? ['reject'] : ['accept'];
    if (f.status !== 'review' && f.extractedBy === 'llm') list.push('review');
    return list;
  };

  const decisionLabel: Record<ReviewDecision, string> = { accept: 'Accept', reject: 'Reject', review: 'Back to review' };
  const decisionIcon: Record<ReviewDecision, JSX.Element> = { accept: <CheckmarkRegular />, reject: <DismissRegular />, review: <ArrowUndoRegular /> };

  if (!dataReady) {
    return (
      <div className={styles.root} ref={setContainer}>
        <Spinner label={'Connecting\u2026'} />
      </div>
    );
  }

  return (
    <div className={styles.root} ref={setContainer}>
      <div className={styles.header}>
        <Title2 as="h1" className={styles.headerTitle}>Fingerprint review</Title2>
        <Button icon={<ArrowClockwiseRegular />} onClick={reload} disabled={loading}>Refresh</Button>
      </div>
      <Text className={styles.muted}>
        What each signal touches, in the shared vocabulary. Facets in a group must all match; any group can match.
        Changes take effect at the next daily match run (06:00 UTC).
      </Text>
      <Text role="status" aria-live="polite" className={styles.srOnly}>{announcement}</Text>
      <PageErrorBar error={error} />
      <PageErrorBar error={writeError} />
      <PageErrorBar error={navError} />

      {loading && <Spinner label={'Loading fingerprints\u2026'} />}

      {bundle && (
        <>
          <div className={styles.counts}>
            <Badge appearance="tint" color={counts.review > 0 ? 'warning' : 'informative'}>To review: {counts.review}</Badge>
            <Badge appearance="tint" color="success">Accepted: {counts.accepted} (LLM {counts.acceptedLlm}, manual {counts.acceptedManual})</Badge>
            <Badge appearance="tint" color="danger">Rejected: {counts.rejected}</Badge>
            <Caption1 className={styles.muted}>
              Confidence threshold {bundle.threshold.toFixed(2)}{bundle.thresholdIsDefault ? ' (default)' : ''}
            </Caption1>
          </div>

          <div className={styles.filters}>
            <TabList selectedValue={tab} onTabSelect={(_, d) => setTab(d.value as StatusTab)} aria-label="Fingerprint status">
              <Tab value="review">To review ({counts.review})</Tab>
              <Tab value="accepted">Accepted ({counts.accepted})</Tab>
              <Tab value="rejected">Rejected ({counts.rejected})</Tab>
            </TabList>
            <div className={styles.field}>
              <Label htmlFor="fr-extractedby">Extracted by</Label>
              <Select id="fr-extractedby" value={extractedBy} onChange={(_, d) => setExtractedBy(d.value)}>
                <option value="">All</option>
                <option value="llm">LLM</option>
                <option value="manual">Manual</option>
                <option value="rule">Rule</option>
              </Select>
            </div>
          </div>

          {visibleCount === 0 && (
            <Card className={styles.empty}>
              <Subtitle2 as="h2">{tab === 'review' ? 'Nothing to review.' : 'No fingerprints match these filters.'}</Subtitle2>
              {tab === 'review' && (
                <>
                  <Text>No fingerprint is below the confidence threshold. You can still check what the LLM accepted.</Text>
                  {counts.acceptedLlm > 0 && (
                    <Button appearance="primary" onClick={() => { setTab('accepted'); setExtractedBy('llm'); }}>
                      Check accepted LLM fingerprints ({counts.acceptedLlm})
                    </Button>
                  )}
                </>
              )}
              {tab !== 'review' && extractedBy && <Button onClick={() => setExtractedBy('')}>Show all extraction methods</Button>}
            </Card>
          )}

          {sections.map((s) => (
            <Card key={s.signalId || 'none'} className={styles.signal}>
              <div className={styles.signalHead}>
                {s.signalId ? (
                  <Link as="button" onClick={() => openSignalForm(s.signalId, setNavError)}>
                    <Subtitle2 as="h2">{s.info ? s.info.code : 'Signal'}</Subtitle2>
                  </Link>
                ) : (
                  <Subtitle2 as="h2">No signal</Subtitle2>
                )}
                {s.info && <Text>{s.info.title}</Text>}
                {s.signalId && <OpenRegular aria-hidden="true" />}
              </div>
              {s.groups.map((g) => (
                <section key={g.group} className={styles.group} aria-label={'Group ' + g.group}>
                  <div className={styles.groupHead}>
                    <Text weight="semibold">Group {g.group}</Text>
                    <Caption1 className={styles.muted}>All of its accepted facets must match; another group can match instead.</Caption1>
                  </div>
                  {g.rows.map((f) => {
                    const role = roleOf(bundle.rules, f.facet);
                    const below = f.confidence !== null && f.confidence < bundle.threshold;
                    const audit = bundle.audit ? bundle.audit[f.id] : undefined;
                    const busy = !!inFlight[f.id];
                    const vocabularyMiss = !bundle.vocabulary.some((v) => v.facet === f.facet && v.value.trim().toLowerCase() === f.value.trim().toLowerCase());
                    return (
                      <div key={f.id} className={styles.row}>
                        <div className={styles.rowTop}>
                          <Text className={styles.facetValue}>{(FACET_LABELS[f.facet] || 'Facet') + ': ' + f.value}</Text>
                          <Badge appearance="outline" color="informative">{role ? ROLE_LABELS[role] : 'no active rule'}</Badge>
                          <Badge appearance="tint" color={f.status === 'accepted' ? 'success' : f.status === 'rejected' ? 'danger' : 'warning'}>{STATUS_LABELS[f.status]}</Badge>
                          <Caption1>{EXTRACTED_LABELS[f.extractedBy] || 'Unknown'}{f.confidence !== null ? ', confidence ' + f.confidence.toFixed(2) : ''}</Caption1>
                          {below && <Badge appearance="filled" color="warning">Below threshold</Badge>}
                        </div>
                        {f.reason && <Text className={styles.reason}>{f.reason}</Text>}
                        {vocabularyMiss && (
                          <Text className={styles.warning}><WarningRegular aria-hidden="true" /> Not in the vocabulary, so it can&rsquo;t match any asset.</Text>
                        )}
                        {audit && <Caption1 className={styles.muted}>Last changed by {audit.by || 'unknown'}{audit.on ? ' on ' + audit.on : ''}</Caption1>}
                        <div className={styles.actions}>
                          {decisionsFor(f).map((d) => (
                            <Button
                              key={d}
                              icon={decisionIcon[d]}
                              appearance={d === 'accept' ? 'primary' : 'secondary'}
                              disabled={busy}
                              aria-describedby={'fr-' + f.id + '-' + d}
                              onClick={() => decide(f, d)}
                            >
                              {decisionLabel[d]}
                            </Button>
                          ))}
                          {busy && <Spinner size="tiny" label={'Saving\u2026'} />}
                        </div>
                        {decisionsFor(f).map((d) => (
                          <Caption1 key={d} id={'fr-' + f.id + '-' + d} className={styles.preview}>
                            <strong>{decisionLabel[d]}:</strong> {describe(f, d).text}
                          </Caption1>
                        ))}
                      </div>
                    );
                  })}
                </section>
              ))}
            </Card>
          ))}
        </>
      )}

      <Dialog open={!!confirm} onOpenChange={(_, d) => { if (!d.open) setConfirm(null); }} modalType="non-modal">
        <DialogSurface mountNode={mountNode}>
          <DialogBody>
            <DialogTitle>
              {confirm ? decisionLabel[confirm.decision] + ' ' + (FACET_LABELS[confirm.fingerprint.facet] || '') + ': ' + confirm.fingerprint.value + '?' : ''}
            </DialogTitle>
            <DialogContent>
              <Text>{confirm ? confirm.text : ''}</Text>
              <br />
              <Caption1 className={styles.muted}>Exposures change at the next daily match run (06:00 UTC), not straight away.</Caption1>
            </DialogContent>
            <DialogActions>
              <Button
                appearance="primary"
                onClick={() => {
                  if (confirm) commit(confirm.fingerprint, confirm.decision, confirm.text);
                  setConfirm(null);
                }}
              >
                {confirm ? decisionLabel[confirm.decision] : 'Confirm'}
              </Button>
              <Button onClick={() => setConfirm(null)}>Cancel</Button>
            </DialogActions>
          </DialogBody>
        </DialogSurface>
      </Dialog>
    </div>
  );
}

const GeneratedComponent = (props: GeneratedComponentProps) => (
  <PageErrorBoundary>
    <PageBody {...props} />
  </PageErrorBoundary>
);

export default GeneratedComponent;

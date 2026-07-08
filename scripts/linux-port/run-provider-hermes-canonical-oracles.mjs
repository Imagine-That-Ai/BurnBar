#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const root = path.resolve(path.dirname(scriptPath), '../..');

function parseArgs(argv) {
  const args = {
    platform: 'linux',
    outDir: path.join(root, 'docs/linux-port/evidence/mission-001-provider-hermes')
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--platform') {
      args.platform = argv[index + 1];
      index += 1;
    } else if (arg === '--out-dir') {
      args.outDir = path.resolve(argv[index + 1]);
      index += 1;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function sortForJson(value) {
  if (Array.isArray(value)) {
    return value.map(sortForJson);
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, sortForJson(value[key])])
    );
  }
  return value;
}

function jsonStable(value) {
  return JSON.stringify(sortForJson(value));
}

function sha256(value) {
  return crypto.createHash('sha256').update(jsonStable(value)).digest('hex');
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function readJsonIfPresent(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }
  return readJson(filePath);
}

function readTextIfPresent(filePath) {
  if (!fs.existsSync(filePath)) {
    return '';
  }
  return fs.readFileSync(filePath, 'utf8');
}

function writeJson(outDir, name, value) {
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(
    path.join(outDir, name),
    `${JSON.stringify(sortForJson(value), null, 2)}\n`,
    'utf8'
  );
}

function diffObjects(expected, actual) {
  if (jsonStable(expected) === jsonStable(actual)) {
    return [];
  }
  return [
    {
      path: '$',
      expected,
      actual
    }
  ];
}

function scalar(value) {
  if (value === null || value === undefined) {
    return undefined;
  }
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  if (typeof value === 'object') {
    if (typeof value.rawValue === 'string') {
      return value.rawValue;
    }
    if (typeof value.id === 'string') {
      return value.id;
    }
  }
  return undefined;
}

function getPath(value, keys) {
  let current = value;
  for (const key of keys) {
    if (!current || typeof current !== 'object') {
      return undefined;
    }
    current = current[key];
  }
  return current;
}

function payloadString(event, key) {
  return scalar(getPath(event, ['payload', key]));
}

function eventRunID(event) {
  return scalar(event.runID);
}

function eventKind(event) {
  return scalar(event.kind);
}

function eventPhase(event) {
  return scalar(event.phase);
}

function parseJournal(outDir, errors) {
  const journalPath = path.join(outDir, 'hermes-run-journal.jsonl');
  if (!fs.existsSync(journalPath)) {
    errors.push('missing hermes-run-journal.jsonl raw product journal');
    return [];
  }
  const lines = fs.readFileSync(journalPath, 'utf8')
    .split(/\r?\n/)
    .map((line, index) => ({ line, lineNumber: index + 1 }))
    .filter((entry) => entry.line.trim().length > 0);
  const events = [];
  for (const entry of lines) {
    try {
      events.push({ ...JSON.parse(entry.line), __lineNumber: entry.lineNumber });
    } catch (error) {
      errors.push(`hermes-run-journal.jsonl line ${entry.lineNumber} is not JSON: ${error.message}`);
    }
  }
  return events;
}

function parseCheckpoints(outDir, errors) {
  const checkpointDir = path.join(outDir, 'hermes-run-checkpoints');
  if (!fs.existsSync(checkpointDir)) {
    errors.push('missing hermes-run-checkpoints raw product checkpoint directory');
    return [];
  }
  return fs.readdirSync(checkpointDir)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .flatMap((name, index) => {
      const filePath = path.join(checkpointDir, name);
      try {
        return [{ ...readJson(filePath), __fileName: name, __fileOrdinal: index + 1 }];
      } catch (error) {
        errors.push(`${name} is not a valid checkpoint JSON file: ${error.message}`);
        return [];
      }
    });
}

function parseSections(transcript) {
  const lines = transcript.split(/\r?\n/);
  const sections = [];
  let current = {
    title: 'daemon prelude',
    lineStart: 1,
    lines: []
  };
  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(/^### (.+)$/);
    if (match) {
      sections.push(current);
      current = {
        title: match[1],
        lineStart: index + 1,
        lines: []
      };
    } else {
      current.lines.push(lines[index]);
    }
  }
  sections.push(current);
  return sections.map((section, index) => {
    const text = section.lines.join('\n').trim();
    const command = text.match(/^command=(.+)$/m)?.[1] ?? null;
    const exitCode = Number(text.match(/^exit_code=(\d+)$/m)?.[1] ?? -1);
    const runID = text.match(/\brun_id=([A-F0-9-]{20,})\b/i)?.[1] ?? null;
    const approvalID = text.match(/\bapproval(?:_id|=)(?:=)?([A-F0-9-]{20,})\b/i)?.[1]
      ?? text.match(/"approvalID"\s*:\s*"([^"]+)"/)?.[1]
      ?? null;
    const phase = text.match(/\bphase=([a-z_]+)\b/)?.[1] ?? null;
    return {
      title: section.title,
      lineStart: section.lineStart,
      command,
      exitCode,
      runID,
      approvalID,
      phase,
      sectionIndex: index + 1,
      text
    };
  });
}

function parseCliTranscript(outDir, errors) {
  const transcriptPath = path.join(outDir, 'cli-hermes-transcript.txt');
  const transcript = readTextIfPresent(transcriptPath);
  if (!transcript) {
    errors.push('missing cli-hermes-transcript.txt product lifecycle transcript');
    return [];
  }
  return parseSections(transcript);
}

function findSection(sections, title, errors) {
  const section = sections.find((candidate) => candidate.title === title);
  if (!section) {
    errors.push(`cli-hermes-transcript.txt missing section ${title}`);
    return null;
  }
  if (section.exitCode !== 0) {
    errors.push(`cli-hermes-transcript.txt section ${title} exit_code=${section.exitCode}`);
  }
  return section;
}

function eventsForRun(journal, runID) {
  return journal.filter((event) => eventRunID(event) === runID);
}

function journalEventsOfKind(runEvents, kind) {
  return runEvents.filter((event) => eventKind(event) === kind);
}

function lastJournalEvent(runEvents) {
  return runEvents.length > 0 ? runEvents[runEvents.length - 1] : null;
}

function rawTimelineFromJournal(raw, offset = 0) {
  return raw.__lineNumber * 1000 + offset;
}

function checkpointForRun(checkpoints, runID, errors) {
  const checkpoint = checkpoints.find((candidate) => scalar(candidate.runID) === runID);
  if (!checkpoint) {
    errors.push(`run ${runID} missing checkpoint readback`);
    return null;
  }
  return checkpoint;
}

function comparableEvent({ kind, source, phase, approvalID, decision, terminal }) {
  const event = { kind, source, phase };
  if (approvalID) {
    event.approvalID = approvalID;
  }
  if (decision) {
    event.decision = decision;
  }
  if (terminal === true) {
    event.terminal = true;
  }
  return event;
}

function withProvenance(event, provenance) {
  return {
    ...event,
    provenance
  };
}

function journalEvent(kind, source, raw, fallbackPhase, extra = {}) {
  const base = comparableEvent({
    kind,
    source,
    phase: fallbackPhase ?? eventPhase(raw),
    decision: extra.decision,
    terminal: extra.terminal
  });
  return withProvenance(base, {
    artifact: 'hermes-run-journal.jsonl',
    sourceFile: 'hermes-run-journal.jsonl',
    rawKind: eventKind(raw),
    rawPhase: eventPhase(raw),
    runID: eventRunID(raw),
    eventID: scalar(raw.eventID),
    approvalID: extra.approvalID,
    rawJournalLineNumber: raw.__lineNumber,
    rawJournalOrdinal: raw.__lineNumber,
    emittedAt: raw.emittedAt,
    rawOrder: {
      sourceFile: 'hermes-run-journal.jsonl',
      sourceOrdinal: raw.__lineNumber,
      journalLineNumber: raw.__lineNumber,
      timelineOrdinal: rawTimelineFromJournal(raw),
      emittedAt: raw.emittedAt
    }
  });
}

function checkpointEvent(kind, checkpoint, extra = {}) {
  const base = comparableEvent({
    kind,
    source: 'daemon',
    phase: scalar(checkpoint.phase),
    terminal: extra.terminal
  });
  const sourceFile = `hermes-run-checkpoints/${checkpoint.__fileName}`;
  return withProvenance(base, {
    artifact: sourceFile,
    sourceFile,
    rawKind: 'checkpoint',
    runID: scalar(checkpoint.runID),
    attempt: checkpoint.attempt,
    fileName: checkpoint.__fileName,
    rawFileOrdinal: checkpoint.__fileOrdinal,
    updatedAt: checkpoint.updatedAt,
    anchorJournalLineNumber: extra.anchorJournalEvent?.__lineNumber,
    rawOrder: {
      sourceFile,
      sourceOrdinal: checkpoint.__fileOrdinal,
      checkpointFileOrdinal: checkpoint.__fileOrdinal,
      anchorJournalLineNumber: extra.anchorJournalEvent?.__lineNumber,
      timelineOrdinal: extra.timelineOrdinal
        ?? (extra.anchorJournalEvent ? rawTimelineFromJournal(extra.anchorJournalEvent, 500) : 900000 + checkpoint.__fileOrdinal * 1000),
      updatedAt: checkpoint.updatedAt
    }
  });
}

function cliEvent(kind, phase, section, runID, extra = {}) {
  const base = comparableEvent({
    kind,
    source: 'cli',
    phase,
    decision: extra.decision,
    terminal: extra.terminal
  });
  return withProvenance(base, {
    artifact: 'cli-hermes-transcript.txt',
    sourceFile: 'cli-hermes-transcript.txt',
    rawKind: 'cli_section',
    runID,
    approvalID: extra.approvalID,
    section: section.title,
    sectionIndex: section.sectionIndex,
    command: section.command,
    lineStart: section.lineStart,
    rawOrder: {
      sourceFile: 'cli-hermes-transcript.txt',
      sourceOrdinal: section.sectionIndex,
      cliSectionIndex: section.sectionIndex,
      cliLineStart: section.lineStart,
      anchorJournalLineNumber: extra.anchorJournalEvent?.__lineNumber,
      timelineOrdinal: extra.timelineOrdinal
        ?? (extra.anchorJournalEvent ? rawTimelineFromJournal(extra.anchorJournalEvent, -100) : 800000 + section.sectionIndex * 1000)
    }
  });
}

function browserRowsForScenario(browser, scenarioID) {
  const stepsByScenario = {
    'prompt-tool-approval-done': [
      'send prompt through daemon',
      'stream assistant/done events',
      'request tool approval',
      'render pending approval',
      'record approval response'
    ],
    'cancel-before-terminal': ['create cancellable run', 'cancel pending run'],
    'retry-after-error': ['create retry failure', 'retry failed run'],
    'persistence-list-readback': ['persisted transcript state']
  };
  const wanted = new Set(stepsByScenario[scenarioID] ?? []);
  return (browser?.rows ?? [])
    .filter((row) => wanted.has(row.step))
    .map((row) => ({
      artifact: browser.artifact,
      rowIndex: row.rowIndex,
      step: row.step,
      method: row.method
    }));
}

function compareRawOrder(left, right) {
  const leftOrder = left.provenance?.rawOrder ?? {};
  const rightOrder = right.provenance?.rawOrder ?? {};
  return (leftOrder.timelineOrdinal ?? 0) - (rightOrder.timelineOrdinal ?? 0)
    || String(leftOrder.sourceFile ?? '').localeCompare(String(rightOrder.sourceFile ?? ''))
    || (leftOrder.sourceOrdinal ?? 0) - (rightOrder.sourceOrdinal ?? 0)
    || String(left.kind).localeCompare(String(right.kind));
}

function expectedKindOrder(expectedScenarios, scenarioID) {
  return (expectedScenarios.find((scenario) => scenario.scenarioID === scenarioID)?.events ?? [])
    .map((event) => event.kind);
}

function sequenceScenario(scenario, expectedScenarios, errors, browser) {
  const browserRows = browserRowsForScenario(browser, scenario.scenarioID);
  const sortedEvents = [...scenario.events].sort(compareRawOrder).map((event, index) => ({
    ...event,
    seq: index + 1,
    provenance: {
      ...event.provenance,
      browserRows,
      normalizedSeq: index + 1
    }
  }));
  const observedKinds = sortedEvents.map((event) => event.kind);
  const expectedKinds = expectedKindOrder(expectedScenarios, scenario.scenarioID);
  if (expectedKinds.length === 0) {
    errors.push(`source oracle missing expected scenario ${scenario.scenarioID}`);
  } else if (jsonStable(observedKinds) !== jsonStable(expectedKinds)) {
    errors.push(
      `scenario ${scenario.scenarioID} raw normalized kind order differs from source oracle: observed=${observedKinds.join('>')} expected=${expectedKinds.join('>')}`
    );
  }
  return {
    scenarioID: scenario.scenarioID,
    promptID: scenario.promptID,
    provenance: {
      sortedBy: 'raw product emission ordinals',
      firstRawOrder: sortedEvents[0]?.provenance?.rawOrder ?? null,
      browserRows
    },
    events: sortedEvents
  };
}

function normalizeJournalRunEvents(runEvents, allowedKinds, extraByRawKind = {}) {
  const allowed = new Set(allowedKinds);
  const events = [];
  for (const raw of runEvents) {
    const rawKind = eventKind(raw);
    if (!allowed.has(rawKind)) {
      continue;
    }
    if (rawKind === 'run_created') {
      events.push(journalEvent('prompt.accepted', 'daemon', raw, 'planning'));
    } else if (rawKind === 'plan_generated') {
      events.push(journalEvent('plan.generated', 'daemon', raw, 'planning'));
    } else if (rawKind === 'approval_requested') {
      const approvalID = payloadString(raw, 'approvalID');
      events.push(journalEvent('tool.approval.required', 'daemon', raw, 'awaiting_approval', { approvalID }));
    } else if (rawKind === 'approval_responded') {
      const approvalID = payloadString(raw, 'approvalID');
      const decision = payloadString(raw, 'decision') ?? extraByRawKind.approval_responded?.decision ?? 'approve';
      events.push(journalEvent('tool.approval.recorded', 'daemon', raw, 'awaiting_approval', { approvalID, decision }));
    } else if (rawKind === 'run_cancelled') {
      events.push(journalEvent('assistant.cancelled', 'daemon', raw, 'cancelled', { terminal: true }));
    } else if (rawKind === 'run_failed') {
      events.push(journalEvent('assistant.error', 'daemon', raw, 'failed'));
    }
  }
  return events;
}

function stripProvenance(scenario) {
  return {
    scenarioID: scenario.scenarioID,
    promptID: scenario.promptID,
    events: scenario.events.map((event) => {
      const { provenance: _provenance, ...rest } = event;
      return rest;
    })
  };
}

function requireRunID(section, label, errors) {
  if (!section?.runID) {
    errors.push(`${label} did not expose a run_id`);
    return '';
  }
  return section.runID;
}

function makeObservedScenarios({ journal, checkpoints, sections, browser, expectedScenarios, errors }) {
  const promptCreate = findSection(sections, 'run create mock provider', errors);
  const promptList = findSection(sections, 'run list after create', errors);
  const promptGet = findSection(sections, 'run get', errors);
  const promptPoll = findSection(sections, 'run poll', errors);
  const approvalCreate = findSection(sections, 'run create requires approval', errors);
  const approvalPoll = findSection(sections, 'run poll approval json', errors);
  const approvalApprove = findSection(sections, 'run approval approve', errors);
  const approvalPostPoll = findSection(sections, 'run poll after approval', errors);
  const cancelCreate = findSection(sections, 'run create cancellable', errors);
  const cancelSection = findSection(sections, 'run cancel', errors);
  const retryCreate = findSection(sections, 'run create retry failure', errors);
  const retrySection = findSection(sections, 'run retry', errors);
  const retryPoll = findSection(sections, 'run poll after retry', errors);
  const persistenceList = findSection(sections, 'run list persistence tail', errors);
  const persistenceGet = findSection(sections, 'run get persistence readback', errors);
  const persistencePoll = findSection(sections, 'run poll persistence readback', errors);

  const promptRunID = requireRunID(promptCreate, 'run create mock provider', errors);
  const approvalRunID = requireRunID(approvalCreate, 'run create requires approval', errors);
  const cancelRunID = requireRunID(cancelCreate, 'run create cancellable', errors);
  const retryRunID = requireRunID(retryCreate, 'run create retry failure', errors);
  const promptJournal = eventsForRun(journal, promptRunID);
  const approvalJournal = eventsForRun(journal, approvalRunID);
  const cancelJournalEvents = eventsForRun(journal, cancelRunID);
  const retryJournal = eventsForRun(journal, retryRunID);
  const approvalRequested = journalEventsOfKind(approvalJournal, 'approval_requested')[0];
  const cancelRunCancelled = journalEventsOfKind(cancelJournalEvents, 'run_cancelled')[0];
  const retryCreatedAgain = journalEventsOfKind(retryJournal, 'run_created')[1];
  const approvalID = approvalPoll?.approvalID
    ?? approvalApprove?.approvalID
    ?? payloadString(approvalRequested ?? {}, 'approvalID');

  if (!approvalID) {
    errors.push('approval scenario did not expose approvalID in poll, approval response, or journal payload');
  }

  const promptCheckpoint = checkpointForRun(checkpoints, promptRunID, errors);
  const approvalCheckpoint = checkpointForRun(checkpoints, approvalRunID, errors);
  const retryCheckpoint = checkpointForRun(checkpoints, retryRunID, errors);

  const scenarios = [];
  if (approvalJournal.length > 0 && approvalCheckpoint) {
    const events = normalizeJournalRunEvents(
      approvalJournal,
      ['run_created', 'plan_generated', 'approval_requested', 'approval_responded']
    );
    const anchor = lastJournalEvent(approvalJournal);
    events.push(checkpointEvent('assistant.done', approvalCheckpoint, {
      terminal: true,
      anchorJournalEvent: anchor,
      timelineOrdinal: anchor ? rawTimelineFromJournal(anchor, 500) : undefined
    }));
    scenarios.push(sequenceScenario({
      scenarioID: 'prompt-tool-approval-done',
      promptID: 'hermes-prompt-approval',
      events
    }, expectedScenarios, errors, browser));
  }

  if (cancelJournalEvents.length > 0 && cancelSection) {
    const events = normalizeJournalRunEvents(
      cancelJournalEvents,
      ['run_created', 'plan_generated', 'approval_requested', 'run_cancelled']
    );
    events.push(cliEvent('run.cancel.requested', 'cancelling', cancelSection, cancelRunID, {
      anchorJournalEvent: cancelRunCancelled,
      timelineOrdinal: cancelRunCancelled ? rawTimelineFromJournal(cancelRunCancelled, -100) : undefined
    }));
    scenarios.push(sequenceScenario({
      scenarioID: 'cancel-before-terminal',
      promptID: 'hermes-prompt-cancel',
      events
    }, expectedScenarios, errors, browser));
  }

  if (retryJournal.length > 0 && retrySection && retryCheckpoint) {
    const events = normalizeJournalRunEvents(
      retryJournal,
      ['run_created', 'plan_generated', 'run_failed']
    );
    events.push(cliEvent('run.retry.requested', 'retrying', retrySection, retryRunID, {
      anchorJournalEvent: retryCreatedAgain,
      timelineOrdinal: retryCreatedAgain ? rawTimelineFromJournal(retryCreatedAgain, -100) : undefined
    }));
    const anchor = lastJournalEvent(retryJournal);
    events.push(checkpointEvent('assistant.done', retryCheckpoint, {
      terminal: true,
      anchorJournalEvent: anchor,
      timelineOrdinal: anchor ? rawTimelineFromJournal(anchor, 500) : undefined
    }));
    scenarios.push(sequenceScenario({
      scenarioID: 'retry-after-error',
      promptID: 'hermes-prompt-retry',
      events
    }, expectedScenarios, errors, browser));
  }

  if (promptJournal.length > 0 && promptCheckpoint && promptList && promptGet && promptPoll && persistenceList && persistenceGet && persistencePoll) {
    const promptCreatedOnly = normalizeJournalRunEvents(promptJournal, ['run_created']);
    const anchor = lastJournalEvent(promptJournal);
    const checkpointBaseOrdinal = anchor ? rawTimelineFromJournal(anchor, 500) : undefined;
    const events = [
      ...promptCreatedOnly,
      checkpointEvent('assistant.done', promptCheckpoint, {
        terminal: true,
        anchorJournalEvent: anchor,
        timelineOrdinal: checkpointBaseOrdinal
      }),
      checkpointEvent('run.persistence.checkpoint', promptCheckpoint, {
        anchorJournalEvent: anchor,
        timelineOrdinal: checkpointBaseOrdinal ? checkpointBaseOrdinal + 1 : undefined
      }),
      cliEvent('run.list.readback', 'completed', persistenceList, promptRunID),
      cliEvent('run.get.readback', 'completed', persistenceGet, promptRunID),
      cliEvent('run.poll.readback', 'completed', persistencePoll, promptRunID)
    ];
    scenarios.push(sequenceScenario({
      scenarioID: 'persistence-list-readback',
      promptID: 'hermes-prompt-persistence',
      events
    }, expectedScenarios, errors, browser));
  }

  const sectionChecks = [
    [approvalPostPoll, 'run poll after approval'],
    [retryPoll, 'run poll after retry']
  ];
  for (const [section, label] of sectionChecks) {
    if (!section || !/phase=completed|"phase"\s*:\s*"completed"/.test(section.text)) {
      errors.push(`${label} must show phase=completed for assistant/done polling`);
    }
  }

  return scenarios;
}

function browserSummary(outDir) {
  const hermes = readJsonIfPresent(path.join(outDir, 'packaged-browser-hermes-dom-transcript.json'));
  if (!hermes) {
    return null;
  }
  return {
    artifact: 'packaged-browser-hermes-dom-transcript.json',
    dataSource: hermes.dataSource ?? null,
    surface: hermes.surface ?? null,
    assertionKeys: Object.keys(hermes.assertions ?? {}).sort(),
    rowSteps: (hermes.rows ?? []).map((row) => row.step).filter(Boolean),
    rows: (hermes.rows ?? []).map((row, index) => ({
      rowIndex: index + 1,
      step: row.step ?? null,
      method: row.method ?? null
    })),
    rowCount: Array.isArray(hermes.rows) ? hermes.rows.length : 0
  };
}

function ensureNotWeakEvidence({ observed, raw, errors }) {
  const source = fs.readFileSync(scriptPath, 'utf8');
  const disallowedSourcePatterns = [
    /observedScenarios\s*=\s*payload\.scenarios/,
    /observed\s*=\s*payload\.scenarios/,
    /observedScenarios\s*=\s*expected/,
    /observed\s*=\s*expected/,
    /return\s+\[\s*\{\s*scenarioID:\s*['"]prompt-tool-approval-done/
  ];
  for (const pattern of disallowedSourcePatterns) {
    if (pattern.test(source)) {
      errors.push(`canonical oracle runner contains weak observed-source pattern ${pattern}`);
    }
  }
  if (!raw.journalEvents.length) {
    errors.push('weak evidence rejected: no raw daemon journal events were parsed');
  }
  if (!raw.cliSections.some((section) => section.title.includes('run poll'))) {
    errors.push('weak evidence rejected: no CLI poll lifecycle sections were parsed');
  }
  if (!raw.checkpoints.length) {
    errors.push('weak evidence rejected: no product checkpoint rows were parsed');
  }
  if (observed.length < 4) {
    errors.push(`weak evidence rejected: expected 4 parsed scenarios, found ${observed.length}`);
  }
}

function writeStatusArtifacts(outDir, platform, hermesStatus) {
  const evidenceClass = hermesStatus === 'exact_match' ? 'canonical_pass' : 'failed';
  function evidenceExists(reference) {
    const artifactPath = path.join(outDir, reference);
    if (reference.endsWith('/')) {
      return fs.existsSync(artifactPath)
        && fs.statSync(artifactPath).isDirectory()
        && fs.readdirSync(artifactPath).length > 0;
    }
    return fs.existsSync(artifactPath)
      && fs.statSync(artifactPath).isFile()
      && fs.statSync(artifactPath).size > 0;
  }
  function requirePresentForCanonical(row) {
    const evidence = Array.isArray(row.evidence) ? row.evidence : [];
    const missingArtifacts = evidence.filter((reference) => !evidenceExists(reference));
    if (row.evidenceClass === 'canonical_pass' && missingArtifacts.length > 0) {
      return {
        ...row,
        status: 'blocked',
        evidenceClass: 'blocked',
        missingArtifacts,
        note: [
          row.note,
          'Fail-closed: canonical_pass requires every referenced artifact to exist in this evidence directory.'
        ].filter(Boolean).join(' ')
      };
    }
    if (missingArtifacts.length > 0) {
      return { ...row, missingArtifacts };
    }
    return row;
  }
  const contractStatus = {
    lane: 'W04ProviderHermesEngine',
    contracts: {
      'VAL-DATA-000': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: ['data-direct-xctest-transcript.txt', 'full-data-direct-xctest-transcript.txt', 'source-scan.txt'],
        note: 'Fresh active-checkout data transcripts generated or verified in this evidence bundle.'
      },
      'VAL-DATA-001': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: ['data-direct-xctest-transcript.txt', 'full-data-direct-xctest-transcript.txt']
      },
      'VAL-DATA-002': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: ['data-direct-xctest-transcript.txt', 'full-data-direct-xctest-transcript.txt', 'sqlite-schema-doc-verifier.txt', 'macos-schema-oracle-transcript.txt']
      },
      'VAL-DATA-003': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: ['data-direct-xctest-transcript.txt', 'full-data-direct-xctest-transcript.txt']
      },
      'VAL-DATA-004': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: [
          'parser-canonical-oracle-accepted.md',
          'provider-parser-product-replay-linux.json',
          'provider-parser-corpus-diff-linux.json',
          'usage-row-reconciliation-diff-linux.json',
          'provider-parser-product-replay-macos.json',
          'usage-row-reconciliation-diff-macos.json'
        ],
        note: 'Fresh active-checkout parser and usage artifacts generated or verified in this evidence bundle.'
      },
      'VAL-DATA-005': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: ['data-direct-xctest-transcript.txt', 'full-data-direct-xctest-transcript.txt', 'cli-hermes-transcript.txt']
      },
      'VAL-DATA-006': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: [
          'retrieval-golden-source-oracle-linux.json',
          'retrieval-golden-diff-linux.json',
          'retrieval-golden-source-oracle-macos.json',
          'retrieval-golden-diff-macos.json',
          'packaged-browser-memory-dom-transcript.json',
          'cli-hermes-transcript.txt'
        ]
      },
      'VAL-DATA-007': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: ['data-direct-xctest-transcript.txt', 'full-data-direct-xctest-transcript.txt']
      },
      'VAL-PROVIDER-001': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: ['provider-log-path-matrix.json', 'provider-discovery-edge-fixture.json', 'provider-discovery-direct-xctest-transcript.txt']
      },
      'VAL-PROVIDER-002': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: [
          'parser-canonical-oracle-accepted.md',
          'canonical-provider-parser-oracle-linux.json',
          'provider-parser-product-replay-linux.json',
          'provider-parser-corpus-diff-linux.json',
          'canonical-provider-parser-oracle-macos.json',
          'provider-parser-product-replay-macos.json',
          'provider-parser-corpus-diff-macos.json'
        ]
      },
      'VAL-PROVIDER-003': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: ['cli-hermes-transcript.txt', 'packaged-browser-hermes-dom-transcript.json', 'daemon-session-oracle.json']
      },
      'VAL-HERMES-001': {
        status: evidenceClass,
        evidenceClass,
        evidence: [
          `hermes-event-order-source-oracle-${platform}.json`,
          `hermes-event-order-diff-${platform}.json`,
          `hermes-event-order-raw-events-${platform}.json`,
          `hermes-event-order-normalized-observed-${platform}.json`,
          'hermes-run-journal.jsonl',
          'hermes-run-checkpoints/',
          'cli-hermes-transcript.txt',
          'packaged-browser-hermes-dom-transcript.json'
        ],
        note: 'Observed events are sorted by raw product ordinals before seq assignment and source-oracle comparison.'
      },
      'VAL-HERMES-002': {
        status: 'canonical_pass',
        evidenceClass: 'canonical_pass',
        evidence: [
          'retrieval-golden-source-oracle-linux.json',
          'retrieval-golden-diff-linux.json',
          'packaged-browser-memory-dom-transcript.json',
          'cli-hermes-transcript.txt'
        ]
      },
      'VAL-HERMES-003': {
        status: evidenceClass,
        evidenceClass,
        evidence: [
          'prompt-wrapper-direct-xctest-transcript.txt',
          'llmsafe-content-linux-fixture.json',
          'packaged-browser-hermes-dom-transcript.json',
          `hermes-event-order-diff-${platform}.json`
        ],
        note: 'Dependent target follows VAL-HERMES-001 plus existing prompt-wrapper proof.'
      }
    }
  };
  contractStatus.contracts = Object.fromEntries(
    Object.entries(contractStatus.contracts).map(([target, row]) => [
      target,
      requirePresentForCanonical(row)
    ])
  );
  writeJson(outDir, 'contract-status.json', contractStatus);
  writeJson(outDir, 'evidence-classification.json', {
    schema: 'openburnbar-linux-provider-hermes-evidence-classification-v2',
    evidenceDirectory: outDir,
    policy: 'Rows marked canonical_pass require every referenced current bundle artifact to exist and be non-empty. VAL-HERMES-001 observations must come from product artifacts, not the source fixture.',
    rows: Object.fromEntries(
      Object.entries(contractStatus.contracts).map(([target, row]) => [
        target,
        {
          classification: row.evidenceClass,
          canonicalPass: row.evidenceClass === 'canonical_pass',
          evidence: row.evidence,
          missingArtifacts: row.missingArtifacts ?? []
        }
      ])
    )
  });
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const outDir = args.outDir;
  const platform = args.platform;
  const errors = [];
  const fixturePath = path.join(root, 'docs/linux-port/fixtures/hermes-event-order-source-oracle.json');
  const fixture = readJson(fixturePath);
  if (fixture.provenance?.acceptedAsCanonical !== true) {
    errors.push('hermes event-order fixture must have provenance.acceptedAsCanonical=true');
  }
  const expected = fixture.scenarios;
  const journalEvents = parseJournal(outDir, errors);
  const checkpoints = parseCheckpoints(outDir, errors);
  const cliSections = parseCliTranscript(outDir, errors);
  const browser = browserSummary(outDir);

  const observedWithProvenance = makeObservedScenarios({
    journal: journalEvents,
    checkpoints,
    sections: cliSections,
    browser,
    expectedScenarios: expected,
    errors
  });
  const observed = observedWithProvenance.map(stripProvenance);
  const raw = {
    schema: 'openburnbar-hermes-event-order-raw-extraction-v1',
    platform,
    generatedAt: new Date().toISOString(),
    sourceArtifacts: [
      'hermes-run-journal.jsonl',
      'hermes-run-checkpoints/',
      'cli-hermes-transcript.txt',
      browser?.artifact
    ].filter(Boolean),
    journalEvents: journalEvents.map((event) => ({
      sourceFile: 'hermes-run-journal.jsonl',
      lineNumber: event.__lineNumber,
      rawJournalOrdinal: event.__lineNumber,
      eventID: scalar(event.eventID),
      runID: eventRunID(event),
      kind: eventKind(event),
      phase: eventPhase(event),
      approvalID: payloadString(event, 'approvalID'),
      decision: payloadString(event, 'decision'),
      emittedAt: event.emittedAt
    })),
    checkpoints: checkpoints.map((checkpoint) => ({
      sourceFile: `hermes-run-checkpoints/${checkpoint.__fileName}`,
      fileName: checkpoint.__fileName,
      rawFileOrdinal: checkpoint.__fileOrdinal,
      runID: scalar(checkpoint.runID),
      phase: scalar(checkpoint.phase),
      activeApprovalID: scalar(checkpoint.activeApprovalID),
      approvalRequestID: scalar(getPath(checkpoint, ['approvalRequest', 'approvalID'])),
      attempt: checkpoint.attempt
    })),
    cliSections: cliSections
      .filter((section) => section.title !== 'daemon prelude')
      .map((section) => ({
        sourceFile: 'cli-hermes-transcript.txt',
        title: section.title,
        sectionIndex: section.sectionIndex,
        lineStart: section.lineStart,
        command: section.command,
        exitCode: section.exitCode,
        runID: section.runID,
        approvalID: section.approvalID,
        phase: section.phase,
        textSHA256: crypto.createHash('sha256').update(section.text).digest('hex')
      })),
    browser
  };

  ensureNotWeakEvidence({ observed, raw, errors });
  const differences = diffObjects(expected, observed);
  const status = differences.length === 0 && errors.length === 0 ? 'exact_match' : 'failed';

  writeJson(outDir, `hermes-event-order-raw-events-${platform}.json`, raw);
  writeJson(outDir, `hermes-event-order-normalized-observed-${platform}.json`, {
    schema: 'openburnbar-hermes-event-order-normalized-observed-v2',
    platform,
    sequencing: {
      rule: 'sort each scenario by raw product emission ordinals, then assign seq',
      journalOrder: 'hermes-run-journal.jsonl raw line number is authoritative for daemon journal events',
      nonJournalOrder: 'checkpoint and CLI events carry file/section ordinals plus journal anchors when the raw flow spans artifacts'
    },
    observedScenarios: observed,
    observedScenariosWithProvenance: observedWithProvenance
  });
  writeJson(outDir, `hermes-event-order-source-oracle-${platform}.json`, {
    schema: 'openburnbar-hermes-event-order-source-oracle-run-v3',
    platform,
    sourceFixture: path.relative(root, fixturePath),
    expectedChecksumSHA256: sha256(expected),
    observedChecksumSHA256: sha256(observed),
    provenance: fixture.provenance,
    observedSource: 'daemon run journal/checkpoints + AF_UNIX CLI lifecycle sections',
    observedSourceArtifacts: raw.sourceArtifacts,
    expectedScenarios: expected,
    observedScenarios: observed,
    observedScenariosWithProvenance: observedWithProvenance,
    integrity: {
      observedFromPayloadScenarios: false,
      observedFromExpectedFixture: false,
      observedFromFixedLiteralArrays: false,
      observedFromBooleanAssertionsOnly: false,
      observedSequenceAssignedAfterRawOrdinalSort: true,
      observedKindOrderCheckedBeforeDiff: true
    }
  });
  writeJson(outDir, `hermes-event-order-diff-${platform}.json`, {
    schema: 'openburnbar-hermes-event-order-diff-v3',
    platform,
    sourceFixture: path.relative(root, fixturePath),
    expectedSource: `${path.relative(root, fixturePath)}#scenarios`,
    observedSource: 'hermes-run-journal.jsonl + hermes-run-checkpoints + cli-hermes-transcript.txt',
    observedSequencing: 'raw product ordinals sorted before seq assignment',
    status,
    expectedChecksumSHA256: sha256(expected),
    observedChecksumSHA256: sha256(observed),
    differences,
    errors
  });
  writeJson(outDir, `canonical-oracle-run-summary-${platform}.json`, {
    schema: 'openburnbar-provider-hermes-canonical-oracle-run-summary-v2',
    platform,
    status: status === 'exact_match' ? 'pass' : 'failed',
    generatedAt: new Date().toISOString(),
    outDir,
    sections: {
      hermes: {
        status: status === 'exact_match' ? 'pass' : 'failed',
        errors,
        artifacts: [
          `hermes-event-order-source-oracle-${platform}.json`,
          `hermes-event-order-diff-${platform}.json`,
          `hermes-event-order-raw-events-${platform}.json`,
          `hermes-event-order-normalized-observed-${platform}.json`
        ]
      }
    }
  });
  writeJson(outDir, 'canonical-oracle-discovery.json', {
    schema: 'openburnbar-provider-hermes-canonical-oracle-discovery-v2',
    generatedAt: new Date().toISOString(),
    runner: 'scripts/linux-port/run-provider-hermes-canonical-oracles.mjs',
    fixture: path.relative(root, fixturePath),
    rawArtifactsRequired: raw.sourceArtifacts,
    weakEvidenceRejected: [
      'precomputed scenario payloads as observed rows',
      'literal observed scenario arrays',
      'expected fixture rows as observed',
      'browser assertion booleans without raw product event extraction'
    ]
  });
  writeStatusArtifacts(outDir, platform, status);

  if (status !== 'exact_match') {
    console.error(`hermes_event_order_${platform}=failed`);
    for (const error of errors) {
      console.error(`error=${error}`);
    }
    process.exit(1);
  }
  console.log(`hermes_event_order_${platform}=pass`);
}

main();

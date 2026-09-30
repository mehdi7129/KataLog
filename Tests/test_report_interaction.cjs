/* Pure report interactions; no browser, network, or private log fixtures required. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../Sources/KataLogCore/ReportInteraction.swift'), 'utf8');
const script = source.match(/static\s+let\s+script\s*=\s*#"""([\s\S]*?)"""#/);
assert.ok(script, 'ReportInteraction.swift must expose its static script for browser-free contract tests');
const context = { module: { exports: {} }, console };
vm.runInNewContext(script[1], context, { timeout: 1000, filename: 'report-interaction.js' });
const { selectLogs, statistics, familyCounts, dailyCounts, dayKey, groupCounts, pageWindow } = context.module.exports;
for (const [name, fn] of Object.entries({ selectLogs, statistics, familyCounts, dailyCounts, dayKey, groupCounts })) {
  assert.equal(typeof fn, 'function', `${name} is part of the pure report contract`);
}

function filters(patch = {}) { return { drone: '', family: '', level: '', query: '', day: '', ...patch }; }
function message(index, patch = {}) {
  return { index, id: `m-${index}`, groupKey: 'wifi', text: '[wifi_broadcom] Wifi link lost', title: 'Liaison perdue', level: 'ERROR', family: 'Communication', isAlert: true, ...patch };
}
function log(id, patch = {}) {
  return { id, droneID: 'controller-a', droneName: 'Drone 00042', date: '2026-09-29T12:00:00Z', dateSource: 'GPS UTC', durationSeconds: 60, status: 'ok', failsafeObserved: false, messages: [], ...patch };
}
function plain(value) { return JSON.parse(JSON.stringify(value)); }
function ids(selected) { return plain(selected.map(item => item.log.id)); }

test('reset retains every log, information message, repeated occurrence, and two identities sharing a number', () => {
  const logs = [
    log('one', { messages: [message(0), message(1), message(2, { level: 'INFO', isAlert: false, text: 'Boot complete', groupKey: 'boot', family: 'Système' })] }),
    log('two', { droneID: 'controller-b', messages: [message(0)] }),
    log('empty')
  ];
  const selected = selectLogs(logs, filters());
  const summary = statistics(selected);
  assert.deepEqual(ids(selected), ['one', 'two', 'empty']);
  assert.equal(summary.logCount, 3);
  assert.equal(summary.droneCount, 2);
  assert.equal(summary.messageCount, 4);
  assert.equal(summary.alertMessageCount, 3);
  assert.equal(summary.alertLogCount, 2);
  assert.equal(summary.durationSeconds, 180);
  assert.deepEqual(plain(familyCounts(selected)), [{ name: 'Communication', count: 2 }]);
  assert.equal(logs[0].messages.length, 3, 'Filtering never mutates the source payload');
});

test('combined drone, day, family, level and text filters select the same messages used by statistics', () => {
  const logs = [
    log('match', { messages: [message(0), message(1, { family: 'Batterie', text: 'Battery low' }), message(2, { level: 'WARNING' })] }),
    log('other-day', { date: '2026-09-28', messages: [message(0)] }),
    log('other-drone', { droneID: 'controller-b', messages: [message(0)] }),
    log('no-messages')
  ];
  const selected = selectLogs(logs, filters({ drone: 'controller-a', day: '2026-09-29', family: 'Communication', level: 'ERROR+', query: 'wifi' }));
  assert.deepEqual(ids(selected), ['match']);
  assert.deepEqual(plain(selected[0].messages.map(item => item.index)), [0]);
  assert.equal(statistics(selected).messageCount, 1);
  assert.equal(statistics(selected).alertLogCount, 1);
  assert.equal(selectLogs(logs, filters()).length, 4, 'Reset restores the full snapshot');
  assert.equal(logs[0].messages.length, 3);
});

test('ALERTS follows isAlert including INFO alarms, while numeric level filters follow level ranks', () => {
  const logs = [log('levels', { messages: [
    message(0, { level: 'INFO', text: '[ALARM] Triggered', isAlert: true }),
    message(1, { level: 'INFO', text: 'Ready', isAlert: false }),
    message(2, { level: 'DEBUG', text: 'Debug', isAlert: false }),
    message(3, { level: 'WARNING' }),
    message(4, { level: 'CRITICAL' })
  ] })];
  function indexes(level) { return plain(selectLogs(logs, filters({ level }))[0].messages.map(item => item.index)); }
  assert.deepEqual(indexes('ALERTS'), [0, 3, 4]);
  assert.deepEqual(indexes('ERROR+'), [4]);
  assert.deepEqual(indexes('WARNING+'), [3, 4]);
  assert.deepEqual(indexes('INFO'), [0, 1]);
  assert.deepEqual(indexes('DEBUG'), [2]);
});

test('search can find a named drone without messages, but never invents a match for an active family', () => {
  const logs = [log('empty'), log('other', { droneID: 'controller-b', droneName: 'Drone 999' })];
  assert.deepEqual(ids(selectLogs(logs, filters({ query: '00042' }))), ['empty']);
  assert.deepEqual(ids(selectLogs(logs, filters({ query: '00042', family: 'Communication' }))), []);
  assert.deepEqual(ids(selectLogs(logs, filters({ query: 'absent search' }))), []);
});

test('failsafe without text remains visible in the unfiltered summary, never in unrelated family results', () => {
  const logs = [log('failsafe', { failsafeObserved: true }), log('healthy')];
  const summary = statistics(selectLogs(logs, filters()));
  assert.equal(summary.alertLogCount, 1);
  assert.equal(summary.failsafeLogCount, 1);
  assert.equal(summary.alertMessageCount, 0);
  assert.deepEqual(plain(familyCounts(selectLogs(logs, filters()))), []);
  const familySummary = statistics(selectLogs(logs, filters({ family: 'Communication' })));
  assert.equal(familySummary.alertLogCount, 0);
  assert.equal(familySummary.failsafeLogCount, 0);
});

test('failed logs remain accounted for but add no recorded duration or affected-log count', () => {
  const logs = [
    log('broken', { status: 'error', durationSeconds: 999, failsafeObserved: true, messages: [message(0)] }),
    log('partial', { status: 'partial', durationSeconds: 12, messages: [message(0)] }),
    log('healthy', { durationSeconds: 8 })
  ];
  const selected = selectLogs(logs, filters());
  const summary = statistics(selected);
  assert.equal(summary.logCount, 3);
  assert.equal(summary.failedLogCount, 1);
  assert.equal(summary.partialLogCount, 1);
  assert.equal(summary.durationSeconds, 20);
  assert.equal(summary.alertLogCount, 1);
  assert.deepEqual(plain(familyCounts(selected)), [{ name: 'Communication', count: 1 }]);
  assert.deepEqual(plain(dailyCounts(selected)), [{ day: '2026-09-29', total: 3, alerts: 1 }]);
});

test('calendar days preserve source dates without timezone conversion and separate undated logs', () => {
  assert.equal(dayKey('2026-09-29T00:15:00+14:00'), '2026-09-29');
  assert.equal(dayKey('2026-09-29T23:45:00-11:00'), '2026-09-29');
  assert.equal(dayKey('2026-09-29'), '2026-09-29');
  assert.equal(dayKey(''), 'undated');
  assert.equal(dayKey('Date inconnue'), 'undated');
  const logs = [log('dated', { messages: [message(0)] }), log('unknown', { date: '' })];
  assert.deepEqual(ids(selectLogs(logs, filters({ day: 'undated' }))), ['unknown']);
  const byDay = Object.fromEntries(plain(dailyCounts(selectLogs(logs, filters()))).map(item => [item.day, item]));
  assert.deepEqual(byDay['2026-09-29'], { day: '2026-09-29', total: 1, alerts: 1 });
  assert.deepEqual(byDay.undated, { day: 'undated', total: 1, alerts: 0 });
});

test('custom and unknown families are all preserved with stable alphabetic order and unique log counts', () => {
  const logs = [
    log('one', { messages: [message(0, { family: 'Zèbre' }), message(1, { family: 'Autres' }), message(2, { family: 'Zèbre' })] }),
    log('two', { messages: [message(0, { family: 'Atelier' }), message(1, { family: 'Zèbre' })] })
  ];
  const counts = plain(familyCounts(selectLogs(logs, filters())));
  assert.deepEqual(counts, [{ name: 'Atelier', count: 1 }, { name: 'Autres', count: 1 }, { name: 'Zèbre', count: 2 }]);
  assert.deepEqual(plain(familyCounts(selectLogs([...logs].reverse(), filters()))), counts);
});

test('empty selection has finite zero totals and empty charts', () => {
  const selected = selectLogs([], filters());
  assert.equal(selected.length, 0);
  for (const key of ['logCount', 'droneCount', 'durationSeconds', 'alertLogCount', 'messageCount', 'alertMessageCount', 'failedLogCount', 'partialLogCount', 'failsafeLogCount']) {
    assert.equal(statistics(selected)[key], 0, key);
  }
  assert.deepEqual(plain(familyCounts(selected)), []);
  assert.deepEqual(plain(dailyCounts(selected)), []);
});

test('a captured text selection never restores unrelated failsafes when HTML filters reset', () => {
  const logs = [log('captured', {failsafeObserved:true, selectionIncludesFailsafe:false,
    messages:[message(0,{level:'INFO',isAlert:false})]})];
  const selected = selectLogs(logs,filters());
  assert.equal(statistics(selected).failsafeLogCount,0);
  assert.equal(statistics(selected).alertLogCount,0);
  assert.equal(statistics(selected).messageCount,1);
});

test('occurrence counts per log and group follow the same filtered messages, including normalized space variants', () => {
  const logs = [log('one', {messages:[message(0,{text:'GPS error',title:'GPS error',groupKey:'gps'}),message(1,{text:'GPS  error',title:'GPS error',groupKey:'gps'})]}),
                log('two', {messages:[message(0,{text:'GPS error',title:'GPS error',groupKey:'gps'})]})];
  const all=groupCounts(selectLogs(logs,filters())).get('gps');
  assert.equal(all.messages,3); assert.equal(all.logs.size,2); assert.equal(all.byLog.get('one'),2);
  const selected=selectLogs(logs,filters({query:'GPS  error'}));
  const filtered=groupCounts(selected).get('gps');
  assert.equal(filtered.messages,statistics(selected).messageCount);
  assert.equal(filtered.messages,1); assert.equal(filtered.logs.size,1); assert.equal(filtered.byLog.get('one'),1);
  assert.equal(filtered.byLog.has('two'),false);
  assert.equal(groupCounts(selectLogs(logs,filters())).get('gps').byLog.get('one'),2);
});

test('detail pagination visits every selected occurrence without changing global totals or source strings', () => {
  const attack='</script><img src=x onerror=alert(1)> éè 漢字\u2028\u2029';
  const messages=Array.from({length:251},(_,i)=>message(i,{text:i===150?attack:`record ${i}`}));
  const logs=[log('large',{messages})];
  const selected=selectLogs(logs,filters());
  const visited=[];
  for(let i=0;i<3;i++)visited.push(...pageWindow(selected[0].messages,i).items.map(m=>m.index));
  assert.deepEqual(plain(visited),Array.from({length:251},(_,i)=>i));
  assert.equal(statistics(selected).messageCount,251);
  assert.equal(groupCounts(selected).get('wifi').messages,251);
  assert.equal(messages[150].text,attack);
  assert.equal(pageWindow(selected[0].messages,1).items[50].text,attack);
});

test('detail pages clamp after a filter shrinks the selection and retain explicit total and range', () => {
  const input=Array.from({length:251},(_,i)=>i);
  assert.deepEqual(plain(pageWindow(input,2)),{items:input.slice(200),index:2,start:200,end:251,total:251,hasPrevious:true,hasNext:false});
  const filtered=input.filter(x=>x<3);
  assert.deepEqual(plain(pageWindow(filtered,2)),{items:[0,1,2],index:0,start:0,end:3,total:3,hasPrevious:false,hasNext:false});
  assert.equal(pageWindow(input,-3).index,0);
  assert.equal(pageWindow(input,Infinity).index,0);
  assert.deepEqual(plain(pageWindow([],8).items),[]);
});

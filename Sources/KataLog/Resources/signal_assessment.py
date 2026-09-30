"""Observed firmware signal severity, independent from recording quality.

This is an occurrence summary, never a component health or flight score.
Small accumulators can be cached or merged without retaining raw messages.
"""
from __future__ import annotations

import re

PRIORITIES = {'EMERGENCY': 8, 'ALERT': 7, 'CRITICAL': 6, 'ERROR': 5,
              'WARNING': 4, 'WARN': 4, 'NOTICE': 3, 'INFO': 2, 'DEBUG': 1}


class SignalAccumulator:
    def __init__(self):
        self.priority = 0
        self.level = None
        self.text = None
        self.count = 0
        self.events = 0
        self.untranslated = 0
        self.uncertain = False
        self.failsafe_message = False

    def _observe(self, priority, level, text, count):
        if priority >= 4:
            self.count += count
            if priority > self.priority:
                self.priority, self.level, self.text = priority, level, text

    def observe_message(self, message, count=1):
        level = str(message.get('level') or 'UNKNOWN').upper()
        text = str(message.get('text') or message.get('title') or '')
        priority = PRIORITIES.get(level, 0)
        failsafe = bool(re.search(r'\bfailsafe activated\b', text, re.I))
        self.failsafe_message |= failsafe
        self.uncertain |= priority == 0
        # Alarm/failsafe flags establish an observed signal but do not invent
        # an ERROR or CRITICAL level absent from the original firmware record.
        self._observe(max(priority, 4 if message.get('isAlert') or failsafe or '[ALARM]' in text.upper() else 0),
                      level if priority else None, text or None, count)

    def observe_event(self, event, count=1):
        self.events += count
        translated = event.get('translationStatus') == 'translated'
        self.untranslated += 0 if translated else count
        levels = [str(event.get(key) or 'UNKNOWN').upper() for key in ('internalLevelName', 'externalLevelName')]
        if not event.get('internalLevelName') and not event.get('externalLevelName'):
            # Some recorded caches predate separate internal/external names.
            # Their original named level is still firmware evidence.
            levels.append(str(event.get('level') or 'UNKNOWN').upper())
        level = max(levels, key=lambda value: PRIORITIES.get(value, 0))
        priority = PRIORITIES.get(level, 0)
        self.uncertain |= priority == 0
        text = event.get('message') if translated else None
        if not text:
            text = 'Événement PX4 ' + str(event.get('eventID', '?'))
        self._observe(priority, level if priority else None, str(text), count)

    def observations(self):
        return {'priority': self.priority, 'level': self.level, 'text': self.text,
                'count': self.count, 'events': self.events, 'untranslated': self.untranslated,
                'uncertain': self.uncertain, 'failsafeMessage': self.failsafe_message}

    def merge(self, value):
        if not isinstance(value, dict):
            self.uncertain = True
            return
        if value.get('priority', 0) > self.priority:
            self.priority, self.level, self.text = value['priority'], value.get('level'), value.get('text')
        self.count += value.get('count', 0)
        self.events += value.get('events', 0)
        self.untranslated += value.get('untranslated', 0)
        self.uncertain |= bool(value.get('uncertain'))
        self.failsafe_message |= bool(value.get('failsafeMessage'))

    def result(self, log, events_complete=None, include_failsafe=True):
        priority, level, text, count = self.priority, self.level, self.text, self.count
        if include_failsafe and log.get('failsafeObserved') and not self.failsafe_message:
            count += 1
            if priority < 4:
                priority, level, text = 4, None, 'Failsafe observé'
        if events_complete is None:
            events_complete = isinstance(log.get('events'), list)
            if not events_complete and 'topics' in log and 'event' not in log['topics']:
                events_complete = bool(log.get('metadata', {}).get('parserVersion'))
        complete = log.get('status') == 'ok' and events_complete and not self.uncertain
        state = ('critical' if priority >= 6 else 'error' if priority >= 5 else
                 'warning' if priority >= 4 else 'none' if complete else 'unknown')
        return {'state': state, 'level': level, 'primaryText': text,
                'occurrenceCount': count, 'eventCount': self.events,
                'untranslatedEventCount': self.untranslated}


def assessment(log, messages=None, events=None, events_complete=None, include_failsafe=True):
    accumulator = SignalAccumulator()
    for message in log.get('messages', []) if messages is None else messages:
        accumulator.observe_message(message)
    for event in log.get('events', []) if events is None else events:
        accumulator.observe_event(event)
    return accumulator.result(log, events_complete, include_failsafe)

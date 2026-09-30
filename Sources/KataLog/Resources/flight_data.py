"""Bounded GPS previews and on-demand log details; no network or source writes.

Field units: PX4 SensorGps v1.13 (lat/lon 1e-7 deg, alt mm) and current
SensorGps (latitude_deg/longitude_deg, altitude_msl_m).
https://docs.px4.io/v1.13/en/msg_docs/sensor_gps
https://docs.px4.io/main/en/msg_docs/SensorGps
"""
from bisect import bisect_left
import math
import numpy as np

PREVIEW_POINTS = 256
DETAIL_POINTS = 4096
GAP_SECONDS = 10.0
BATTERY_REFERENCE = 'https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/msg/BatteryStatus.msg'
GPS_REFERENCE = 'https://github.com/PX4/PX4-Autopilot/blob/v1.16.0/msg/SensorGps.msg'


def relative_time(stamp, start):
    try:
        value = float(stamp) / 1e6 - start
        return value if math.isfinite(value) else None
    except (TypeError, ValueError, OverflowError):
        return None


def parameter_details(ulog, start):
    """Preserve decoded values/types; pyulog does not retain the wire key type."""
    from px4_events import json_value
    def entry(name, value):
        decoded = value.item() if hasattr(value, 'item') else value
        return {'name': str(name), 'type': type(decoded).__name__, 'value': json_value(value),
                'typeSource': 'pyulog decoded value type; declared ULog parameter type is not retained'}
    initial = getattr(ulog, 'initial_parameters', {})
    previous = dict(initial)
    changes = []
    for index, (stamp, name, value) in enumerate(getattr(ulog, 'changed_parameters', [])):
        item = entry(name, value)
        old = previous.get(name)
        item.update(previousValue=json_value(old), timeSeconds=relative_time(stamp, start),
                    rawTimestamp=json_value(stamp), sourceIndex=index,
                    source='ULog:changed_parameters', timing='last_data_timestamp',
                    changed=name not in previous or json_value(old) != item['value'] or type(old) != type(value),
                    previousType=type(old).__name__ if name in previous else None)
        previous[name] = value
        changes.append(item)
    defaults = {}
    if hasattr(ulog, 'get_default_parameters'):
        for code, label in ((0, 'system'), (1, 'current_setup')):
            defaults[label] = [entry(name, value) for name, value in sorted(ulog.get_default_parameters(code).items())]
    return {'schemaVersion': 1,
            'initial': [dict(entry(name, value), source='ULog:initial_parameters') for name, value in sorted(initial.items())],
            'changes': changes, 'defaults': defaults,
            'timing': 'Parameter records have no own timestamp; pyulog associates the last data timestamp.',
            'interpretation': 'Observed parameter changes do not establish the cause of an alert or failure.'}


def dropout_details(ulog, start):
    from px4_events import json_value
    return [{'id': 'dropout:' + str(index), 'sourceIndex': index, 'source': 'ULog:dropout',
             'timeSeconds': relative_time(dropout.timestamp, start), 'rawTimestamp': json_value(dropout.timestamp),
             'durationMilliseconds': json_value(dropout.duration), 'durationSeconds': float(dropout.duration) / 1000,
             'timing': 'last_data_timestamp',
             'interpretation': 'Recording dropout; this record does not prove a radio outage.'}
            for index, dropout in enumerate(getattr(ulog, 'dropouts', []))]


def subsystem_details(ulog, topics, start):
    """Bounded field summaries from actual instances, never a guessed identity.

    Raw first/last values are retained even when no valid scalar was observed.
    Units and sentinels are referenced only for known fields. Min/max describe
    the recorded fields, without diagnosing health or merging receivers.
    """
    from px4_events import json_value
    from telemetry_extractor import _known_field, _dtype
    instances = []
    for dataset in getattr(ulog, 'data_list', []):
        if dataset.name not in topics:
            continue
        fields = []
        for field, raw in sorted(dataset.data.items()):
            if field.startswith('timestamp'):
                continue
            values = np.asarray(raw)
            unit_raw, unit, scale, reference, sentinel = _known_field(dataset.name, field)
            if dataset.name == 'battery_status':
                extra = {'cell_count': ('cells', 'zero_unknown'), 'cycle_count': ('cycles', None),
                         'over_discharge_count': ('count', None), 'interface_error': ('count', None),
                         'average_time_to_empty': ('min', None), 'average_time_to_full': ('min', None),
                         'state_of_health': ('%', None), 'max_error': ('%', None),
                         'full_charge_capacity_wh': ('Wh', None), 'remaining_capacity_wh': ('Wh', None),
                         'nominal_voltage': ('V', None)}
                if not reference and field in extra:
                    unit_raw, sentinel = extra[field]
                    unit, reference = unit_raw, BATTERY_REFERENCE
            numeric = values.ndim == 1 and values.dtype.kind in 'biuf'
            item = {'field': field, 'type': _dtype(dataset, field), 'sampleCount': len(values),
                    'rawUnit': unit_raw, 'unit': unit, 'scale': scale,
                    'unitStatus': 'reference' if reference else 'unknown', 'unitSource': reference,
                    'source': f'ULog:{dataset.name}[{dataset.multi_id}].{field}',
                    'firstRawValue': json_value(values[0]) if len(values) else None,
                    'lastRawValue': json_value(values[-1]) if len(values) else None,
                    'validSampleCount': None, 'rejectedSampleCount': None,
                    'firstValue': None, 'lastValue': None, 'minimum': None, 'maximum': None,
                    'firstTimeSeconds': None, 'lastTimeSeconds': None,
                    'sentinelPolicy': sentinel}
            if numeric:
                valid = np.isfinite(values)
                if sentinel == 'zero_unknown': valid &= values != 0
                elif sentinel == 'minus_one_unknown': valid &= values != -1
                elif sentinel == 'fraction_range': valid &= (values >= 0) & (values <= 1)
                if dataset.name == 'battery_status' and field != 'connected' and 'connected' in dataset.data:
                    connected = np.asarray(dataset.data['connected'])
                    if connected.shape == values.shape: valid &= connected != 0
                indices = np.flatnonzero(valid)
                item.update(validSampleCount=len(indices), rejectedSampleCount=len(values) - len(indices))
                if len(indices):
                    observed = values[valid]
                    def scaled(value): return json_value(value if scale == 1 else value * scale)
                    item.update(firstValue=scaled(values[indices[0]]), lastValue=scaled(values[indices[-1]]),
                                minimum=scaled(np.min(observed)), maximum=scaled(np.max(observed)))
                    stamps = dataset.data.get('timestamp', [])
                    item['firstTimeSeconds'] = relative_time(stamps[indices[0]], start) if indices[0] < len(stamps) else None
                    item['lastTimeSeconds'] = relative_time(stamps[indices[-1]], start) if indices[-1] < len(stamps) else None
            fields.append(item)
        instances.append({'topic': dataset.name, 'instance': int(dataset.multi_id), 'fields': fields})
    return {'schemaVersion': 1, 'instances': instances,
            'interpretation': 'Observed source fields only; missing fields and undocumented units remain unknown. Battery pack serial numbers are not controller or fleet identifiers.'}


def bounded_points(points, limit):
    """Keep segment endpoints when the budget permits, never merge segment IDs."""
    if len(points) <= limit:
        return points
    endpoints = {0, len(points) - 1}
    for i in range(1, len(points)):
        if points[i]['segment'] != points[i-1]['segment']:
            endpoints.update((i - 1, i))
    if len(endpoints) > limit:
        ordered = sorted(endpoints)
        keep = {ordered[i] for i in np.linspace(0, len(ordered) - 1, limit, dtype=int)}
    else:
        keep = endpoints
        extra = [i for i in range(len(points)) if i not in keep]
        count = min(limit - len(keep), len(extra))
        if count:
            keep.update(extra[i] for i in np.linspace(0, len(extra) - 1, count, dtype=int))
    return [points[i] for i in sorted(keep)]


def _candidate(dataset, start, end):
    data = dataset.data
    modern = 'latitude_deg' in data and 'longitude_deg' in data
    lat_key, lon_key = ('latitude_deg', 'longitude_deg') if modern else ('lat', 'lon')
    required = ['timestamp', lat_key, lon_key, 'fix_type']
    if not all(key in data for key in required):
        return None
    count = len(data['timestamp'])
    if any(len(data[key]) != count for key in required):
        return None
    scale = 1.0 if modern else 1e-7
    altitude_key = 'altitude_msl_m' if modern else 'alt'
    altitude = data.get(altitude_key)
    altitude_scale = 1.0 if modern else 1e-3
    points, rejected, segment = [], 0, -1
    last_time = None
    gap = True
    for i in range(count):
        stamp = float(data['timestamp'][i]) / 1e6
        lat, lon = float(data[lat_key][i]) * scale, float(data[lon_key][i]) * scale
        fix = float(data['fix_type'][i])
        valid = (math.isfinite(stamp) and start <= stamp <= end and
                 math.isfinite(lat) and math.isfinite(lon) and -90 < lat < 90 and -180 <= lon <= 180 and
                 fix in (3, 4, 5, 6) and (last_time is None or stamp > last_time))
        # Extrapolated/dead-reckoned fixes do not become recorded GNSS positions.
        if not valid:
            rejected += 1; gap = True
            continue
        if gap or last_time is None or stamp - last_time > GAP_SECONDS:
            segment += 1
        alt = None
        if altitude is not None and i < len(altitude):
            value = float(altitude[i]) * altitude_scale
            if math.isfinite(value):
                alt = value
        points.append({'timeSeconds': round(stamp - start, 6), 'latitude': lat,
                       'longitude': lon, 'altitudeMeters': alt, 'segment': segment})
        last_time = stamp; gap = False
    return {'source': f'{dataset.name}[{dataset.multi_id}] · WGS84 · {lat_key}/{lon_key} · altitude MSL',
            'originalPointCount': count, 'rejectedPointCount': rejected, 'points': points}


def extract_track(datasets, start, end):
    candidates = []
    for dataset in datasets:
        if dataset.name in ('sensor_gps', 'vehicle_gps_position'):
            track = _candidate(dataset, start, end)
            if track and track['points']:
                candidates.append((track, dataset.name == 'sensor_gps', -dataset.multi_id))
    if not candidates:
        return None
    # One receiver only, never concatenate independent sensors. Most usable
    # points wins; prefer raw sensor and lowest instance on an equal count.
    return max(candidates, key=lambda item: (len(item[0]['points']), item[1], item[2]))[0]


def track_preview(track, limit=PREVIEW_POINTS):
    return {**track, 'points': bounded_points(track['points'], limit)} if track else None


def position_messages(messages, track):
    if not track:
        return
    points = track['points']
    times = [p['timeSeconds'] for p in points]
    spans = {}
    for p in points:
        lo, hi = spans.get(p['segment'], (p['timeSeconds'], p['timeSeconds']))
        spans[p['segment']] = (min(lo, p['timeSeconds']), max(hi, p['timeSeconds']))
    for message in messages:
        stamp = message['timestampSeconds']
        index = bisect_left(times, stamp)
        neighbors = points[max(0, index-1): min(len(points), index+1)]
        if not neighbors:
            continue
        point = min(neighbors, key=lambda p: abs(p['timeSeconds'] - stamp))
        lo, hi = spans[point['segment']]
        if lo <= stamp <= hi and abs(point['timeSeconds'] - stamp) <= 2:
            message['position'] = point.copy()


def enrich(log, ulog, detailed=False, dictionary_path=None):
    start = ulog.start_timestamp / 1e6
    end = start + log['durationSeconds']
    track = extract_track(ulog.data_list, start, end)
    log['track'] = track_preview(track, DETAIL_POINTS if detailed else PREVIEW_POINTS)
    if track:
        log['coverage'].append(f"GPS : un récepteur choisi selon les points valides ; fix 3D/différentiel/RTK seulement, lacunes > {GAP_SECONDS:g} s et échantillons invalides séparés. Trajectoire d’affichage échantillonnée, pas une trajectoire de commande.")
    else:
        log['coverage'].append('Aucune trajectoire GNSS exploitable (coordonnées, fix ou timestamps absents/invalides).')
    # Global-map alerts use exact nearby samples, even when the displayed
    # trajectory is only a preview. Parameters and topic details remain lazy.
    position_messages(log['messages'], track)
    if not detailed:
        return
    log['topicDetails'] = [dict(name=d.name, instance=d.multi_id,
                                sampleCount=len(d.data.get('timestamp', [])), fields=sorted(d.data))
                           for d in sorted(ulog.data_list, key=lambda d: (d.name, d.multi_id))]
    log['parameters'] = {str(k): str(v) for k, v in sorted(ulog.initial_parameters.items())}
    log['parameterChanges'] = [dict(timeSeconds=round(float(stamp)/1e6 - start, 6), name=str(name), value=str(value))
                               for stamp, name, value in ulog.changed_parameters if math.isfinite(float(stamp))]
    log['parameterDetails'] = parameter_details(ulog, start)
    log['dropouts'] = dropout_details(ulog, start)
    log['batteryDetails'] = subsystem_details(ulog, {'battery_status'}, start)
    log['gnssDetails'] = subsystem_details(ulog, {'sensor_gps', 'vehicle_gps_position'}, start)
    log['metadata']['detailParserVersion'] = log['metadata']['parserVersion']
    from px4_events import extract_events, export_log_metadata
    from telemetry_extractor import catalogue
    decoded = extract_events(ulog, start, firmwareMetadata=log.get('metadata', {}), dictionary_path=dictionary_path)
    log['events'] = decoded['events']
    log['eventDictionary'] = decoded['dictionary']
    log['eventCoverage'] = decoded['coverage']
    # The compact summary defers event translation. Once details have actually
    # decoded the records, retain the resulting coverage rather than its older
    # "dictionary required" notice.
    log['coverage'] = [item for item in log['coverage'] if not item.startswith('Événements binaires non décodés :')]
    if decoded['events']:
        translated = sum(item.get('translationStatus') == 'translated' for item in decoded['events'])
        log['coverage'].append(f"Événements binaires : {len(decoded['events'])} enregistrements conservés ; {translated} traduits avec un dictionnaire exact, {len(decoded['events']) - translated} bruts ou non traduits. Statut du dictionnaire : {decoded['dictionary']['status']}.")
    log['metadataDetails'] = export_log_metadata(ulog)
    log['telemetryCatalogue'] = catalogue(ulog)

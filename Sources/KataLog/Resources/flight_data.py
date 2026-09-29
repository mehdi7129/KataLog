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


def enrich(log, ulog, detailed=False):
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
    log['metadata']['detailParserVersion'] = log['metadata']['parserVersion']

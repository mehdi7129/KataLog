"""Compact, exhaustive map coverage independent of detailed flight previews.

Each page contains only recorded GPS samples and listing metadata. No ULog,
full summary JSON, messages, or trajectory is decoded by an ordinary overview
query. Client/message/date filters are applied before counting and pagination.
"""
from __future__ import annotations

import base64
import json
import math


def valid_point(point):
    return (isinstance(point, dict)
            and all(type(point.get(key)) in (int, float) and math.isfinite(point[key])
                    for key in ('latitude', 'longitude', 'timeSeconds'))
            and abs(point['latitude']) < 90 and abs(point['longitude']) <= 180)


def projected_marker(log):
    track = log.get('track') or {}
    point = next((point for point in track.get('points', []) if valid_point(point)), None)
    if point is None:
        return None
    return json.dumps({'fileName': log.get('fileName', ''),
                       'latitude': point['latitude'], 'longitude': point['longitude']},
                      ensure_ascii=False, allow_nan=False, separators=(',', ':'))


def query_page(db, request, scope, limit, revision, scope_hash, offset, unavailable):
    import library_repository as repository
    statement, params, _ = repository.selection_statement(scope, metadata_only=True)
    # Only small metadata is copied by the selection CTE. The track-bearing
    # summary_projection column must never be read by this request.
    selected = ' FROM selected s JOIN kl_logs l ON l.id=s.id'
    proximal = bool(scope.get('_proximityFiltered'))
    if proximal:
        selected += ' JOIN kl_proximity_matches p ON p.id=s.id'
    located = 'p.latitude IS NOT NULL' if proximal else 'l.map_marker IS NOT NULL'
    counts = db.execute(statement + 'SELECT COUNT(*),COALESCE(SUM(' + located + '),0)' + selected, params).fetchone()
    result = {'queryVersion': repository.QUERY_VERSION, 'revision': revision, 'scopeHash': scope_hash,
              'markers': [], 'totalLogs': counts[0], 'locatedLogs': counts[1], 'nextCursor': None}
    if unavailable is not None:
        result['proximityUnavailableLogs'] = unavailable
    descending = request.get('sortOrder', 'recent') == 'recent'
    direction, comparison = ('DESC', '<') if descending else ('ASC', '>')
    where, page_params, page_offset = ' WHERE ' + located, list(params), offset
    if request.get('cursor'):
        cursor = json.loads(base64.urlsafe_b64decode(request['cursor'] + '=' * (-len(request['cursor']) % 4)))
        position = cursor.get('position')
        if position is not None:
            if not isinstance(position, list) or len(position) != 2 or not all(isinstance(item, str) for item in position):
                raise ValueError('Position de curseur de carte invalide.')
            where += ' AND (s.date,s.id)' + comparison + '(?,?)'
            page_params.extend(position)
            page_offset = 0
    fields = 's.id,s.date,s.duration,s.canonical_name,s.stock_number,l.map_marker,c.name AS client_name'
    if proximal:
        # Complete-track verification also yields the closest real sample.
        # It can exist even when an old summary has no GPS preview.
        fields += ',p.latitude,p.longitude'
    rows = db.execute(statement + 'SELECT ' + fields + selected +
                      ' LEFT JOIN log_clients lc ON lc.log_id=s.id LEFT JOIN clients c ON c.id=lc.client_id' +
                      where + ' ORDER BY s.date ' + direction + ',s.id ' + direction + ' LIMIT ? OFFSET ?',
                      page_params + [limit, page_offset])

    def marker(row):
        value = json.loads(row['map_marker']) if row['map_marker'] else {'fileName': ''}
        if proximal:
            value.update(latitude=row['latitude'], longitude=row['longitude'])
        value.update(id=row['id'], droneName='Drone ' + row['stock_number'] if row['stock_number'] else row['canonical_name'],
                     date=row['date'], durationSeconds=row['duration'], clientName=row['client_name'])
        return value

    result['markers'] = repository.bounded_rows(rows, marker, result)
    if offset + len(result['markers']) < result['locatedLogs']:
        last = result['markers'][-1]
        result['nextCursor'] = repository.encode_cursor(revision, scope_hash, 'map-overview', None,
                                                       offset + len(result['markers']), [last['date'], last['id']])
    return result

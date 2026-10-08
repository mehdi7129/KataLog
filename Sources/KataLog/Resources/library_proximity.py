"""Full-resolution, SHA-verified geographic selection before map pagination.

Display previews are intentionally never used as a spatial oracle. Complete
GNSS tracks can be cached by content ID; missing sources remain searchable
once that complete track is cached. Gaps and invalid fixes are not bridged.
"""
from __future__ import annotations

import contextlib
import io
import json
import math
import struct
from pathlib import Path
import zlib

EARTH_METERS = 6_371_008.8
CACHE_VERSION = 1
MAX_CACHE_BYTES = 128 * 1024 * 1024


def initialize(db):
    db.execute('CREATE TABLE IF NOT EXISTS spatial_tracks(log_id TEXT PRIMARY KEY,version INTEGER NOT NULL,payload BLOB NOT NULL)')


def prepare_readonly(db):
    if not db.execute("SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='spatial_tracks'").fetchone():
        db.execute('CREATE TEMP TABLE IF NOT EXISTS spatial_tracks(log_id TEXT PRIMARY KEY,version INTEGER NOT NULL,payload BLOB NOT NULL)')


def validate(value):
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError('Zone géographique invalide.')
    result = {}
    for name, minimum, maximum in (('latitude', -90, 90), ('longitude', -180, 180), ('radiusMeters', 1, 20_100_000)):
        number = value.get(name)
        if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number) or not minimum <= number <= maximum:
            raise ValueError('Coordonnées ou rayon de recherche invalides.')
        result[name] = float(number)
    return result


def vector(latitude, longitude):
    latitude, longitude = math.radians(latitude), math.radians(longitude)
    return (math.cos(latitude) * math.cos(longitude), math.cos(latitude) * math.sin(longitude), math.sin(latitude))


def dot(a, b):
    return sum(x*y for x, y in zip(a, b))


def cross(a, b):
    return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])


def norm(a):
    return math.sqrt(dot(a, a))


def angle(a, b):
    return math.atan2(norm(cross(a, b)), dot(a, b))


def segment_distance(center, start, end):
    """Angular distance to the shorter great-circle arc, including endpoints."""
    distance = min(angle(center, start), angle(center, end))
    normal = cross(start, end)
    length = norm(normal)
    if length < 1e-12:
        return distance  # coincident/antipodal points do not define an arc
    normal = tuple(x / length for x in normal)
    projection = tuple(c - dot(center, normal)*n for c, n in zip(center, normal))
    length = norm(projection)
    if length < 1e-12:
        return distance
    candidate = tuple(x / length for x in projection)
    arc = angle(start, end)
    if angle(start, candidate) + angle(candidate, end) <= arc + 1e-9:
        distance = min(distance, angle(center, candidate))
    return distance


def intersects(track, proximity):
    if not track:
        return False
    center = vector(proximity['latitude'], proximity['longitude'])
    radius = proximity['radiusMeters'] / EARTH_METERS
    previous = None
    for point in track.get('points', []):
        current = vector(point['latitude'], point['longitude'])
        if angle(center, current) <= radius:
            return True
        if previous is not None:
            last, position = previous
            delta = point['timeSeconds'] - last['timeSeconds']
            if point.get('segment') == last.get('segment') and 0 < delta <= 10:
                if segment_distance(center, position, current) <= radius:
                    return True
        previous = (point, current)
    return False


def cache_track(db, identity, track):
    encoded = json.dumps(track, allow_nan=False, separators=(',', ':')).encode()
    if len(encoded) <= MAX_CACHE_BYTES:
        db.execute('INSERT OR REPLACE INTO spatial_tracks VALUES(?,?,?)', (identity, CACHE_VERSION, zlib.compress(encoded)))
        return True
    return False


def complete_track(db, identity, read_only=False, cache_status=None):
    import analyzer
    from flight_data import extract_track
    cached = db.execute('SELECT version,payload FROM spatial_tracks WHERE log_id=?', (identity,)).fetchone()
    if cached and cached[0] == CACHE_VERSION:
        try:
            decoder = zlib.decompressobj()
            raw = decoder.decompress(cached[1], MAX_CACHE_BYTES + 1)
            if len(raw) > MAX_CACHE_BYTES or not decoder.eof:
                raise ValueError('Cache de trajectoire trop volumineux.')
            track = json.loads(raw)
            if cache_status is not None:
                cache_status.append(True)
            return track, True
        except (ValueError, zlib.error, UnicodeError):
            pass  # Rebuild from an original; never use an incomplete preview.
    for row in db.execute('SELECT path FROM sources WHERE log_id=? ORDER BY path', (identity,)):
        path = Path(row[0])
        try:
            before = analyzer.stat_signature(analyzer.require_local_source(path))
            if analyzer.digest_file(path) != identity:
                continue
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                ulog = analyzer.ULog(str(path), message_name_filter_list=['sensor_gps', 'vehicle_gps_position'])
            track = extract_track(ulog.data_list, ulog.start_timestamp / 1e6, ulog.last_timestamp / 1e6)
            if analyzer.stat_signature(path.stat()) != before:
                continue
            retained = not read_only and cache_track(db, identity, track)
            if cache_status is not None:
                cache_status.append(retained)
            return track, True
        except (OSError, ValueError, TypeError, KeyError, IndexError, OverflowError, EOFError, RuntimeError, struct.error):
            continue
    if cache_status is not None:
        cache_status.append(False)
    return None, False


def prepare_scope(db, scope, proximity, read_only=False, overview=False, cache_key=None, cache_path=None):
    import library_repository as repository
    import proximity_cache
    db.execute('CREATE TEMP TABLE IF NOT EXISTS kl_proximity_metadata(key TEXT)')
    cached = db.execute('SELECT key FROM kl_proximity_metadata').fetchone()
    if cache_key is not None and cached and cached[0] == cache_key:
        return dict(scope, _proximityFiltered=True), 0
    db.execute('DELETE FROM kl_proximity_metadata')
    db.execute('DROP TABLE IF EXISTS temp.kl_proximity_matches')
    db.execute('CREATE TEMP TABLE kl_proximity_matches(id TEXT PRIMARY KEY,latitude REAL,longitude REAL)')
    if cache_key is not None and proximity_cache.load(db, cache_path, cache_key):
        db.execute('INSERT INTO kl_proximity_metadata VALUES(?)', (cache_key,))
        return dict(scope, _proximityFiltered=True), 0
    statement, params, _ = repository.selection_statement(scope)
    identities = [row[0] for row in db.execute(statement + 'SELECT id FROM selected', params)]
    unavailable = 0
    cache_status = []
    for identity in identities:
        track, available = complete_track(db, identity, read_only, cache_status)
        if not available:
            unavailable += 1
        elif intersects(track, proximity):
            point = None
            if overview:
                from library_map_overview import valid_point
                center = vector(proximity['latitude'], proximity['longitude'])
                point = min((point for point in track.get('points', []) if valid_point(point)),
                            key=lambda point: angle(center, vector(point['latitude'], point['longitude'])), default=None)
            db.execute('INSERT INTO kl_proximity_matches VALUES(?,?,?)',
                       (identity, point['latitude'] if point else None, point['longitude'] if point else None))
    if cache_key is not None and all(cache_status):
        db.execute('INSERT INTO kl_proximity_metadata VALUES(?)', (cache_key,))
        proximity_cache.save(db, cache_path, cache_key)
    return dict(scope, _proximityFiltered=True), unavailable

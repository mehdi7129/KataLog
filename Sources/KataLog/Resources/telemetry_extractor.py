"""On-demand numeric ULog series, with bounded points and explicit coverage.

Units are known-field references, not inferred from an arbitrary field name.
PX4 v1.14 BatteryStatus/EstimatorStatus/SensorGps and v1.16 SensorGps supply
the references below. Unknown topics/fields remain catalogued with no unit.
"""
import math
import re
import numpy as np

MAX_POINTS = 2048
MAX_CURVES = 4
DEFAULT_GAP_SECONDS = 10.0
GPS14 = 'https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/msg/SensorGps.msg'
GPS16 = 'https://github.com/PX4/PX4-Autopilot/blob/v1.16.0/msg/SensorGps.msg'
BATTERY14 = 'https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/msg/BatteryStatus.msg'
EKF14 = 'https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/msg/EstimatorStatus.msg'


def _known_field(topic, field):
    """raw unit, output unit, scale, reference, documented sentinel policy."""
    if topic in ('sensor_gps', 'vehicle_gps_position'):
        units = {'lat': ('1e-7 deg', 'deg', 1e-7, GPS14),
                 'lon': ('1e-7 deg', 'deg', 1e-7, GPS14),
                 'alt': ('mm', 'm', .001, GPS14),
                 'alt_ellipsoid': ('mm', 'm', .001, GPS14),
                 'latitude_deg': ('deg', 'deg', 1, GPS16),
                 'longitude_deg': ('deg', 'deg', 1, GPS16),
                 'altitude_msl_m': ('m', 'm', 1, GPS16),
                 'altitude_ellipsoid_m': ('m', 'm', 1, GPS16),
                 'eph': ('m', 'm', 1, GPS14), 'epv': ('m', 'm', 1, GPS14),
                 's_variance_m_s': ('m/s', 'm/s', 1, GPS14),
                 'c_variance_rad': ('rad', 'rad', 1, GPS14),
                 'vel_m_s': ('m/s', 'm/s', 1, GPS14),
                 'vel_n_m_s': ('m/s', 'm/s', 1, GPS14),
                 'vel_e_m_s': ('m/s', 'm/s', 1, GPS14),
                 'vel_d_m_s': ('m/s', 'm/s', 1, GPS14),
                 'heading': ('rad', 'rad', 1, GPS14), 'cog_rad': ('rad', 'rad', 1, GPS14),
                 'rtcm_injection_rate': ('Hz', 'Hz', 1, GPS14)}
        if field in units:
            return (*units[field], None)
    if topic == 'battery_status':
        if field in ('voltage_v', 'voltage_filtered_v') or re.fullmatch(r'voltage_cell_v\[\d+\]', field):
            return ('V', 'V', 1, BATTERY14, 'zero_unknown')
        if field == 'max_cell_voltage_delta':
            return ('V', 'V', 1, BATTERY14, None)
        if field in ('current_a', 'current_average_a'):
            return ('A', 'A', 1, BATTERY14, 'minus_one_unknown')
        if field == 'current_filtered_a':
            return ('A', 'A', 1, BATTERY14, 'zero_unknown')
        if field == 'discharged_mah':
            return ('mAh', 'mAh', 1, BATTERY14, 'minus_one_unknown')
        if field == 'remaining':
            return ('fraction', '%', 100, BATTERY14, 'fraction_range')
        if field == 'time_remaining_s':
            return ('s', 's', 1, BATTERY14, None)
    if topic == 'estimator_status':
        if field in ('pos_horiz_accuracy', 'pos_vert_accuracy'):
            return ('m', 'm', 1, EKF14, None)
        if field.endswith('_test_ratio') and field in ('mag_test_ratio', 'vel_test_ratio', 'pos_test_ratio',
                                                      'hgt_test_ratio', 'tas_test_ratio', 'hagl_test_ratio', 'beta_test_ratio'):
            return ('ratio', 'ratio', 1, EKF14, None)
        if field == 'time_slip':
            return ('s', 's', 1, EKF14, None)
        tracking = {'output_tracking_error[0]': 'rad', 'output_tracking_error[1]': 'm/s',
                    'output_tracking_error[2]': 'm'}
        if field in tracking:
            return (tracking[field], tracking[field], 1, EKF14, None)
    return ('', '', 1, None, None)


def _dtype(dataset, field):
    declared = next((item.type_str for item in getattr(dataset, 'field_data', [])
                     if item.field_name == field), None)
    return declared or str(np.asarray(dataset.data[field]).dtype)


def _discrete(topic, field, dtype):
    if topic in ('sensor_gps', 'vehicle_gps_position') and field in ('lat', 'lon', 'alt', 'alt_ellipsoid'):
        return False  # integer encodings of continuous coordinates, not enum states
    return dtype.kind in 'biu'


def catalogue(ulog):
    """Enumerate actual fields/instances; no series are extracted at import."""
    result = []
    for dataset in getattr(ulog, 'data_list', []):
        for field, values in dataset.data.items():
            array = np.asarray(values)
            raw_unit, unit, scale, reference, sentinel = _known_field(dataset.name, field)
            numeric = array.ndim == 1 and array.dtype.kind in 'biuf'
            result.append({'key': f'{dataset.name}[{dataset.multi_id}].{field}',
                           'topic': dataset.name, 'instance': int(dataset.multi_id), 'field': field,
                           'type': _dtype(dataset, field), 'sampleCount': len(array),
                           'numeric': numeric, 'extractable': numeric and field != 'timestamp' and 'timestamp' in dataset.data,
                           'rawUnit': raw_unit, 'unit': unit, 'scale': scale,
                           'unitSource': reference, 'unitStatus': 'reference' if reference else 'unknown',
                           'sentinelPolicy': sentinel,
                           'interpolation': 'step' if _discrete(dataset.name, field, array.dtype) else 'linear'})
    return sorted(result, key=lambda item: (item['topic'], item['instance'], item['field']))


class _Segment:
    """A contiguous range into existing ULog arrays, not a copy of every point."""
    __slots__ = ('left', 'right', 'stamps', 'values', 'start', 'scale', 'segment')
    def __init__(self, left, right, stamps, values, start, scale, segment):
        self.left, self.right, self.stamps, self.values = left, right, stamps, values
        self.start, self.scale, self.segment = start, scale, segment

    def __len__(self):
        return self.right - self.left

    def __getitem__(self, index):
        if index < 0:
            index += len(self)
        if not 0 <= index < len(self):
            raise IndexError(index)
        absolute = self.left + index
        return {'timeSeconds': float(self.stamps[absolute]) / 1e6 - self.start,
                'value': float(self.values[absolute]) * self.scale, 'segment': self.segment}

    def __iter__(self):
        for index in range(len(self)):
            yield self[index]


def _downsample(segment, budget, discrete):
    """Source-order points; extrema and discrete transitions are never averaged."""
    count = len(segment)
    if count <= budget:
        return segment, 0
    essential = {0, count - 1}
    if discrete:
        for index in range(1, count):
            if segment[index]['value'] != segment[index - 1]['value']:
                essential.update((index - 1, index))
        if len(essential) <= budget:
            indices = sorted(essential)
        else:
            # Keep paired transition samples when possible. Report loss explicitly.
            pairs = [(index - 1, index) for index in range(1, count)
                     if segment[index]['value'] != segment[index - 1]['value']]
            slots = max(0, (budget - 2) // 2)
            chosen = np.linspace(0, len(pairs) - 1, slots, dtype=int) if slots else []
            indices = sorted({0, count - 1} | {point for pick in chosen for point in pairs[pick]})
        retained = set(indices)
        lost = sum(segment[index]['value'] != segment[index - 1]['value'] and
                   not {index - 1, index}.issubset(retained) for index in range(1, count))
        return [segment[index] for index in indices], lost
    # Endpoints plus bucket minima/maxima preserve spikes instead of uniform stride.
    slots = budget - 2
    indices = {0, count - 1}
    if slots >= 2:
        buckets = max(1, slots // 2)
        edges = np.linspace(1, count - 1, buckets + 1, dtype=int)
        for left, right in zip(edges[:-1], edges[1:]):
            if right > left:
                indices.add(min(range(left, right), key=lambda i: segment[i]['value']))
                indices.add(max(range(left, right), key=lambda i: segment[i]['value']))
    elif slots == 1:
        # Preserve the larger departure from the endpoint range.
        low, high = sorted((segment[0]['value'], segment[-1]['value']))
        indices.add(max(range(1, count - 1), key=lambda i: max(low - segment[i]['value'], segment[i]['value'] - high)))
    return [segment[index] for index in sorted(indices)], 0


def _reduce_segments(segments, budget, discrete):
    costs = [min(2, len(segment)) for segment in segments]
    included = []
    left = budget
    # Whole segment boundary pairs are allocated before interior points. If even
    # these do not fit, omitted segments are counted; different IDs never join.
    for index, cost in enumerate(costs):
        if cost <= left:
            included.append(index)
            left -= cost
    allocation = {index: costs[index] for index in included}
    while left and included:
        active = [index for index in included if allocation[index] < len(segments[index])]
        if not active:
            break
        share = max(1, left // len(active))
        for index in active:
            extra = min(share, len(segments[index]) - allocation[index], left)
            allocation[index] += extra
            left -= extra
    points, lost_transitions, omitted_extrema = [], 0, 0
    for index in included:
        reduced, lost = _downsample(segments[index], allocation[index], discrete)
        points.extend(reduced)
        lost_transitions += lost
        source_values = {min(point['value'] for point in segments[index]), max(point['value'] for point in segments[index])}
        omitted_extrema += len(source_values - {point['value'] for point in reduced})
    omitted = set(range(len(segments))) - set(included)
    return points, len(omitted), sum(len(segments[index]) for index in omitted), lost_transitions, omitted_extrema


def extract_series(ulog, topic, field, instance=0, startSeconds=None,
                   timeFrom=None, timeTo=None, budget=MAX_POINTS, gapSeconds=DEFAULT_GAP_SECONDS):
    """Extract one selected series. Window/budget/gaps are recorded in output.

    NaN, documented unknown sentinels, time reversals and long gaps split
    segments. No sort, interpolation over missing samples, or average is used.
    Integers not exactly representable as a Swift Double are rejected explicitly.
    """
    if type(budget) is not int or not 2 <= budget <= MAX_POINTS:
        raise ValueError('budget must be an integer between 2 and 2048')
    if startSeconds is None:
        startSeconds = getattr(ulog, 'start_timestamp', 0) / 1e6
    for name, value in [('startSeconds', startSeconds), ('timeFrom', timeFrom), ('timeTo', timeTo), ('gapSeconds', gapSeconds)]:
        if value is not None and not math.isfinite(value):
            raise ValueError(name + ' must be finite')
    if gapSeconds <= 0 or (timeFrom is not None and timeTo is not None and timeFrom > timeTo):
        raise ValueError('invalid window or gap threshold')
    dataset = next((item for item in getattr(ulog, 'data_list', [])
                    if item.name == topic and item.multi_id == instance), None)
    if dataset is None or field not in dataset.data:
        raise KeyError(f'unavailable field {topic}[{instance}].{field}')
    values = np.asarray(dataset.data[field])
    stamps = np.asarray(dataset.data.get('timestamp', []))
    if field == 'timestamp' or values.ndim != 1 or values.dtype.kind not in 'biuf':
        raise ValueError('field is not an extractable numeric series')
    if len(stamps) != len(values):
        raise ValueError('timestamp and field sample counts differ')
    raw_unit, unit, scale, reference, sentinel = _known_field(topic, field)
    discrete = _discrete(topic, field, values.dtype)
    segments, current_left, current_right = [], None, None
    segment_count, valid_count, boundary_remaining = 0, 0, budget
    omitted_boundary_segments, omitted_boundary_samples, omitted_boundary_transitions = 0, 0, 0
    current_transitions, current_value = 0, None
    rejected, outside, reversals, gaps, precision, sentinels, invalid_values, invalid_stamps = (0,) * 8
    previous_time = None
    in_window = 0

    def split():
        nonlocal current_left, current_right, segment_count, valid_count, boundary_remaining
        nonlocal omitted_boundary_segments, omitted_boundary_samples, omitted_boundary_transitions
        nonlocal current_transitions, current_value
        if current_left is not None:
            count = current_right - current_left
            valid_count += count
            boundary_cost = min(2, count)
            if boundary_cost <= boundary_remaining:
                segments.append(_Segment(current_left, current_right, stamps, values,
                                         startSeconds, scale, segment_count))
                boundary_remaining -= boundary_cost
            else:
                omitted_boundary_segments += 1
                omitted_boundary_samples += count
                omitted_boundary_transitions += current_transitions
            segment_count += 1
            current_left = current_right = None
            current_transitions, current_value = 0, None

    for source_index, (raw_time, raw_value) in enumerate(zip(stamps, values)):
        stamp = float(raw_time)
        if not math.isfinite(stamp) or stamp < 0:
            rejected += 1; invalid_stamps += 1
            split(); previous_time = None
            continue
        time = stamp / 1e6 - startSeconds
        if previous_time is not None and time <= previous_time:
            reversals += 1
            split()
        elif previous_time is not None and time - previous_time > gapSeconds:
            gaps += 1
            split()
        previous_time = time
        if (timeFrom is not None and time < timeFrom) or (timeTo is not None and time > timeTo):
            outside += 1
            split()
            continue
        in_window += 1
        value = float(raw_value)
        if not math.isfinite(value):
            rejected += 1; invalid_values += 1
            split()
            continue
        if values.dtype.kind in 'iu' and abs(int(raw_value)) > 2 ** 53:
            rejected += 1; precision += 1
            split()
            continue
        unknown = ((sentinel == 'zero_unknown' and value == 0) or
                   (sentinel == 'minus_one_unknown' and value == -1) or
                   (sentinel == 'fraction_range' and not 0 <= value <= 1))
        if unknown:
            rejected += 1; sentinels += 1
            split()
            continue
        if current_left is None:
            current_left = source_index
        elif discrete and current_value != value:
            current_transitions += 1
        current_value = value
        current_right = source_index + 1
    split()
    points, omitted_segments, omitted_samples, lost_transitions, omitted_extrema = _reduce_segments(segments, budget, discrete)
    omitted_segments += omitted_boundary_segments
    omitted_samples += omitted_boundary_samples
    lost_transitions += omitted_boundary_transitions
    detail = {'windowSampleCount': in_window, 'validSampleCount': valid_count,
              'rejectedSampleCount': rejected, 'outsideWindowSampleCount': outside,
              'displayedPointCount': len(points), 'segmentCount': segment_count,
              'displayedSegmentCount': len({point['segment'] for point in points}),
              'omittedSegmentCount': omitted_segments, 'omittedSegmentSampleCount': omitted_samples,
              'omittedTransitionCount': lost_transitions, 'omittedExtremaCount': omitted_extrema,
              'timeReversalCount': reversals, 'longGapCount': gaps, 'nonfiniteValueCount': invalid_values,
              'invalidTimestampCount': invalid_stamps, 'precisionRejectedCount': precision,
              'sentinelRejectedCount': sentinels}
    return {'key': f'{topic}[{instance}].{field}', 'label': field, 'source': f'{topic}[{instance}].{field}',
            'topic': topic, 'field': field, 'instance': int(instance), 'type': _dtype(dataset, field),
            'unit': unit, 'rawUnit': raw_unit, 'unitSource': reference,
            'unitStatus': 'reference' if reference else 'unknown', 'scale': scale,
            'sourceConversion': f'raw × {scale}; float64; integer values outside ±2^53 rejected',
            'originalSampleCount': len(values), 'points': points,
            'interpolation': 'step' if discrete else 'linear',
            'strategy': 'transition-pairs' if discrete else 'bucket-minmax',
            'pointBudget': budget, 'gapSeconds': gapSeconds,
            'windowFrom': timeFrom, 'windowTo': timeTo, **detail,
            'completeWindow': not rejected and not omitted_segments and not lost_transitions and not omitted_extrema and not gaps and not reversals,
            'coverage': {'status': 'absent' if not valid_count else ('partial' if rejected or omitted_segments or lost_transitions or omitted_extrema or gaps or reversals else 'available'),
                         'detail': detail}}


RECIPES = {
    'battery': [('battery_status', field) for field in ('voltage_v', 'current_a', 'remaining', 'discharged_mah')],
    'gnss': [('sensor_gps', field) for field in ('fix_type', 'satellites_used', 'eph', 'epv')],
    'ekf': [('estimator_status', field) for field in ('pos_test_ratio', 'vel_test_ratio', 'hgt_test_ratio', 'mag_test_ratio')],
}


def extract_recipe(ulog, recipe, instance=0, startSeconds=None, timeFrom=None, timeTo=None, budget=MAX_POINTS):
    """Up to four curves, sharing a total point budget of at most 2048."""
    if type(budget) is not int or not 2 <= budget <= MAX_POINTS:
        raise ValueError('recipe total budget must be between 2 and 2048')
    requests = RECIPES.get(recipe) if isinstance(recipe, str) else recipe
    if requests is None or not isinstance(requests, (list, tuple)) or len(requests) > MAX_CURVES:
        raise ValueError('unknown recipe or more than four curves requested')
    if any(not isinstance(request, (list, tuple)) or len(request) != 2 or
           any(not isinstance(value, str) for value in request) for request in requests):
        raise ValueError('each curve must identify a topic and field')
    if len({tuple(request) for request in requests}) != len(requests):
        raise ValueError('duplicate curves are not allowed')
    available, missing = [], []
    for topic, field in requests:
        if any(item.name == topic and item.multi_id == instance and field in item.data for item in ulog.data_list):
            available.append((topic, field))
        else:
            missing.append(f'{topic}[{instance}].{field}')
    if len(available) * 2 > budget:
        raise ValueError('total budget cannot preserve every curve boundary')
    allocations = [budget // len(available) + (index < budget % len(available))
                   for index in range(len(available))] if available else []
    series = [extract_series(ulog, topic, field, instance, startSeconds, timeFrom, timeTo, allocation)
              for (topic, field), allocation in zip(available, allocations)]
    return {'schemaVersion': 1, 'recipe': recipe if isinstance(recipe, str) else 'custom',
            'instance': instance, 'series': series, 'missingFields': missing,
            'pointBudget': budget, 'displayedPointCount': sum(len(item['points']) for item in series)}

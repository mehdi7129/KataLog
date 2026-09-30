"""Bounded on-demand telemetry preserves extrema, transitions and gaps."""
import json
from pathlib import Path
import sys
import tracemalloc
from types import SimpleNamespace
import unittest
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import telemetry_extractor as telemetry


def log(topic='custom', instance=0, stamps=None, **fields):
    count = len(next(iter(fields.values())))
    data = {name: np.array(values) for name, values in fields.items()}
    data['timestamp'] = np.array(range(count) if stamps is None else stamps) * 1e6
    dataset = SimpleNamespace(name=topic, multi_id=instance, data=data, field_data=[])
    return SimpleNamespace(start_timestamp=0, data_list=[dataset])


class TelemetryTests(unittest.TestCase):
    def test_catalogue_actual_fields_types_instances_unknown_units_and_non_numeric(self):
        first = log(instance=2, value=[1.5, 2.5], arbitrary_voltage=[4, 5], text=['a', 'b'])
        fields = telemetry.catalogue(first)
        self.assertEqual(len(fields), 4)
        self.assertEqual({item['instance'] for item in fields}, {2})
        self.assertFalse(next(item for item in fields if item['field'] == 'text')['extractable'])
        self.assertEqual(next(item for item in fields if item['field'] == 'arbitrary_voltage')['unit'], '')
        self.assertEqual(next(item for item in fields if item['field'] == 'value')['type'], 'float64')

    def test_minmax_preserves_single_sample_spike_and_valley_with_budget(self):
        values = np.zeros(10000); values[4123] = 99; values[7345] = -42
        result = telemetry.extract_series(log(value=values), 'custom', 'value', budget=128)
        self.assertLessEqual(len(result['points']), 128)
        self.assertEqual(min(point['value'] for point in result['points']), -42)
        self.assertEqual(max(point['value'] for point in result['points']), 99)
        self.assertEqual(result['points'][0]['timeSeconds'], 0)
        self.assertEqual(result['points'][-1]['timeSeconds'], 9999)
        self.assertEqual(result['originalSampleCount'], 10000)
        self.assertEqual(result['omittedExtremaCount'], 0)

    def test_nan_time_reversal_equal_time_and_long_gap_split_segments(self):
        result = telemetry.extract_series(log(stamps=[0, 1, 2, 3, 30, 29, 29, 31], value=[1., 2., np.nan, 4., 5., 6., 7., 8.]), 'custom', 'value')
        points = result['points']
        self.assertEqual([point['segment'] for point in points], [0, 0, 1, 2, 3, 4, 4])
        self.assertEqual(result['nonfiniteValueCount'], 1)
        self.assertEqual(result['timeReversalCount'], 2)
        self.assertEqual(result['longGapCount'], 1)
        self.assertEqual(result['coverage']['status'], 'partial')
        json.dumps(result, allow_nan=False)

    def test_window_relative_start_and_no_synthetic_boundary_interpolation(self):
        result = telemetry.extract_series(log(stamps=[10, 11, 12, 13], value=[1., 2., 3., 4.]),
                                           'custom', 'value', startSeconds=10, timeFrom=.5, timeTo=2.5)
        self.assertEqual([point['timeSeconds'] for point in result['points']], [1, 2])
        self.assertEqual(result['outsideWindowSampleCount'], 2)
        self.assertEqual(result['validSampleCount'], 2)

    def test_many_segments_omitted_explicitly_and_never_connected(self):
        result = telemetry.extract_series(log(stamps=np.arange(100) * 20, value=np.arange(100, dtype=float)),
                                           'custom', 'value', budget=8)
        self.assertEqual(len(result['points']), 8)
        self.assertEqual(len({point['segment'] for point in result['points']}), 8)
        self.assertEqual(result['omittedSegmentCount'], 92)
        self.assertFalse(result['completeWindow'])

    def test_discrete_spike_preserves_before_after_pairs_and_step_metadata(self):
        values = np.zeros(10000, dtype=int); values[5001] = 6
        result = telemetry.extract_series(log(value=values), 'custom', 'value', budget=8)
        self.assertEqual(result['interpolation'], 'step')
        self.assertEqual(result['omittedTransitionCount'], 0)
        self.assertTrue({5000, 5001, 5002}.issubset({point['timeSeconds'] for point in result['points']}))

    def test_discrete_excess_transitions_report_loss(self):
        result = telemetry.extract_series(log(value=np.arange(100) % 2), 'custom', 'value', budget=10)
        self.assertLessEqual(len(result['points']), 10)
        self.assertGreater(result['omittedTransitionCount'], 0)
        self.assertEqual(result['coverage']['status'], 'partial')

    def test_small_budget_cannot_preserve_interior_extrema_reports_loss(self):
        result = telemetry.extract_series(log(value=[0., 99., 0.]), 'custom', 'value', budget=2)
        self.assertEqual(result['omittedExtremaCount'], 1)
        self.assertFalse(result['completeWindow'])

    def test_old_modern_gnss_unit_conversion_matches_with_provenance(self):
        old = telemetry.extract_series(log('sensor_gps', lat=[480000000, 481000000]), 'sensor_gps', 'lat')
        new = telemetry.extract_series(log('sensor_gps', latitude_deg=[48., 48.1]), 'sensor_gps', 'latitude_deg')
        for left, right in zip(old['points'], new['points']):
            self.assertAlmostEqual(left['value'], right['value'])
        self.assertEqual(old['unit'], 'deg')
        self.assertIn('v1.14.0', old['unitSource'])
        self.assertIn('v1.16.0', new['unitSource'])

    def test_battery_unknown_sentinels_not_false_zero_and_negative_current_valid(self):
        current = telemetry.extract_series(log('battery_status', current_a=[-2., -1., 3.]), 'battery_status', 'current_a')
        self.assertEqual([point['value'] for point in current['points']], [-2., 3.])
        self.assertEqual(current['sentinelRejectedCount'], 1)
        remaining = telemetry.extract_series(log('battery_status', remaining=[.5, -1., 1., 2.]), 'battery_status', 'remaining')
        self.assertEqual([point['value'] for point in remaining['points']], [50., 100.])
        self.assertEqual(remaining['unit'], '%')
        voltage = telemetry.extract_series(log('battery_status', voltage_v=[0., 12.]), 'battery_status', 'voltage_v')
        self.assertEqual(len(voltage['points']), 1)

    def test_ekf_array_component_units_are_different(self):
        for field, unit in [('output_tracking_error[0]', 'rad'), ('output_tracking_error[1]', 'm/s'), ('output_tracking_error[2]', 'm')]:
            self.assertEqual(telemetry.extract_series(log('estimator_status', **{field: [1., 2.]}), 'estimator_status', field)['unit'], unit)

    def test_instance_not_concatenated_and_missing_fields_reported(self):
        first = log('sensor_gps', instance=0, eph=[1., 2.]); second = log('sensor_gps', instance=1, eph=[50., 60.])
        first.data_list.extend(second.data_list)
        result = telemetry.extract_recipe(first, 'gnss', instance=1)
        self.assertEqual(len(result['series']), 1)
        self.assertEqual([point['value'] for point in result['series'][0]['points']], [50., 60.])
        self.assertEqual(len(result['missingFields']), 3)

    def test_four_curves_share_total_budget_and_more_than_four_refused(self):
        source = log('battery_status', **{field: np.linspace(.1, 1., 10000) for field in ('voltage_v', 'current_a', 'remaining', 'discharged_mah')})
        result = telemetry.extract_recipe(source, 'battery', budget=2048)
        self.assertEqual(len(result['series']), 4)
        self.assertLessEqual(result['displayedPointCount'], 2048)
        with self.assertRaises(ValueError): telemetry.extract_recipe(source, [('battery_status', 'voltage_v')] * 5)
        with self.assertRaises(ValueError): telemetry.extract_recipe(source, [('battery_status', 'voltage_v')] * 2)
        with self.assertRaises(ValueError): telemetry.extract_recipe(source, [('battery_status',)])

    def test_precision_lost_uint64_rejected_explicitly(self):
        result = telemetry.extract_series(log(flags=np.array([1, 2 ** 54, 2], dtype=np.uint64)), 'custom', 'flags')
        self.assertEqual(result['precisionRejectedCount'], 1)
        self.assertEqual([point['value'] for point in result['points']], [1, 2])
        self.assertNotEqual(result['points'][0]['segment'], result['points'][1]['segment'])

    def test_missing_timestamp_empty_and_invalid_request(self):
        empty = telemetry.extract_series(log(value=[]), 'custom', 'value')
        self.assertEqual(empty['coverage']['status'], 'absent')
        for kwargs in [{'budget': 1}, {'budget': 2049}, {'timeFrom': 3, 'timeTo': 2}, {'timeFrom': np.nan}, {'gapSeconds': 0}]:
            with self.assertRaises(ValueError): telemetry.extract_series(log(value=[1]), 'custom', 'value', **kwargs)
        source = log(value=[1]); del source.data_list[0].data['timestamp']
        with self.assertRaises(ValueError): telemetry.extract_series(source, 'custom', 'value')
        with self.assertRaises(KeyError): telemetry.extract_series(log(value=[1]), 'custom', 'missing')

    def test_large_source_uses_views_not_a_dictionary_per_sample(self):
        source = log(value=np.sin(np.arange(100_000) / 100))
        tracemalloc.start()
        try:
            result = telemetry.extract_series(source, 'custom', 'value')
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertLessEqual(len(result['points']), 2048)
        self.assertLess(peak, 3 * 1024 * 1024)

    def test_large_segment_count_does_not_allocate_a_descriptor_for_every_sample(self):
        source = log(stamps=np.arange(20_000) * 20, value=np.arange(20_000, dtype=float))
        tracemalloc.start()
        try:
            result = telemetry.extract_series(source, 'custom', 'value', budget=128)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(result['segmentCount'], 20_000)
        self.assertEqual(result['omittedSegmentCount'], 20_000 - 128)
        self.assertLess(peak, 3 * 1024 * 1024)


if __name__ == '__main__': unittest.main()

"""Incremental listing validation with bounded synthetic transport and loopback."""

import unittest
from unittest.mock import patch

from test_gcs_collect import BODY, REMOTE, UUID, Simulator, gcs


class ListingTransport:
    def __init__(self, messages):
        self.input = messages
        self.received = 0
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.closed = True

    def publish(self, *unused):
        pass

    def messages(self, seconds):
        for item in self.input:
            self.received += 1
            yield item


def raw(payload, **extra):
    return "send_mqtt_ftp_list", {"uuid": UUID, "payload": payload, **extra}


def end(path=gcs.LOG_ROOT, code=0):
    return "send_mqtt_ftp_end_session", {"uuid": UUID, "opcode": 0, "filename": path, "ret_code": code}


class MQTTListingBudgetTests(unittest.TestCase):
    def listing(self, messages, path=gcs.LOG_ROOT):
        self.transport = ListingTransport(messages)
        with patch.object(gcs, "MQTT", return_value=self.transport):
            return gcs.list_directory("gcs.local", 1999, UUID, path)

    def test_invalid_first_payload_is_rejected_before_receiving_more(self):
        cases = ["F" + "x" * (1024 * 1024) + ".ulg\t16", "D../outside",
                 "Fshort.ulg", "Fshort.ulg\tinvalid", "Fshort.ulg\t" + str(gcs.MAX_LOG_BYTES + 1)]
        for payload in cases:
            with self.subTest(prefix=payload[:25]):
                def messages():
                    yield raw(payload)
                    self.fail("The next message must not be requested after an invalid entry.")
                with self.assertRaises(gcs.CollectionError):
                    self.listing(messages())
                self.assertEqual(self.transport.received, 1)
                self.assertTrue(self.transport.closed)

    def test_multimessage_result_matches_structured_listing_with_duplicates_and_unicode(self):
        parent = gcs.LOG_ROOT
        expected = gcs.parse_listing({"directories": ["z", "é", "z"],
            "files": [["b.ULG", "16"], ["a.ulg", 17], ["b.ULG", 16], ["ignore.txt", "ignored"]]}, parent)
        messages = [raw("Dz\x00Fignore.txt\tignored\n"), raw("Dé\nFb.ULG\t16"),
                    raw("Dz\nFa.ulg\t17\nFb.ULG\t16"), end()]
        self.assertEqual(self.listing(messages), expected)
        self.assertTrue(self.transport.closed)

    def test_conflicting_size_is_rejected_on_the_conflicting_message(self):
        def messages():
            yield raw("Fsame.ulg\t16")
            yield raw("Fsame.ulg\t17")
            self.fail("Conflicting sizes must be rejected without waiting for end_session.")
        with self.assertRaisesRegex(gcs.CollectionError, "incohérente"):
            self.listing(messages())
        self.assertEqual(self.transport.received, 2)

    def test_utf8_byte_budget_is_cumulative_and_does_not_consume_the_next_message(self):
        payload = "Déé\n"
        with patch.object(gcs, "MAX_LISTING_BYTES", len(payload.encode()) * 2 - 1, create=True):
            def messages():
                yield raw(payload)
                yield raw(payload)
                self.fail("The cumulative byte budget must fail before the third message.")
            with self.assertRaisesRegex(gcs.CollectionError, "octets"):
                self.listing(messages())
        self.assertEqual(self.transport.received, 2)

    def test_maximum_counts_are_accepted_without_lowering_the_contract(self):
        name = "\U00010000" * (1024 - len(gcs.LOG_ROOT) - len("/.ulg")) + ".ulg"
        self.assertEqual(self.listing([raw(f"F{name}\t{gcs.MAX_LOG_BYTES}"), end()]),
                         ([], [{"path": gcs.LOG_ROOT + "/" + name, "size": gcs.MAX_LOG_BYTES}]))
        def messages():
            for offset in range(0, gcs.MAX_DIRECTORIES, 1000):
                yield raw("\n".join(f"Dd{i:05}" for i in range(offset, min(offset + 1000, gcs.MAX_DIRECTORIES))))
            for offset in range(0, gcs.MAX_FILES, 1000):
                yield raw("\n".join(f"Ff{i:06}.ulg\t{gcs.MAX_LOG_BYTES}" for i in range(offset, min(offset + 1000, gcs.MAX_FILES))))
            yield end()
        directories, files = self.listing(messages())
        self.assertEqual(len(directories), 4096)
        self.assertEqual(len(files), 100_000)
        self.assertEqual(files[0], {"path": gcs.LOG_ROOT + "/f000000.ulg", "size": gcs.MAX_LOG_BYTES})
        self.assertEqual(files[-1]["path"], gcs.LOG_ROOT + "/f099999.ulg")

    def test_duplicate_entries_still_count_towards_the_same_limits(self):
        for attribute, payload in (("MAX_DIRECTORIES", "Dsame"), ("MAX_FILES", "Fsame.ulg\t16")):
            with self.subTest(attribute=attribute), patch.object(gcs, attribute, 2):
                with self.assertRaisesRegex(gcs.CollectionError, "volumineux"):
                    self.listing([raw(payload), raw(payload), raw(payload), end()])

    def test_empty_end_cancellation_and_error_keep_existing_semantics(self):
        self.assertEqual(self.listing([raw(""), end()]), ([], []))
        with self.assertRaisesRegex(gcs.CollectionError, "Aucun listing"):
            self.listing([end()])
        with self.assertRaisesRegex(gcs.CollectionError, "code 3") as caught:
            self.listing([raw("Dvalid"), end(code=3)])
        self.assertTrue(caught.exception.retryable)
        def cancelled():
            yield raw("Dvalid")
            raise gcs.Cancelled("cancelled")
        with self.assertRaises(gcs.Cancelled):
            self.listing(cancelled())
        self.assertTrue(self.transport.closed)

    def test_raw_inventory_retains_fragmented_mqtt_transport_behavior(self):
        with Simulator() as simulator:
            simulator.raw = True
            self.assertTrue(simulator.fragment)
            self.assertEqual(gcs.inventory("127.0.0.1", simulator.port, UUID), [{"path": REMOTE, "size": len(BODY)}])


if __name__ == "__main__":
    unittest.main()

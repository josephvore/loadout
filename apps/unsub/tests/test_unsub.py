"""Offline checks for unsub.py's parsing and URL-safety helpers.

Run: python3 -I apps/unsub/tests/test_unsub.py  (no network, no Mail)
"""

import email
import email.policy
import importlib.util
import os
import socket
import sys
import unittest
import urllib.request
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("unsub", os.path.join(HERE, "..", "unsub.py"))
unsub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(unsub)


def resolves_to(*addrs):
    def fake(name, port, *args, **kwargs):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (a, port)) for a in addrs]
    return fake


class SafeToFetch(unittest.TestCase):
    def test_rejects_non_https_and_local_names(self):
        for url in ["http://example.com/u", "ftp://example.com/u", "https://localhost/u",
                    "https://printer.local/u", "https://intranet/u", "https://box.internal/u",
                    "https://127.0.0.1/u", "https://10.1.2.3/u", "https://192.168.0.5/u",
                    "https://169.254.169.254/latest", "https://[::1]/u", "https://example.com:bad/u"]:
            with self.subTest(url=url):
                self.assertFalse(unsub.safe_to_fetch(url))

    def test_public_ip_literal(self):
        self.assertTrue(unsub.safe_to_fetch("https://93.184.216.34/u"))

    def test_dns_name_must_resolve_publicly(self):
        with mock.patch.object(unsub.socket, "getaddrinfo", resolves_to("93.184.216.34")):
            self.assertTrue(unsub.safe_to_fetch("https://news.example.com/u"))
        with mock.patch.object(unsub.socket, "getaddrinfo", resolves_to("93.184.216.34", "10.0.0.7")):
            self.assertFalse(unsub.safe_to_fetch("https://news.example.com/u"))
        with mock.patch.object(unsub.socket, "getaddrinfo", side_effect=socket.gaierror("nope")):
            self.assertFalse(unsub.safe_to_fetch("https://news.example.com/u"))


class Requests(unittest.TestCase):
    def test_http_request_refuses_unsafe_url_without_network(self):
        with mock.patch.object(unsub._opener, "open") as opened:
            status, url, body = unsub.http_request("https://127.0.0.1/unsubscribe", data=b"x")
        opened.assert_not_called()
        self.assertEqual((status, body), (0, ""))

    def test_redirect_to_unsafe_target_is_blocked(self):
        handler = unsub.SafeRedirectHandler()
        req = urllib.request.Request("https://93.184.216.34/start")
        for target in ["http://93.184.216.34/next", "https://127.0.0.1/admin"]:
            with self.subTest(target=target), self.assertRaises(unsub.UnsafeURL):
                handler.redirect_request(req, None, 302, "Found", {}, target)

    def test_redirect_to_safe_target_is_followed(self):
        handler = unsub.SafeRedirectHandler()
        req = urllib.request.Request("https://93.184.216.34/start")
        new = handler.redirect_request(req, None, 302, "Found", {}, "https://93.184.216.35/done")
        self.assertEqual(new.full_url, "https://93.184.216.35/done")

    def test_form_action_goes_through_the_same_check(self):
        form = {"method": "post", "action": "https://10.0.0.1/submit", "fields": [], "buttons": []}
        with mock.patch.object(unsub._opener, "open") as opened:
            status, _, _ = unsub.submit_form("https://93.184.216.34/page", form, {}, None)
        opened.assert_not_called()
        self.assertEqual(status, 0)


class Parsing(unittest.TestCase):
    def test_mailto_keeps_plus_literal(self):
        to, subject, body = unsub.parse_mailto(
            "mailto:list+unsub@example.com?subject=remove%20me+now&body=bye")
        self.assertEqual(to, "list+unsub@example.com")
        self.assertEqual(subject, "remove me+now")
        self.assertEqual(body, "bye")

    def test_mailto_defaults(self):
        self.assertEqual(unsub.parse_mailto("mailto:a@example.com"),
                         ("a@example.com", "unsubscribe", "unsubscribe"))

    def test_list_unsubscribe_header(self):
        msg = email.message_from_string(
            "List-Unsubscribe: <mailto:u@example.com>, <https://example.com/u?id=1>\n"
            "List-Unsubscribe-Post: List-Unsubscribe=One-Click\n\nhi",
            policy=email.policy.default)
        self.assertEqual(unsub.list_unsubscribe(msg),
                         ("https://example.com/u?id=1", "mailto:u@example.com", True))


if __name__ == "__main__":
    unittest.main(verbosity=1)

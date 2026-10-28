"""Fetches Tone Central's remote resources for the page; Roland's servers send no CORS headers, so the page can't.

Only the hosts Tone Central uses are reachable, over HTTPS, and redirects are held to the same list, so the proxy
cannot be turned against other hosts.
"""

import urllib.error
import urllib.parse
import urllib.request

ALLOWED_HOSTS = frozenset(
    {
        "api.roland.com",  # URL definitions (katana_mk2.json)
        "bosstonecentral.com",  # liveset catalogue and .tsl files
        "www.youtube.com",  # iframe API for preview videos
        "w.soundcloud.com",  # player API for preview audio
        "api.soundcloud.com",
    }
)
TIMEOUT_SECONDS = 20


def checked_url(url):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or parts.hostname not in ALLOWED_HOSTS:
        raise PermissionError(f"refusing to proxy {url!r}")
    return urllib.parse.urlunsplit(("https", *parts[1:]))


class _AllowlistedRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return super().redirect_request(req, fp, code, msg, headers, checked_url(newurl))


_opener = urllib.request.build_opener(_AllowlistedRedirects)


def fetch(url):
    """Returns (status, content type, body); upstream HTTP errors pass through so the page sees them as such."""
    request = urllib.request.Request(checked_url(url), headers={"User-Agent": "Mozilla/5.0 (Macintosh)"})
    try:
        with _opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            return response.status, response.headers.get("Content-Type", "application/octet-stream"), response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.headers.get("Content-Type", "text/plain"), error.read()

#!/usr/bin/env python3
"""
Yacine TV Native macOS Backend & Crypto/HLS Stream Engine
Reverse-engineered from Yacine_TV_3.1_Black.apk (ver3.ycntivi.off, libpk-lib.so)
"""

from __future__ import annotations

import base64
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
import copy
import gzip
import hashlib
import http.client
import json
import os
import queue
import re
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ============================================================================
# 1. JNI Native Crypto Engine (dev.google.ytvclib.utils.C / libpk-lib.so)
# ============================================================================
MASTER_KEY_PREFIX = "c!xZj+N9&G@Ev@vw"
WMA_SALT = "WS9WMg"

DEFAULT_FALLBACK_HOSTS = [
    "def111.ycnapi.com",
    "tv.variety-buy.store",
    "deft.yacinelive.com",
]

FIREBASE_PROJECT_ID = os.environ.get("YACINE_FIREBASE_PROJECT", "").strip()
FIREBASE_API_KEY = os.environ.get("YACINE_FIREBASE_API_KEY", "").strip()
FIREBASE_APP_ID = os.environ.get("YACINE_FIREBASE_APP_ID", "").strip()
FIREBASE_RC_URL = (
    f"https://firebaseremoteconfig.googleapis.com/v1/projects/{FIREBASE_PROJECT_ID}/"
    f"namespaces/firebase:fetch?key={FIREBASE_API_KEY}"
    if FIREBASE_PROJECT_ID and FIREBASE_API_KEY
    else ""
)
OKHTTP_UA = "okhttp/4.12.0"

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


def pk_crpt(raw_bytes: bytes, key: str) -> bytes:
    """Exact implementation of crpt(std::string, const std::string&) from libpk-lib.so."""
    full_key = (MASTER_KEY_PREFIX + key).encode("utf-8")
    klen = len(full_key)
    return bytes(b ^ full_key[i % klen] for i, b in enumerate(raw_bytes))


def pk_dec(b64_str: str, key: str) -> str:
    """Exact implementation of Java_dev_google_ytvclib_utils_C_dec."""
    raw = base64.b64decode(b64_str.strip())
    return pk_crpt(raw, key).decode("utf-8", errors="replace")


def pk_enc(plain_str: str, key: str) -> str:
    """Exact implementation of Java_dev_google_ytvclib_utils_C_enc."""
    encrypted = pk_crpt(plain_str.encode("utf-8"), key)
    return base64.b64encode(encrypted).decode("ascii")


def pk_wma(wmp: str, ip: str, wmv: str, gmt_time_str: str = "") -> str:
    """Exact implementation of Java_dev_google_ytvclib_utils_C_wma (wmsAuthSign)."""
    if not gmt_time_str:
        now = datetime.now(timezone.utc)
        # Format matching SimpleDateFormat("M/d/y h:mm:ss a", Locale.US) in GMT
        hour12 = now.hour % 12 or 12
        ampm = "AM" if now.hour < 12 else "PM"
        gmt_time_str = f"{now.month}/{now.day}/{now.year} {hour12}:{now.minute:02d}:{now.second:02d} {ampm}"

    to_hash = f"{ip}{wmp}{WMA_SALT}{gmt_time_str}{wmv}".encode("utf-8")
    md5_raw_16 = hashlib.md5(to_hash).digest()
    hash_b64 = base64.b64encode(md5_raw_16).decode("ascii")
    payload = f"server_time={gmt_time_str}&hash_value={hash_b64}&validminutes={wmv}".encode("utf-8")
    return "?wmsAuthSign=" + base64.b64encode(payload).decode("ascii")


def b64u_encode(s: str) -> str:
    return base64.urlsafe_b64encode(s.encode("utf-8")).decode("ascii")


def b64u_decode(s: str) -> str:
    pad = "=" * ((4 - len(s) % 4) % 4)
    return base64.urlsafe_b64decode((s + pad).encode("ascii")).decode("utf-8", errors="replace")


DEFAULT_BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


class UpstreamHTTPError(Exception):
    """Represents an HTTP 4xx/5xx error returned by an upstream media host."""

    def __init__(self, status: int, reason: str, url: str):
        super().__init__(f"HTTP {status} {reason} for {url}")
        self.status = status
        self.reason = reason
        self.url = url


class _FastHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection with TCP_NODELAY enabled to eliminate Nagle framing stalls."""

    def connect(self):
        super().connect()
        if self.sock is not None:
            try:
                self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                pass


class _FastHTTPSConnection(http.client.HTTPSConnection):
    """HTTPSConnection with TCP_NODELAY enabled for low-latency TLS control and segment streaming."""

    def connect(self):
        super().connect()
        if self.sock is not None:
            try:
                self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                pass


class KeepAliveHTTPPool:
    """Thread-safe persistent HTTP/HTTPS connection pool per (scheme, host, port)."""

    def __init__(self, ssl_ctx: ssl.SSLContext):
        self.ssl_ctx = ssl_ctx
        self._lock = threading.Lock()
        self._pools: dict[tuple[str, str, int], queue.LifoQueue] = {}

    def _get_pool(self, key: tuple[str, str, int]) -> queue.LifoQueue:
        with self._lock:
            pool = self._pools.get(key)
            if pool is None:
                pool = queue.LifoQueue(maxsize=24)
                self._pools[key] = pool
            return pool

    def _acquire(self, scheme: str, host: str, port: int, timeout: float):
        pool = self._get_pool((scheme, host, port))
        while True:
            try:
                conn = pool.get_nowait()
            except queue.Empty:
                if scheme == "https":
                    return _FastHTTPSConnection(host, port, timeout=timeout, context=self.ssl_ctx), False
                return _FastHTTPConnection(host, port, timeout=timeout), False
            # Discard pooled sockets that have an unclosed response or closed transport
            if conn.sock is None or getattr(conn, "_HTTPConnection__response", None) is not None:
                try:
                    conn.close()
                except Exception:
                    pass
                continue
            conn.timeout = timeout
            conn.sock.settimeout(timeout)
            return conn, True

    def _release(self, scheme: str, host: str, port: int, conn, keep: bool):
        if not keep:
            try:
                conn.close()
            except Exception:
                pass
            return
        pool = self._get_pool((scheme, host, port))
        try:
            pool.put_nowait(conn)
        except queue.Full:
            try:
                conn.close()
            except Exception:
                pass

    def open_raw(self, url: str, method: str = "GET", headers: dict | None = None,
                 timeout: float = 12.0, max_redirects: int = 5):
        """Returns (conn, resp, final_url, pool_key) with caller owning release/close."""
        current_url = url
        req_headers = dict(headers or {})
        req_headers.setdefault("Accept-Encoding", "gzip, deflate")

        for _ in range(max_redirects + 1):
            parsed = urllib.parse.urlparse(current_url)
            scheme = parsed.scheme.lower() or "http"
            host = parsed.hostname or ""
            port = parsed.port or (443 if scheme == "https" else 80)
            path = parsed.path or "/"
            if parsed.query:
                path += "?" + parsed.query

            # Drain up to 4 stale pooled sockets before burning the single fresh-socket retry
            last_exc = None
            conn = None
            resp = None
            pooled_failures = 0
            fresh_failures = 0
            while fresh_failures < 2:
                conn, from_pool = self._acquire(scheme, host, port, timeout)
                try:
                    conn.request(method, path, headers=req_headers)
                    resp = conn.getresponse()
                    break
                except (http.client.HTTPException, OSError, EOFError) as exc:
                    last_exc = exc
                    try:
                        conn.close()
                    except Exception:
                        pass
                    conn = None
                    resp = None
                    if from_pool and pooled_failures < 4:
                        pooled_failures += 1
                        continue
                    fresh_failures += 1
                    if fresh_failures >= 2:
                        raise
            if resp is None:
                raise last_exc or RuntimeError(f"Failed request for {current_url}")

            if resp.status in (301, 302, 303, 307, 308):
                loc = resp.getheader("Location")
                # Drain and close response cleanly before reusing socket
                conn_hdr = (resp.getheader("Connection") or "").lower()
                will_close = resp.will_close
                fully_drained = False
                try:
                    resp.read()
                    resp.close()
                    fully_drained = resp.isclosed()
                except Exception:
                    pass
                self._release(scheme, host, port, conn, keep=fully_drained and (conn_hdr != "close") and not will_close)
                if not loc:
                    raise UpstreamHTTPError(resp.status, resp.reason, current_url)
                current_url = urllib.parse.urljoin(current_url, loc)
                continue

            if resp.status >= 400:
                conn_hdr = (resp.getheader("Connection") or "").lower()
                will_close = resp.will_close
                fully_drained = False
                try:
                    resp.read()
                    resp.close()
                    fully_drained = resp.isclosed()
                except Exception:
                    pass
                self._release(scheme, host, port, conn, keep=fully_drained and (conn_hdr != "close") and not will_close)
                raise UpstreamHTTPError(resp.status, resp.reason, current_url)

            return conn, resp, current_url, (scheme, host, port)

        raise RuntimeError(f"Too many redirects for {url}")

    def release_response(self, pool_key, conn, resp, fully_consumed: bool):
        keep = False
        if resp is not None:
            conn_hdr = (resp.getheader("Connection") or "").lower()
            will_close = resp.will_close
            if fully_consumed:
                try:
                    # read1() leaves resp.fp open at Content-Length EOF; close() detaches fp cleanly for keep-alive
                    resp.close()
                    keep = resp.isclosed() and (conn_hdr != "close") and not will_close
                except Exception:
                    keep = False
        self._release(pool_key[0], pool_key[1], pool_key[2], conn, keep=keep)

    def fetch_bytes(self, url: str, headers: dict | None = None, timeout: float = 12.0):
        conn, resp, final_url, pool_key = self.open_raw(
            url, method="GET", headers=headers, timeout=timeout
        )
        fully_read = False
        try:
            body = resp.read()
            fully_read = True
            resp_headers = {k.lower(): v for k, v in resp.getheaders()}
            status = resp.status
        finally:
            self.release_response(pool_key, conn, resp, fully_consumed=fully_read)

        body = decompress_body(body, resp_headers.get("content-encoding", ""))
        return status, resp_headers, final_url, body


def decompress_body(data: bytes, content_encoding: str = "") -> bytes:
    """Decompresses gzip or deflate HTTP payloads transparently."""
    if not data:
        return data
    enc = content_encoding.lower()
    if "gzip" in enc or data[:2] == b"\x1f\x8b":
        try:
            return gzip.decompress(data)
        except Exception:
            pass
    if "deflate" in enc:
        try:
            return zlib.decompress(data)
        except Exception:
            try:
                return zlib.decompress(data, -zlib.MAX_WBITS)
            except Exception:
                pass
    return data


def sanitize_header_text(val: str) -> str:
    """Strips invisible Unicode format/zero-width chars while preserving ASCII URLs."""
    return "".join(ch for ch in val if 0x20 <= ord(ch) < 0x7F).strip()


def latin1_safe_header(val: str) -> str:
    """
    Ensures UTF-8 invisible characters in Referer/headers are transmitted cleanly
    over Python's http.client (which encodes header strings using latin-1).
    """
    return val.encode("utf-8").decode("latin-1")


class TTLCache:
    """Thread-safe bounded LRU+TTL cache for short-lived API and master manifest caching."""

    def __init__(self, maxsize: int = 256):
        self.maxsize = maxsize
        self._lock = threading.Lock()
        self._items: OrderedDict[object, tuple[float, object]] = OrderedDict()

    def get(self, key: object):
        now = time.monotonic()
        with self._lock:
            entry = self._items.get(key)
            if entry is None:
                return None
            expires_at, value = entry
            if expires_at <= now:
                del self._items[key]
                return None
            self._items.move_to_end(key)
            return value

    def set(self, key: object, value: object, ttl: float):
        if ttl <= 0:
            return
        expires_at = time.monotonic() + ttl
        with self._lock:
            self._items[key] = (expires_at, value)
            self._items.move_to_end(key)
            while len(self._items) > self.maxsize:
                self._items.popitem(last=False)

    def clear(self):
        with self._lock:
            self._items.clear()


class SingleFlight:
    """Coalesces concurrent identical calls so duplicate upstream fetches are shared."""

    def __init__(self):
        self._lock = threading.Lock()
        self._inflight: dict[object, dict] = {}

    def do(self, key: object, fn):
        with self._lock:
            slot = self._inflight.get(key)
            if slot is None:
                slot = {"event": threading.Event(), "result": None, "error": None}
                self._inflight[key] = slot
                is_leader = True
            else:
                is_leader = False

        if not is_leader:
            slot["event"].wait()
            if slot["error"] is not None:
                raise slot["error"]
            return slot["result"]

        try:
            res = fn()
            slot["result"] = res
            return res
        except BaseException as exc:
            slot["error"] = exc
            raise
        finally:
            with self._lock:
                self._inflight.pop(key, None)
            slot["event"].set()


HTTP_POOL = KeepAliveHTTPPool(SSL_CTX)
API_CACHE = TTLCache(maxsize=256)
API_FLIGHT = SingleFlight()
M3U8_CACHE = TTLCache(maxsize=128)
M3U8_FLIGHT = SingleFlight()
HEADER_CACHE = TTLCache(maxsize=256)
PROBE_CACHE = TTLCache(maxsize=256)
PROBE_FLIGHT = SingleFlight()
EXTRACT_CACHE = TTLCache(maxsize=128)


# ============================================================================
# 2. Dynamic Host Discovery & API Client (HostInterceptor + CryptInterceptor)
# ============================================================================
class YacineApiClient:
    def __init__(self):
        self.lock = threading.Lock()
        self.active_host = DEFAULT_FALLBACK_HOSTS[0]
        self.config_cache = None
        self.config_ts = 0.0
        self.last_rc_fetch = 0
        self._warmup_done = threading.Event()
        # Run Firebase Remote Config + /config warmup off the startup critical path
        # so the local HTTP server binds immediately for zero-wait client launch.
        threading.Thread(target=self._background_warmup, name="yacine-warmup", daemon=True).start()

    def _background_warmup(self):
        try:
            self._resolve_remote_config_host()
            self._fetch_config_locked()
        finally:
            self._warmup_done.set()

    def get_active_host(self) -> str:
        with self.lock:
            return self.active_host

    def _resolve_remote_config_host(self):
        if not FIREBASE_RC_URL or not FIREBASE_APP_ID:
            return
        try:
            body = json.dumps({
                "appInstanceId": "a1b2c3d4e5f60718293a4b5c6d7e8f90",
                "appInstanceIdToken": "token",
                "appId": FIREBASE_APP_ID,
                "countryCode": "US",
                "languageCode": "en_US",
                "platformVersion": "33",
                "timeZone": "UTC",
                "appVersion": "3.1",
                "appBuild": "56",
                "packageName": "ver3.ycntivi.off",
                "sdkVersion": "21.2.0",
            }).encode("utf-8")
            req = urllib.request.Request(
                FIREBASE_RC_URL,
                data=body,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=8, context=SSL_CTX) as resp:
                rc = json.loads(resp.read().decode("utf-8"))
                entries = rc.get("entries", {})
                host = entries.get("defaults", "").strip()
                if host:
                    with self.lock:
                        self.active_host = host
                        self.last_rc_fetch = time.time()
        except Exception as e:
            sys.stderr.write(f"[FRC] Warning: {e}\n")

    def api_get(self, endpoint_path: str) -> dict:
        with self.lock:
            current_host = self.active_host
        hosts_to_try = [current_host] + [
            h for h in DEFAULT_FALLBACK_HOSTS if h != current_host
        ]
        last_err = None
        clean_ep = endpoint_path.lstrip("/")
        hdrs = {
            "Accept": "application/json",
            "User-Agent": OKHTTP_UA,
        }
        for host in hosts_to_try:
            url = f"https://{host}/api/{clean_ep}"
            try:
                _, resp_hdrs, _, body_bytes = HTTP_POOL.fetch_bytes(url, headers=hdrs, timeout=12.0)
                t_hdr = resp_hdrs.get("t") or str(int(time.time() * 1000))[:10]
                decrypted_json = pk_dec(body_bytes.decode("utf-8"), t_hdr)
                data = json.loads(decrypted_json)
                with self.lock:
                    self.active_host = host
                return data
            except Exception as e:
                last_err = e
                continue
        raise RuntimeError(f"All API hosts failed for /{endpoint_path}: {last_err}")

    def api_get_cached(self, endpoint_path: str, ttl: float, force_refresh: bool = False) -> dict:
        if not force_refresh:
            cached = API_CACHE.get(endpoint_path)
            if cached is not None:
                return copy.deepcopy(cached)

        def _fetch():
            if not force_refresh:
                again = API_CACHE.get(endpoint_path)
                if again is not None:
                    return again
            data = self.api_get(endpoint_path)
            API_CACHE.set(endpoint_path, data, ttl)
            return data

        result = API_FLIGHT.do(("api", endpoint_path, force_refresh), _fetch)
        return copy.deepcopy(result)

    def _fetch_config_locked(self) -> dict:
        now = time.monotonic()
        with self.lock:
            if self.config_cache is not None and (now - self.config_ts) < 180.0:
                return self.config_cache
        try:
            cfg = self.api_get("config").get("data", {})
        except Exception:
            cfg = None
        with self.lock:
            if cfg:
                self.config_cache = cfg
                self.config_ts = time.monotonic()
            elif self.config_cache is None:
                self.config_cache = {}
            return self.config_cache

    def get_config(self, wait: bool = True) -> dict:
        now = time.monotonic()
        with self.lock:
            if self.config_cache is not None and (now - self.config_ts) < 180.0:
                return self.config_cache
            cached = self.config_cache
        if not wait:
            return cached or {}
        self._warmup_done.wait(timeout=5.0)
        return self._fetch_config_locked()

    def enrich_streams(self, resp_data: dict, probe: bool = True, force_refresh: bool = False) -> dict:
        cfg = self.get_config(wait=True)
        player_cfg = cfg.get("player") or {}
        wmp = str(player_cfg.get("wmp") or "")
        ip = str(player_cfg.get("ip") or "0.0.0.0")
        wmv = str(player_cfg.get("wmv") or "5")

        streams = resp_data.get("data") or []
        for s in streams:
            raw_url = s.get("url") or ""
            url_type = s.get("url_type", 1)
            resolved_url = raw_url
            keyword = ""

            if url_type == 2 and raw_url:
                resolved_url = raw_url + pk_wma(wmp, ip, wmv)
            elif url_type in (1, 6) and "$$" in raw_url:
                parts = raw_url.split("$$", 1)
                resolved_url = parts[0].strip()
                keyword = parts[1].strip() or ("m3u8" if url_type == 6 else "")
            elif url_type == 6:
                keyword = "m3u8"

            s["resolved_url"] = resolved_url
            s["keyword"] = keyword

            headers = s.get("headers") or {}
            ua = (
                s.get("user_agent")
                or headers.get("User-Agent")
                or headers.get("user-agent")
                or DEFAULT_BROWSER_UA
            )
            ref = headers.get("Referer") or headers.get("referer") or s.get("referer") or ""

            s["effective_ua"] = ua
            s["effective_ref"] = ref
            s["proxy_url"] = (
                f"/proxy/m3u8?u={b64u_encode(resolved_url)}"
                f"&ua={b64u_encode(ua)}"
                f"&ref={b64u_encode(ref)}"
            )

        if probe and streams:
            _probe_and_rank_streams(resp_data, force_refresh=force_refresh)
        return resp_data


API_CLIENT = YacineApiClient()
UI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "ui"))


def _build_upstream_headers(ua: str, ref: str, include_origin: bool = False, cookie: str = "") -> dict:
    hdrs = {
        "Accept": "*/*",
        "Accept-Encoding": "gzip, deflate",
        "Connection": "keep-alive",
    }
    if ua:
        hdrs["User-Agent"] = latin1_safe_header(ua)
    if ref:
        hdrs["Referer"] = latin1_safe_header(ref)
        if include_origin:
            try:
                clean_ref = sanitize_header_text(ref)
                p = urllib.parse.urlparse(clean_ref)
                if p.scheme and p.netloc:
                    hdrs["Origin"] = f"{p.scheme}://{p.netloc}"
            except Exception:
                pass
    if cookie:
        hdrs["Cookie"] = latin1_safe_header(cookie)
    return hdrs


def _build_header_candidates(ua: str, ref: str, target_url: str = "") -> list[tuple[str, str, bool]]:
    """Ordered header attempts: put cached host winner first, then exact API headers, then fallbacks."""
    base_ua = ua or DEFAULT_BROWSER_UA
    raw_list: list[tuple[str, str, bool]] = [(base_ua, ref, False)]
    clean_ref = sanitize_header_text(ref) if ref else ""
    if ref and clean_ref != ref:
        raw_list.append((base_ua, clean_ref, False))
    if ref:
        if clean_ref:
            raw_list.append((base_ua, clean_ref, True))
        raw_list.append((base_ua, "", False))
    if base_ua != DEFAULT_BROWSER_UA:
        if clean_ref:
            raw_list.append((DEFAULT_BROWSER_UA, clean_ref, False))
        raw_list.append((DEFAULT_BROWSER_UA, "", False))

    if target_url:
        p = urllib.parse.urlparse(target_url)
        cached = HEADER_CACHE.get((p.scheme.lower(), p.hostname or "", ua, ref))
        if cached is not None:
            raw_list.insert(0, cached)

    seen = set()
    deduped = []
    for item in raw_list:
        if item not in seen:
            seen.add(item)
            deduped.append(item)
    return deduped


def _dash_to_hls_candidates(url: str) -> list[str]:
    """Maps Wowza-style .mpd URLs (e.g. manifest*.mpd) to HLS playlist.m3u8 / index.m3u8 preserving queries."""
    parsed = urllib.parse.urlparse(url)
    if not parsed.path.lower().endswith(".mpd"):
        return []
    dir_path = parsed.path.rsplit("/", 1)[0] if "/" in parsed.path else ""
    out = []
    for name in ("playlist.m3u8", "index.m3u8"):
        new_path = f"{dir_path}/{name}" if dir_path else f"/{name}"
        out.append(urllib.parse.urlunparse(parsed._replace(path=new_path)))
    return out


def _fetch_with_fallback(target_url: str, ua: str, ref: str, cookie: str = "", timeout: float = 12.0):
    """Fetches a URL with automatic retry on 400/401/403 caused by poisoned Referer/Origin headers."""
    last_err = None
    parsed = urllib.parse.urlparse(target_url)
    cache_key = (parsed.scheme.lower(), parsed.hostname or "", ua, ref)
    for cand_ua, cand_ref, include_origin in _build_header_candidates(ua, ref, target_url=target_url):
        hdrs = _build_upstream_headers(cand_ua, cand_ref, include_origin=include_origin, cookie=cookie)
        try:
            status, resp_hdrs, final_url, body = HTTP_POOL.fetch_bytes(
                target_url, headers=hdrs, timeout=timeout
            )
            HEADER_CACHE.set(cache_key, (cand_ua, cand_ref, include_origin), ttl=300.0)
            return status, resp_hdrs, final_url, body, cand_ua, cand_ref
        except UpstreamHTTPError as e:
            last_err = e
            if e.status in (400, 401, 403):
                continue
            raise
    if last_err is not None:
        raise last_err
    raise RuntimeError(f"Failed to fetch {target_url}")


def _fetch_m3u8_resolved(target_url: str, ua: str, ref: str, cookie: str = "", timeout: float = 12.0):
    """Fetches an HLS playlist, transparently converting Wowza .mpd URLs to playlist.m3u8."""
    hls_cands = _dash_to_hls_candidates(target_url)
    if hls_cands:
        last_err = None
        for hls_u in hls_cands:
            try:
                res = _fetch_with_fallback(hls_u, ua, ref, cookie=cookie, timeout=timeout)
                if b"#EXTM3U" in res[3][:512]:
                    return res
            except Exception as exc:
                last_err = exc
        if last_err is not None:
            try:
                return _fetch_with_fallback(target_url, ua, ref, cookie=cookie, timeout=timeout)
            except Exception:
                raise last_err

    res = _fetch_with_fallback(target_url, ua, ref, cookie=cookie, timeout=timeout)
    _, _, final_url, body, _, _ = res
    if b"#EXTM3U" not in body[:512]:
        # Handle redirects or responses that expose an .mpd path/body
        if b"<MPD" in body[:512] or urllib.parse.urlparse(final_url).path.lower().endswith(".mpd"):
            for hls_u in _dash_to_hls_candidates(final_url):
                try:
                    hls_res = _fetch_with_fallback(hls_u, ua, ref, cookie=cookie, timeout=timeout)
                    if b"#EXTM3U" in hls_res[3][:512]:
                        return hls_res
                except Exception:
                    continue
    return res


def _fetch_m3u8_coalesced(target_url: str, ua: str, ref: str, cookie: str = "", timeout: float = 12.0):
    """Deduplicates concurrent M3U8 fetches and briefly caches master manifests across /proxy/m3u8 & /api/variants."""
    cache_key = ("m3u8", target_url, ua, ref, cookie)
    cached = M3U8_CACHE.get(cache_key)
    if cached is not None:
        return cached

    def _run():
        again = M3U8_CACHE.get(cache_key)
        if again is not None:
            return again
        res = _fetch_m3u8_resolved(target_url, ua, ref, cookie=cookie, timeout=timeout)
        _, _, _, body, _, _ = res
        # Only cache master variant playlists; live chunklists must stay real-time.
        if b"#EXT-X-STREAM-INF" in body:
            M3U8_CACHE.set(cache_key, res, ttl=8.0)
        return res

    return M3U8_FLIGHT.do(cache_key, _run)


def _parse_variant_info(inf_line: str, abs_url: str) -> dict:
    """Extracts resolution, bandwidth, frame rate, codecs, label and sort key from #EXT-X-STREAM-INF."""
    bw = 0
    m_bw = re.search(r'(?:^|[,:\s])BANDWIDTH=(\d+)', inf_line)
    if m_bw:
        bw = int(m_bw.group(1))

    avg_bw = 0
    m_avg = re.search(r'AVERAGE-BANDWIDTH=(\d+)', inf_line)
    if m_avg:
        avg_bw = int(m_avg.group(1))

    w, h = 0, 0
    m_res = re.search(r'RESOLUTION=(\d+)x(\d+)', inf_line)
    if m_res:
        w, h = int(m_res.group(1)), int(m_res.group(2))
    else:
        m_hint = re.search(r'(?:_|/|-)(2160|1440|1080|720|576|540|480|360|288|240|144)p?\b', abs_url, re.I)
        if m_hint:
            h = int(m_hint.group(1))
            w = (h * 16) // 9

    fps = 0.0
    m_fps = re.search(r'FRAME-RATE=([\d.]+)', inf_line)
    if m_fps:
        try:
            fps = float(m_fps.group(1))
        except ValueError:
            fps = 0.0

    codecs = ""
    m_codecs = re.search(r'CODECS="([^"]+)"', inf_line)
    if m_codecs:
        codecs = m_codecs.group(1).strip()

    codecs_low = codecs.lower()
    has_video_codec = any(tok in codecs_low for tok in ("avc", "hvc", "hev", "dvh", "av01", "vp09", "mp4v"))
    has_audio_codec = any(tok in codecs_low for tok in ("mp4a", "ac-3", "ec-3", "opus", "flac"))
    is_audio_only = (h == 0) and (
        'VIDEO="none"' in inf_line or (codecs_low != "" and has_audio_codec and not has_video_codec)
    )

    if any(tok in codecs_low for tok in ("hvc1", "hev1", "dvh1", "av01")):
        codec_rank = 2
    elif not is_audio_only and (h > 0 or has_video_codec):
        codec_rank = 1
    else:
        codec_rank = 0

    fps_tag = int(round(fps)) if fps >= 45.0 else 0
    eff_bw = avg_bw or bw
    if h > 0:
        base_label = f"{h}p{fps_tag}" if fps_tag else f"{h}p"
    elif is_audio_only:
        base_label = "Audio"
    elif eff_bw >= 1_000_000:
        base_label = f"{eff_bw / 1_000_000:.1f}M"
    elif eff_bw > 0:
        base_label = f"{eff_bw // 1000}k"
    else:
        base_label = "Stream"

    return {
        "sort_key": (not is_audio_only, h, w, round(fps, 1), codec_rank, eff_bw, bw),
        "height": h,
        "width": w,
        "bandwidth": bw,
        "avg_bandwidth": avg_bw,
        "fps": fps,
        "codecs": codecs,
        "is_audio_only": is_audio_only,
        "label": base_label,
        "eff_bw": eff_bw,
    }


def _parse_master_variants(lines: list[str], final_url: str, uri_rewriter=None):
    """Parses a master playlist into (header_lines, sorted_variant_blocks)."""
    header_lines = []
    variant_blocks = []
    pending_inf_lines: list[str] = []

    for line in lines:
        sline = line.strip()
        if not sline:
            continue
        if sline.startswith("#EXT-X-STREAM-INF"):
            if pending_inf_lines:
                pending_inf_lines = [sline]
            else:
                pending_inf_lines.append(sline)
            continue
        if pending_inf_lines:
            if sline.startswith("#"):
                pending_inf_lines.append(uri_rewriter(sline) if uri_rewriter else sline)
                continue
            abs_u = urllib.parse.urljoin(final_url, sline)
            info = _parse_variant_info("\n".join(pending_inf_lines), abs_u)
            info["inf_lines"] = pending_inf_lines
            info["abs_url"] = abs_u
            variant_blocks.append(info)
            pending_inf_lines = []
            continue

        header_lines.append(uri_rewriter(sline) if uri_rewriter else sline)

    # Sort descending: non-audio -> height -> width -> fps -> codec -> avg/peak bandwidth
    variant_blocks.sort(key=lambda v: v["sort_key"], reverse=True)

    # Disambiguate duplicate resolution+fps labels using effective bitrate (e.g. "720p · 4.5M")
    label_counts: dict[str, int] = {}
    for vb in variant_blocks:
        label_counts[vb["label"]] = label_counts.get(vb["label"], 0) + 1
    for vb in variant_blocks:
        lbl = vb["label"]
        ebw = vb["eff_bw"]
        if label_counts.get(lbl, 0) > 1 and ebw > 0:
            bw_str = f"{ebw / 1_000_000:.1f}M" if ebw >= 1_000_000 else f"{ebw // 1000}k"
            vb["display_label"] = f"{lbl} · {bw_str}"
        else:
            vb["display_label"] = lbl

    return header_lines, variant_blocks


def _rewrite_and_sort_m3u8(
    raw_text: str,
    final_url: str,
    ua_b64: str,
    ref_b64: str,
    variant_idx: int | None = None,
    ck_b64: str = "",
):
    """Rewrites playlist URIs to local proxy, sorting master variants highest-first for optimal ABR."""
    ck_q = f"&ck={ck_b64}" if ck_b64 else ""

    def make_m3u8_proxy(abs_u: str) -> str:
        return f"/proxy/m3u8?u={b64u_encode(abs_u)}&ua={ua_b64}&ref={ref_b64}{ck_q}"

    def make_seg_proxy(abs_u: str) -> str:
        return f"/proxy/seg.ts?u={b64u_encode(abs_u)}&ua={ua_b64}&ref={ref_b64}{ck_q}"

    def replace_uri_attr(match):
        uri_val = match.group(1)
        abs_u = urllib.parse.urljoin(final_url, uri_val)
        if ".m3u8" in abs_u.lower():
            return f'URI="{make_m3u8_proxy(abs_u)}"'
        return f'URI="{make_seg_proxy(abs_u)}"'

    def rewrite_tag_line(sline: str) -> str:
        if 'URI="' not in sline:
            return sline
        if sline.startswith("#EXT-X-MEDIA"):
            return re.sub(
                r'URI="([^"]+)"',
                lambda m: f'URI="{make_m3u8_proxy(urllib.parse.urljoin(final_url, m.group(1)))}"',
                sline,
            )
        return re.sub(r'URI="([^"]+)"', replace_uri_attr, sline)

    lines = raw_text.splitlines()
    is_master = any(ln.strip().startswith("#EXT-X-STREAM-INF") for ln in lines)

    if not is_master:
        out = []
        for line in lines:
            sline = line.strip()
            if not sline:
                out.append(line)
                continue
            if sline.startswith("#"):
                out.append(rewrite_tag_line(sline))
            else:
                abs_u = urllib.parse.urljoin(final_url, sline)
                parsed_u = urllib.parse.urlparse(abs_u)
                if parsed_u.path.lower().endswith(".m3u8"):
                    out.append(make_m3u8_proxy(abs_u))
                else:
                    out.append(make_seg_proxy(abs_u))
        return "\n".join(out) + "\n", [], False

    header_lines, variant_blocks = _parse_master_variants(lines, final_url, uri_rewriter=rewrite_tag_line)

    meta_variants = []
    for idx, vb in enumerate(variant_blocks):
        meta_variants.append({
            "index": idx,
            "label": vb["label"],
            "display_label": vb["display_label"],
            "resolution": f"{vb['width']}x{vb['height']}" if vb["height"] > 0 else "",
            "bandwidth": vb["bandwidth"],
            "avg_bandwidth": vb["avg_bandwidth"] or None,
            "fps": round(vb["fps"], 2) if vb["fps"] > 0 else None,
            "codecs": vb["codecs"] or None,
            "is_audio_only": vb["is_audio_only"],
            "proxy_url": f"/proxy/m3u8?u={b64u_encode(final_url)}&ua={ua_b64}&ref={ref_b64}{ck_q}&variant={idx}",
        })

    selected_blocks = variant_blocks
    if variant_idx is not None and 0 <= variant_idx < len(variant_blocks):
        selected_blocks = [variant_blocks[variant_idx]]

    out_lines = list(header_lines)
    for vb in selected_blocks:
        out_lines.extend(vb["inf_lines"])
        out_lines.append(make_m3u8_proxy(vb["abs_url"]))

    return "\n".join(out_lines) + "\n", meta_variants, True


def _estimate_single_bitrate(raw_text: str, final_url: str, ua: str, ref: str, cookie: str = "") -> int:
    """Best-effort bitrate estimate for single-bitrate media playlists via a single HEAD on first segment."""
    seg_dur = 0.0
    first_seg = ""
    lines = raw_text.splitlines()
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith("#EXTINF:"):
            try:
                seg_dur = float(s.split(":", 1)[1].split(",", 1)[0].strip())
            except ValueError:
                seg_dur = 0.0
            for j in range(i + 1, min(i + 6, len(lines))):
                cand = lines[j].strip()
                if cand and not cand.startswith("#"):
                    first_seg = urllib.parse.urljoin(final_url, cand)
                    break
            if first_seg:
                break
    if not first_seg or seg_dur <= 0.1:
        return 0
    try:
        hdrs = _build_upstream_headers(ua, ref, cookie=cookie)
        hdrs["Accept-Encoding"] = "identity"
        conn, resp, _, pool_key = HTTP_POOL.open_raw(first_seg, method="HEAD", headers=hdrs, timeout=1.4)
        clen = 0
        fully_read = False
        try:
            resp.read()
            fully_read = True
            cl_hdr = resp.getheader("Content-Length")
            if cl_hdr and cl_hdr.isdigit():
                clen = int(cl_hdr)
        finally:
            HTTP_POOL.release_response(pool_key, conn, resp, fully_consumed=fully_read)
        if clen > 4096:
            return int((clen * 8) / seg_dur)
    except Exception:
        pass
    return 0


def _probe_playlist_quality(
    url: str,
    ua: str,
    ref: str,
    cookie: str = "",
    timeout: float = 2.6,
    verify_segment: bool = True,
) -> dict:
    """Verifies a stream URL is actually playable and returns its true top resolution/fps/bitrate."""
    out = {
        "ok": None,
        "effective_url": url,
        "is_master": False,
        "max_height": 0,
        "max_width": 0,
        "max_fps": 0.0,
        "max_bandwidth": 0,
        "label": "",
        "used_ua": ua,
        "used_ref": ref,
    }
    try:
        _, _, final_url, body, used_ua, used_ref = _fetch_m3u8_resolved(
            url, ua, ref, cookie=cookie, timeout=timeout
        )
    except UpstreamHTTPError:
        out["ok"] = False
        out["label"] = "Offline"
        return out
    except (TimeoutError, socket.timeout):
        return out
    except Exception:
        out["ok"] = False
        out["label"] = "Offline"
        return out

    text = body.decode("utf-8", errors="replace")
    if "#EXTM3U" not in text:
        out["ok"] = False
        return out

    out["effective_url"] = final_url
    out["used_ua"] = used_ua
    out["used_ref"] = used_ref

    lines = text.splitlines()
    if any(ln.strip().startswith("#EXT-X-STREAM-INF") for ln in lines):
        out["is_master"] = True
        _, variants = _parse_master_variants(lines, final_url)
        video_vars = [v for v in variants if not v["is_audio_only"]] or variants
        if not video_vars:
            out["ok"] = False
            out["label"] = "Offline"
            return out

        top = video_vars[0]
        if not verify_segment:
            out.update({
                "ok": True,
                "max_height": top["height"],
                "max_width": top["width"],
                "max_fps": top["fps"],
                "max_bandwidth": top["eff_bw"] or top["bandwidth"],
                "label": top["label"],
            })
            return out

        # Confirm child chunklist returns 200 with segments (catches dead 404 MediaPackage masters)
        saw_timeout = False
        for cand_v in video_vars[:2]:
            try:
                _, _, _, c_body, _, _ = _fetch_with_fallback(
                    cand_v["abs_url"], used_ua, used_ref, cookie=cookie, timeout=min(timeout, 2.0)
                )
                c_text = c_body.decode("utf-8", errors="replace")
                if "#EXTM3U" in c_text and ("#EXTINF" in c_text or "#EXT-X-MAP" in c_text):
                    out.update({
                        "ok": True,
                        "max_height": cand_v["height"],
                        "max_width": cand_v["width"],
                        "max_fps": cand_v["fps"],
                        "max_bandwidth": cand_v["eff_bw"] or cand_v["bandwidth"],
                        "label": cand_v["label"],
                    })
                    return out
            except (TimeoutError, socket.timeout):
                saw_timeout = True
            except UpstreamHTTPError:
                continue
            except Exception:
                continue

        if saw_timeout:
            out.update({
                "ok": None,
                "max_height": top["height"],
                "max_width": top["width"],
                "max_fps": top["fps"],
                "max_bandwidth": top["eff_bw"] or top["bandwidth"],
                "label": top["label"],
            })
            return out

        out["ok"] = False
        out["label"] = "Offline"
        return out

    # Single-bitrate live media playlist
    if "#EXTINF" not in text and "#EXT-X-MAP" not in text:
        out["ok"] = False
        out["label"] = "Offline"
        return out

    est_bw = _estimate_single_bitrate(text, final_url, used_ua, used_ref, cookie=cookie) if verify_segment else 0
    m_hint = re.search(r'(?:_|/|-)(2160|1440|1080|720|576|540|480|360|288|240|144)p?\b', final_url, re.I)
    h = int(m_hint.group(1)) if m_hint else 0
    w = (h * 16) // 9 if h > 0 else 0
    if h > 0:
        lbl = f"{h}p"
    elif est_bw >= 1_000_000:
        lbl = f"{est_bw / 1_000_000:.1f}M"
    elif est_bw > 0:
        lbl = f"{est_bw // 1000}k"
    else:
        lbl = "Live"

    out.update({
        "ok": True,
        "max_height": h,
        "max_width": w,
        "max_fps": 0.0,
        "max_bandwidth": est_bw,
        "label": lbl,
    })
    return out


def _probe_single_cached(url: str, ua: str, ref: str, force_refresh: bool = False) -> dict:
    key = ("probe", url, ua, ref)
    if not force_refresh:
        cached = PROBE_CACHE.get(key)
        if cached is not None:
            return cached

    def _run():
        if not force_refresh:
            again = PROBE_CACHE.get(key)
            if again is not None:
                return again
        res = _probe_playlist_quality(url, ua, ref, timeout=2.0, verify_segment=True)
        PROBE_CACHE.set(key, res, ttl=15.0)
        return res

    return PROBE_FLIGHT.do(key, _run)


def _probe_and_rank_streams(resp_data: dict, force_refresh: bool = False):
    """Probes direct servers in parallel, converts .mpd->.m3u8, and sets recommended_index/order."""
    streams = resp_data.get("data") or []
    direct_indices = [i for i, s in enumerate(streams) if s.get("url_type", 1) in (1, 2, 3) and s.get("resolved_url")]

    probe_results: dict[int, dict] = {}
    if direct_indices:
        from concurrent.futures import wait as wait_futures
        ex = ThreadPoolExecutor(max_workers=min(6, len(direct_indices)))
        try:
            fmap = {
                ex.submit(
                    _probe_single_cached,
                    streams[i]["resolved_url"],
                    streams[i]["effective_ua"],
                    streams[i]["effective_ref"],
                    force_refresh,
                ): i
                for i in direct_indices
            }
            done, _ = wait_futures(fmap.keys(), timeout=2.2)
            for fut in done:
                idx = fmap[fut]
                try:
                    probe_results[idx] = fut.result()
                except Exception:
                    pass
        finally:
            ex.shutdown(wait=False)

    ranked: list[tuple[tuple, int]] = []
    for i, s in enumerate(streams):
        url_type = s.get("url_type", 1)
        if url_type in (1, 2, 3):
            pr = probe_results.get(i)
            if pr is None:
                s["probe_ok"] = None
                s["probe_height"] = 0
                s["probe_fps"] = 0.0
                s["probe_bandwidth"] = 0
                s["probe_label"] = ""
                tier = 1
            else:
                ok = pr.get("ok")
                s["probe_ok"] = ok
                s["probe_height"] = pr.get("max_height", 0)
                s["probe_fps"] = round(pr.get("max_fps", 0.0), 2)
                s["probe_bandwidth"] = pr.get("max_bandwidth", 0)
                s["probe_label"] = pr.get("label", "")
                eff_u = pr.get("effective_url")
                if ok is True and eff_u and eff_u != s["resolved_url"]:
                    s["resolved_url"] = eff_u
                    s["proxy_url"] = (
                        f"/proxy/m3u8?u={b64u_encode(eff_u)}"
                        f"&ua={b64u_encode(s['effective_ua'])}"
                        f"&ref={b64u_encode(s['effective_ref'])}"
                    )
                tier = 3 if ok is True else (0 if ok is False else 1)
        else:
            s["probe_ok"] = None
            s["probe_height"] = 0
            s["probe_fps"] = 0.0
            s["probe_bandwidth"] = 0
            s["probe_label"] = "Web"
            tier = 2

        score = (
            tier,
            s["probe_height"],
            round(s["probe_fps"], 1),
            s["probe_bandwidth"],
            -i,
        )
        ranked.append((score, i))

    ranked.sort(key=lambda item: item[0], reverse=True)
    order = [idx for _, idx in ranked] if ranked else [0]
    resp_data["recommended_index"] = order[0]
    resp_data["recommended_order"] = order


def _collect_html_candidates(
    html_text: str,
    page_url: str,
    ua: str,
    ref: str,
    cookie: str = "",
    depth: int = 0,
    visited: set[str] | None = None,
) -> list[tuple[str, str]]:
    """Collects (stream_url, source_page_url) pairs across absolute, relative, and iframe/player embeds."""
    if visited is None:
        visited = set()
    visited.add(page_url)

    normalized = (
        html_text.replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("&amp;", "&")
    )
    skip_domains = ("doubleclick", "googlesyndication", "analytics", "googletagmanager")
    found: list[tuple[str, str]] = []

    def add_cand(raw_u: str):
        clean_u = raw_u.strip().rstrip("\\,;)")
        if not clean_u or clean_u.startswith("data:"):
            return
        abs_u = urllib.parse.urljoin(page_url, clean_u)
        low = abs_u.lower()
        if any(sk in low for sk in skip_domains):
            return
        # Expand Wowza .mpd candidates cleanly alongside .m3u8 links
        if urllib.parse.urlparse(abs_u).path.lower().endswith(".mpd"):
            for hls_u in _dash_to_hls_candidates(abs_u):
                found.append((hls_u, page_url))
        else:
            found.append((abs_u, page_url))

    for c in re.findall(r'https?://[^\s"\'<>\\`]+(?:\.m3u8|\.mpd)[^\s"\'<>\\`]*', normalized, re.I):
        add_cand(c)
    for rel in re.findall(r'["\']([^"\'\s<>\\]+\.(?:m3u8|mpd)(?:\?[^"\'\s<>\\]*)?)["\']', normalized, re.I):
        add_cand(rel)

    if depth < 2:
        iframe_srcs = re.findall(r'<iframe[^>]+src=["\']([^"\']+)["\']', html_text, re.I)
        # Also catch inline JS player iframe URLs (e.g. '/player/index.php?id=...')
        iframe_srcs += re.findall(r'["\'](/[^"\'\s<>]*player[^"\'\s<>]*)["\']', normalized, re.I)
        sub_urls = []
        skip_hosts = ("youtube.com", "youtu.be", "dailymotion.com", "twitch.tv", "facebook.com", "twitter.com", "instagram.com")
        for raw_src in iframe_srcs:
            if raw_src.startswith("data:") or raw_src.startswith("about:") or raw_src.startswith("javascript:"):
                continue
            sub_u = urllib.parse.urljoin(page_url, raw_src)
            low_i = sub_u.lower()
            if sub_u in visited or any(sh in low_i for sh in skip_hosts):
                continue
            if low_i.endswith((".js", ".css", ".png", ".jpg", ".svg", ".ico")):
                continue
            visited.add(sub_u)
            sub_urls.append(sub_u)
            if len(sub_urls) >= 10:
                break

        if sub_urls:
            def _fetch_sub(sub_u: str):
                _, _, final_i, body, _, _ = _fetch_with_fallback(
                    sub_u, ua or DEFAULT_BROWSER_UA, page_url, cookie=cookie, timeout=6.0
                )
                return _collect_html_candidates(
                    body.decode("utf-8", errors="replace"),
                    final_i,
                    ua or DEFAULT_BROWSER_UA,
                    page_url,
                    cookie=cookie,
                    depth=depth + 1,
                    visited=set(visited),
                )

            with ThreadPoolExecutor(max_workers=min(4, len(sub_urls))) as ex:
                for fut in [ex.submit(_fetch_sub, su) for su in sub_urls]:
                    try:
                        found.extend(fut.result())
                    except Exception:
                        continue

    # Deduplicate stream URLs while preserving first-seen source_page_url
    deduped = []
    seen_u = set()
    for su, src_ref in found:
        if su not in seen_u:
            seen_u.add(su)
            deduped.append((su, src_ref))
    return deduped[:16]


def _extract_m3u8_from_html(html_text: str, page_url: str, ua: str, ref: str, cookie: str = "", depth: int = 0):
    """Extracts and probes all .m3u8/.mpd candidates from HTML + nested iframes, returning highest live quality."""
    cands = _collect_html_candidates(html_text, page_url, ua, ref, cookie=cookie, depth=depth)
    if not cands:
        return None, None, {}

    results = []
    with ThreadPoolExecutor(max_workers=min(6, len(cands))) as ex:
        futs = {
            ex.submit(
                _probe_playlist_quality,
                cand_u,
                ua or DEFAULT_BROWSER_UA,
                src_ref or ref or page_url,
                cookie,
                3.6,
                True,
            ): (cand_u, src_ref)
            for cand_u, src_ref in cands
        }
        for fut, (cand_u, src_ref) in futs.items():
            try:
                pr = fut.result()
                if pr.get("ok") is True:
                    score = (
                        pr.get("max_height", 0),
                        round(pr.get("max_fps", 0.0), 1),
                        pr.get("max_bandwidth", 0),
                        1 if pr.get("is_master") else 0,
                    )
                    results.append((score, pr, src_ref))
            except Exception:
                continue

    if not results:
        return None, None, {}

    results.sort(key=lambda item: item[0], reverse=True)
    _, best_pr, best_ref = results[0]
    return best_pr["effective_url"], best_pr.get("used_ref") or best_ref or page_url, best_pr


# ============================================================================
# 3. Local HTTP Server + HLS Playlist/Segment Rewriter
# ============================================================================
class YacineRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True

    def log_message(self, fmt, *args):
        # Quiet logging to avoid stdout clutter
        pass

    def _send_cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")

    def _send_json(self, status: int, payload: dict, head_only: bool = False):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self._send_cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._send_cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self._dispatch_request(head_only=True)

    def do_GET(self):
        self._dispatch_request(head_only=False)

    def _dispatch_request(self, head_only: bool = False):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        force_refresh = qs.get("refresh", ["0"])[0] == "1"
        if force_refresh and path in ("/api/categories", "/api/events"):
            API_CACHE.clear()
            M3U8_CACHE.clear()

        try:
            if path == "/api/status":
                cfg = API_CLIENT.get_config(wait=False)
                self._send_json(200, {
                    "ok": True,
                    "active_host": API_CLIENT.get_active_host(),
                    "config": cfg,
                }, head_only=head_only)
                return

            if path == "/api/categories":
                cat_id = qs.get("id", [None])[0]
                endpoint = f"categories/{cat_id}" if cat_id else "categories"
                data = API_CLIENT.api_get_cached(endpoint, ttl=300.0, force_refresh=force_refresh)
                self._send_json(200, data, head_only=head_only)
                return

            if path == "/api/channels":
                cat_id = qs.get("category_id", [""])[0]
                data = API_CLIENT.api_get_cached(
                    f"categories/{cat_id}/channels", ttl=180.0, force_refresh=force_refresh
                )
                self._send_json(200, data, head_only=head_only)
                return

            if path == "/api/events":
                data = API_CLIENT.api_get_cached("events", ttl=30.0, force_refresh=force_refresh)
                self._send_json(200, data, head_only=head_only)
                return

            if path == "/api/search":
                q = qs.get("query", [""])[0]
                encoded_q = urllib.parse.quote(q)
                data = API_CLIENT.api_get_cached(
                    f"search?query={encoded_q}", ttl=45.0, force_refresh=force_refresh
                )
                self._send_json(200, data, head_only=head_only)
                return

            if path == "/api/stream":
                kind = qs.get("type", ["channel"])[0]
                item_id = qs.get("id", [""])[0]
                endpoint = f"event/{item_id}" if kind == "event" else f"channel/{item_id}"
                data = API_CLIENT.api_get_cached(endpoint, ttl=15.0, force_refresh=force_refresh)
                enriched = API_CLIENT.enrich_streams(data, force_refresh=force_refresh)
                self._send_json(200, enriched, head_only=head_only)
                return

            if path == "/api/extract_m3u8":
                u_param = qs.get("u", [""])[0]
                ua_param = qs.get("ua", [""])[0]
                ref_param = qs.get("ref", [""])[0]
                ck_param = qs.get("ck", [""])[0]
                target_u = b64u_decode(u_param) if u_param and not u_param.startswith("http") else u_param
                ua_s = b64u_decode(ua_param) if ua_param else DEFAULT_BROWSER_UA
                ref_s = b64u_decode(ref_param) if ref_param else ""
                ck_s = b64u_decode(ck_param) if ck_param else ""
                ekey = ("extract", target_u, ua_s, ref_s, ck_s)
                if not force_refresh:
                    ecached = EXTRACT_CACHE.get(ekey)
                    if ecached is not None:
                        self._send_json(200, ecached, head_only=head_only)
                        return
                try:
                    _, _, final_u, body, used_ua, used_ref = _fetch_with_fallback(
                        target_u, ua_s, ref_s, cookie=ck_s, timeout=8.0
                    )
                    text = body.decode("utf-8", errors="replace")
                    if "#EXTM3U" in text[:400]:
                        m3u8_u, m3u8_ref, meta = final_u, used_ref, _probe_playlist_quality(
                            final_u, used_ua, used_ref, cookie=ck_s, timeout=3.5, verify_segment=True
                        )
                        if meta.get("ok") is not True:
                            m3u8_u, m3u8_ref = None, None
                    else:
                        m3u8_u, m3u8_ref, meta = _extract_m3u8_from_html(
                            text, final_u, used_ua, used_ref, cookie=ck_s
                        )
                    if m3u8_u:
                        eff_ua = meta.get("used_ua") or used_ua or DEFAULT_BROWSER_UA
                        eff_ref = m3u8_ref or final_u
                        ck_q = f"&ck={ck_param}" if ck_param else ""
                        proxy_u = (
                            f"/proxy/m3u8?u={b64u_encode(m3u8_u)}"
                            f"&ua={b64u_encode(eff_ua)}"
                            f"&ref={b64u_encode(eff_ref)}{ck_q}"
                        )
                        payload = {
                            "ok": True,
                            "found": True,
                            "m3u8_url": m3u8_u,
                            "referer": eff_ref,
                            "proxy_url": proxy_u,
                            "max_height": meta.get("max_height", 0),
                            "max_fps": meta.get("max_fps", 0.0),
                            "max_bandwidth": meta.get("max_bandwidth", 0),
                            "label": meta.get("label", ""),
                        }
                        EXTRACT_CACHE.set(ekey, payload, ttl=12.0)
                        self._send_json(200, payload, head_only=head_only)
                    else:
                        self._send_json(200, {"ok": True, "found": False}, head_only=head_only)
                except Exception as ex:
                    self._send_json(200, {"ok": False, "found": False, "error": str(ex)}, head_only=head_only)
                return

            if path == "/api/variants":
                u_b64 = qs.get("u", [""])[0]
                ua_b64 = qs.get("ua", [""])[0]
                ref_b64 = qs.get("ref", [""])[0]
                ck_b64 = qs.get("ck", [""])[0]
                target_url = b64u_decode(u_b64)
                ua = b64u_decode(ua_b64) if ua_b64 else DEFAULT_BROWSER_UA
                ref = b64u_decode(ref_b64) if ref_b64 else ""
                ck = b64u_decode(ck_b64) if ck_b64 else ""
                _, _, final_url, body, used_ua, used_ref = _fetch_m3u8_coalesced(
                    target_url, ua, ref, cookie=ck, timeout=10.0
                )
                raw_text = body.decode("utf-8", errors="replace")
                _, variants, is_master = _rewrite_and_sort_m3u8(
                    raw_text, final_url, b64u_encode(used_ua), b64u_encode(used_ref), ck_b64=ck_b64
                )
                ck_q = f"&ck={ck_b64}" if ck_b64 else ""
                self._send_json(200, {
                    "ok": True,
                    "is_master": is_master,
                    "variants": variants,
                    "auto_proxy_url": (
                        f"/proxy/m3u8?u={b64u_encode(final_url)}"
                        f"&ua={b64u_encode(used_ua)}"
                        f"&ref={b64u_encode(used_ref)}{ck_q}"
                    ),
                }, head_only=head_only)
                return

            if path == "/proxy/m3u8":
                self._handle_proxy_m3u8(qs, head_only=head_only)
                return

            if path.startswith("/proxy/seg"):
                self._handle_proxy_seg(qs, head_only=head_only)
                return

            # Serve static UI files
            self._serve_static(path)

        except BrokenPipeError:
            pass
        except UpstreamHTTPError as e:
            try:
                self._send_json(e.status, {"error": True, "message": str(e)}, head_only=head_only)
            except Exception:
                pass
        except urllib.error.HTTPError as e:
            try:
                self._send_json(e.code, {"error": True, "message": str(e)}, head_only=head_only)
            except Exception:
                pass
        except (http.client.HTTPException, ssl.SSLError, TimeoutError, OSError) as e:
            try:
                self._send_json(502, {"error": True, "message": f"Upstream network/TLS error: {e}"}, head_only=head_only)
            except Exception:
                pass
        except Exception as e:
            try:
                self._send_json(500, {"error": True, "message": str(e)}, head_only=head_only)
            except Exception:
                pass

    def _handle_proxy_m3u8(self, qs: dict, head_only: bool = False):
        u_b64 = qs.get("u", [""])[0]
        ua_b64 = qs.get("ua", [""])[0]
        ref_b64 = qs.get("ref", [""])[0]
        ck_b64 = qs.get("ck", [""])[0]
        variant_param = qs.get("variant", [None])[0]
        variant_idx = int(variant_param) if (variant_param is not None and variant_param.isdigit()) else None

        target_url = b64u_decode(u_b64)
        ua = b64u_decode(ua_b64) if ua_b64 else DEFAULT_BROWSER_UA
        ref = b64u_decode(ref_b64) if ref_b64 else ""
        cookie = b64u_decode(ck_b64) if ck_b64 else ""

        _, resp_hdrs, final_url, body, used_ua, used_ref = _fetch_m3u8_coalesced(
            target_url, ua, ref, cookie=cookie, timeout=12.0
        )
        raw_text = body.decode("utf-8", errors="replace")

        # If upstream returned HTML instead of an M3U8 playlist, extract best live embedded stream
        ctype = resp_hdrs.get("content-type", "").lower()
        stripped_head = raw_text.lstrip()[:64].lower()
        if "#EXTM3U" not in raw_text and ("html" in ctype or stripped_head.startswith("<!doctype") or stripped_head.startswith("<html")):
            found_u, found_ref, _ = _extract_m3u8_from_html(
                raw_text, final_url, used_ua, used_ref, cookie=cookie
            )
            if found_u:
                _, resp_hdrs, final_url, body, used_ua, used_ref = _fetch_m3u8_resolved(
                    found_u, used_ua, found_ref or final_url, cookie=cookie, timeout=12.0
                )
                raw_text = body.decode("utf-8", errors="replace")
            else:
                raise UpstreamHTTPError(415, "Upstream returned HTML instead of HLS playlist", final_url)

        if "#EXTM3U" not in raw_text:
            raise UpstreamHTTPError(415, "Upstream response is not a valid M3U8 playlist", final_url)

        used_ua_b64 = b64u_encode(used_ua)
        used_ref_b64 = b64u_encode(used_ref)
        rewritten_text, _, _ = _rewrite_and_sort_m3u8(
            raw_text, final_url, used_ua_b64, used_ref_b64, variant_idx=variant_idx, ck_b64=ck_b64
        )

        out_bytes = rewritten_text.encode("utf-8")
        self.send_response(200)
        self._send_cors()
        self.send_header("Content-Type", "application/vnd.apple.mpegurl")
        self.send_header("Content-Length", str(len(out_bytes)))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.end_headers()
        if not head_only:
            self.wfile.write(out_bytes)

    def _open_seg_with_fallback(self, target_url: str, ua: str, ref: str, method: str, range_hdr: str | None, cookie: str = ""):
        last_err = None
        parsed = urllib.parse.urlparse(target_url)
        cache_key = (parsed.scheme.lower(), parsed.hostname or "", ua, ref)
        for cand_ua, cand_ref, include_origin in _build_header_candidates(ua, ref, target_url=target_url):
            hdrs = _build_upstream_headers(cand_ua, cand_ref, include_origin=include_origin, cookie=cookie)
            # Request uncompressed binary bytes for media segments
            hdrs["Accept-Encoding"] = "identity"
            if range_hdr:
                hdrs["Range"] = range_hdr
            try:
                res = HTTP_POOL.open_raw(target_url, method=method, headers=hdrs, timeout=15.0)
                HEADER_CACHE.set(cache_key, (cand_ua, cand_ref, include_origin), ttl=300.0)
                return res
            except UpstreamHTTPError as e:
                last_err = e
                if e.status == 503:
                    time.sleep(0.15)
                    try:
                        return HTTP_POOL.open_raw(target_url, method=method, headers=hdrs, timeout=15.0)
                    except UpstreamHTTPError as e2:
                        last_err = e2
                        raise
                if e.status in (400, 401, 403):
                    continue
                raise
        if last_err is not None:
            raise last_err
        raise RuntimeError(f"Segment fetch failed for {target_url}")

    @staticmethod
    def _normalize_seg_ctype(raw_ctype: str | None, first_chunk: bytes | None = None) -> str:
        if first_chunk and first_chunk[0] == 0x47:
            return "video/mp2t"
        base = (raw_ctype or "application/octet-stream").split(";")[0].strip().lower()
        disguised = (
            "image/png", "image/gif", "image/jpeg",
            "application/pdf", "application/javascript", "text/javascript",
        )
        if base in disguised:
            return "video/mp2t" if first_chunk is None else "application/octet-stream"
        return raw_ctype or "application/octet-stream"

    def _handle_proxy_seg(self, qs: dict, head_only: bool = False):
        u_b64 = qs.get("u", [""])[0]
        ua_b64 = qs.get("ua", [""])[0]
        ref_b64 = qs.get("ref", [""])[0]
        ck_b64 = qs.get("ck", [""])[0]

        target_url = b64u_decode(u_b64)
        ua = b64u_decode(ua_b64) if ua_b64 else DEFAULT_BROWSER_UA
        ref = b64u_decode(ref_b64) if ref_b64 else ""
        cookie = b64u_decode(ck_b64) if ck_b64 else ""
        range_hdr = self.headers.get("Range")

        if head_only:
            try:
                conn, resp, _, pool_key = self._open_seg_with_fallback(
                    target_url, ua, ref, "HEAD", range_hdr, cookie=cookie
                )
                fully_read = False
                try:
                    resp.read()
                    fully_read = True
                    clen = resp.getheader("Content-Length")
                    ctype = self._normalize_seg_ctype(resp.getheader("Content-Type"))
                    self.send_response(resp.status)
                    self._send_cors()
                    self.send_header("Content-Type", ctype)
                    if clen:
                        self.send_header("Content-Length", clen)
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Cache-Control", "public, max-age=300")
                    self.end_headers()
                finally:
                    HTTP_POOL.release_response(pool_key, conn, resp, fully_consumed=fully_read)
                return
            except UpstreamHTTPError as e:
                if e.status not in (405, 501):
                    raise
                # Fallback if HEAD unsupported: read zero/1 byte via GET Range
                range_hdr = range_hdr or "bytes=0-0"

        conn, resp, _, pool_key = self._open_seg_with_fallback(
            target_url, ua, ref, "GET", range_hdr, cookie=cookie
        )
        fully_read = False
        try:
            first_chunk = resp.read1(131072)
            if not first_chunk:
                fully_read = True

            # Disguised .pdf/.php/.js segments start with 0x47 (MPEG-TS sync byte) -> serve as video/mp2t
            content_type = self._normalize_seg_ctype(resp.getheader("Content-Type"), first_chunk)

            self.send_response(resp.status)
            self._send_cors()
            self.send_header("Content-Type", content_type)
            clen = resp.getheader("Content-Length")
            crange = resp.getheader("Content-Range")
            if crange:
                self.send_header("Content-Range", crange)
            if clen is not None:
                self.send_header("Content-Length", clen)
                self.send_header("Accept-Ranges", "bytes")
            else:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.send_header("Cache-Control", "public, max-age=300")
            self.end_headers()

            if not head_only:
                if first_chunk:
                    self.wfile.write(first_chunk)
                while True:
                    chunk = resp.read1(131072)
                    if not chunk:
                        fully_read = True
                        break
                    self.wfile.write(chunk)
        finally:
            HTTP_POOL.release_response(pool_key, conn, resp, fully_consumed=fully_read)

    def _serve_static(self, url_path: str):
        if url_path in ("/", ""):
            url_path = "/index.html"
        safe_rel = os.path.normpath(url_path.lstrip("/"))
        full_path = os.path.abspath(os.path.join(UI_DIR, safe_rel))
        if not full_path.startswith(UI_DIR) or not os.path.isfile(full_path):
            self._send_json(404, {"error": True, "message": "Not found"})
            return

        ext = os.path.splitext(full_path)[1].lower()
        mime_map = {
            ".html": "text/html; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".png": "image/png",
            ".svg": "image/svg+xml",
            ".json": "application/json",
            ".ico": "image/x-icon",
        }
        ctype = mime_map.get(ext, "application/octet-stream")
        with open(full_path, "rb") as f:
            content = f.read()

        self.send_response(200)
        self._send_cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(content)


class ReuseThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64


def main():
    port = int(os.environ.get("YACINE_PORT", "19485"))
    server = ReuseThreadingHTTPServer(("127.0.0.1", port), YacineRequestHandler)
    sys.stdout.write(f"YACINE_BACKEND_READY:http://127.0.0.1:{port}\n")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

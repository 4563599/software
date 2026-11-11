"""T Notes ciphertext sync service; Python standard library only."""
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import ssl
import threading
import time
import uuid
from collections import defaultdict, deque
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

MAX_BODY = 262144
MAX_VAULT_BYTES = 16 * 1024 * 1024
NAME = re.compile(r"^[a-zA-Z0-9_-]{3,40}$")


class ApiError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def envelope(value):
    if not isinstance(value, dict) or set(value) != {"iv", "data"}:
        raise ApiError(400, "Invalid encrypted envelope")
    try:
        if len(base64.b64decode(value["iv"], validate=True)) != 12:
            raise ValueError()
        if not 16 <= len(base64.b64decode(value["data"], validate=True)) <= 160000:
            raise ValueError()
    except (ValueError, TypeError):
        raise ApiError(400, "Invalid encrypted envelope")
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def identifier(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise ApiError(400, "Invalid record id")


class Store:
    def __init__(self, db_path, enrollment_digest=""):
        self.path = str(db_path)
        self.enrollment_digest = enrollment_digest
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS users (
                    id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL,
                    salt TEXT NOT NULL, check_blob TEXT NOT NULL, auth_hash TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS records (
                    owner TEXT NOT NULL REFERENCES users(id), id TEXT NOT NULL,
                    rev INTEGER NOT NULL, envelope TEXT NOT NULL, updated INTEGER NOT NULL,
                    PRIMARY KEY(owner,id)
                );
            """)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def profile(self, name):
        with self.connect() as db:
            row = db.execute("SELECT * FROM users WHERE name=?", (name,)).fetchone()
        if row is None:
            raise ApiError(404, "Vault not found")
        return {"id": row["id"], "name": row["name"], "salt": row["salt"],
                "check": json.loads(row["check_blob"]), "kdf": "pbkdf2-sha256-hkdf-v1"}

    def register(self, data, invitation):
        if not self.enrollment_digest or not hmac.compare_digest(
                hashlib.sha256(invitation.encode()).hexdigest(), self.enrollment_digest):
            raise ApiError(403, "Enrollment not authorized")
        name, user_id = data.get("name", ""), identifier(data.get("id"))
        if not isinstance(name, str) or not NAME.fullmatch(name):
            raise ApiError(400, "Use 3-40 letters, numbers, hyphens or underscores")
        try:
            if len(base64.b64decode(data["salt"], validate=True)) != 16:
                raise ValueError()
        except (KeyError, ValueError, TypeError):
            raise ApiError(400, "Invalid KDF salt")
        auth = data.get("auth", "")
        if not isinstance(auth, str) or not re.fullmatch(r"[0-9a-f]{64}", auth):
            raise ApiError(400, "Invalid authentication proof")
        check = envelope(data.get("check"))
        try:
            with self.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                # This private deployment permits one owner; enrollment is single-use.
                if db.execute("SELECT COUNT(*) FROM users").fetchone()[0]:
                    raise ApiError(409, "Owner already enrolled; use the existing vault")
                db.execute("INSERT INTO users VALUES(?,?,?,?,?)", (
                    user_id, name, data["salt"], check, hashlib.sha256(auth.encode()).hexdigest()))
        except sqlite3.IntegrityError:
            raise ApiError(409, "Vault already exists")
        return self.profile(name)

    def login(self, name, auth):
        with self.connect() as db:
            row = db.execute("SELECT id,auth_hash FROM users WHERE name=?", (name,)).fetchone()
        digest = hashlib.sha256(str(auth).encode()).hexdigest()
        if row is None or not hmac.compare_digest(row["auth_hash"], digest):
            raise ApiError(401, "Invalid credentials")
        return row["id"]

    def list_records(self, owner):
        with self.connect() as db:
            rows = db.execute("SELECT id,rev,envelope,updated FROM records WHERE owner=? ORDER BY updated,id", (owner,)).fetchall()
        return [{"id": row["id"], "rev": row["rev"], "envelope": json.loads(row["envelope"]),
                 "updated": row["updated"]} for row in rows]

    def put(self, owner, data):
        record_id, encoded = identifier(data.get("id")), envelope(data.get("envelope"))
        base = data.get("base")
        if type(base) is not int or base < 0:
            raise ApiError(400, "Invalid revision")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM records WHERE owner=? AND id=?", (owner, record_id)).fetchone()
            # Retrying a write after a lost response is idempotent.
            if row is not None and row["envelope"] == encoded:
                return {"id": record_id, "rev": row["rev"]}
            if (row is None and base != 0) or (row is not None and row["rev"] != base):
                raise ApiError(409, "Revision conflict")
            used = db.execute("SELECT COALESCE(SUM(LENGTH(envelope)),0),COUNT(*) FROM records WHERE owner=?", (owner,)).fetchone()
            if used[0] - (len(row["envelope"]) if row else 0) + len(encoded) > MAX_VAULT_BYTES or (row is None and used[1] >= 2000):
                raise ApiError(413, "Vault quota exceeded")
            rev = (row["rev"] if row else 0) + 1
            db.execute("INSERT INTO records VALUES(?,?,?,?,?) ON CONFLICT(owner,id) DO UPDATE SET rev=excluded.rev,envelope=excluded.envelope,updated=excluded.updated",
                       (owner, record_id, rev, encoded, int(time.time() * 1000)))
        return {"id": record_id, "rev": rev}


class SyncServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, store):
        super().__init__(address, Handler)
        self.store = store
        self.sessions = {}
        self.rates = defaultdict(deque)
        self.guard = threading.Lock()
        self.slots = threading.BoundedSemaphore(24)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    server_version = "TNotes/1"

    def setup(self):
        self.request.settimeout(15)
        if isinstance(self.request, ssl.SSLSocket):
            self.request.do_handshake()
        super().setup()

    def log_message(self, *_):
        pass

    def response(self, code, data):
        raw = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(raw)

    def limit(self, group):
        now = time.monotonic()
        with self.server.guard:
            # Bound rate-limit memory independently of attacker-controlled IP count.
            if len(self.server.rates) > 4096:
                self.server.rates = defaultdict(deque, {k:v for k,v in self.server.rates.items() if v and v[-1] > now-60})
                if len(self.server.rates) > 4096:
                    raise ApiError(503, "Busy")
            queue = self.server.rates[(self.client_address[0], group)]
            while queue and queue[0] < now - 60:
                queue.popleft()
            if len(queue) >= (15 if group == "auth" else 180):
                raise ApiError(429, "Please wait before retrying")
            queue.append(now)

    def owner(self):
        key = self.headers.get("Authorization", "").removeprefix("Bearer ")
        with self.server.guard:
            session = self.server.sessions.get(key)
        if session is None or session[1] < time.time():
            raise ApiError(401, "Session expired")
        return session[0]

    def handle_api(self):
        route = urlsplit(self.path)
        self.limit("auth" if route.path in ("/v1/profile", "/v1/login", "/v1/register") else "api")
        if self.command == "GET":
            if route.path == "/health":
                return {"ok": True, "schema": 1}
            if route.path == "/v1/profile":
                return self.server.store.profile(parse_qs(route.query).get("name", [""])[0])
            if route.path == "/v1/records":
                return {"items": self.server.store.list_records(self.owner())}
            raise ApiError(404, "Not found")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 1 <= length <= MAX_BODY:
                raise ApiError(413, "Invalid body size")
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ValueError()
        except (ValueError, UnicodeError):
            raise ApiError(400, "Invalid JSON")
        if self.command == "POST" and route.path == "/v1/register":
            return self.server.store.register(data, self.headers.get("X-Enrollment", ""))
        if self.command == "POST" and route.path == "/v1/login":
            owner = self.server.store.login(data.get("name", ""), data.get("auth", ""))
            session = secrets.token_urlsafe(32)
            with self.server.guard:
                self.server.sessions = {k:v for k,v in self.server.sessions.items() if v[1] > time.time()}
                if len(self.server.sessions) >= 128:
                    self.server.sessions.pop(next(iter(self.server.sessions)))
                self.server.sessions[session] = (owner, time.time() + 3600)
            return {"token": session}
        if self.command == "PUT" and route.path == "/v1/records":
            return self.server.store.put(self.owner(), data)
        raise ApiError(404, "Not found")

    def dispatch(self):
        try:
            self.response(200, self.handle_api())
        except ApiError as exc:
            self.response(exc.status, {"error": exc.message})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception:
            self.response(500, {"error": "Internal server error"})

    do_GET = do_POST = do_PUT = dispatch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    store = Store(config["database"], config.get("enrollment_digest", ""))
    server = SyncServer((config.get("host", "127.0.0.1"), config.get("port", 18443)), store)
    # TLS is mandatory for any non-loopback listener.
    if config.get("cert") and config.get("key"):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(config["cert"], config["key"])
        server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    elif config.get("host", "127.0.0.1") not in ("127.0.0.1", "::1"):
        raise RuntimeError("TLS required")
    server.serve_forever()


if __name__ == "__main__":
    main()

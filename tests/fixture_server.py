#!/usr/bin/env python3
"""A fake Miniflux for tests/api.sh, on loopback only.

Usage: fixture_server.py PORTFILE LOGFILE

Binds an ephemeral port on 127.0.0.1, writes the port to PORTFILE and
appends one JSON line per request to LOGFILE. Nothing leaves the machine.

The first path segment picks a behaviour, so a test chooses one by where it
points MINIFLUX_SERVER:

  /           a current instance: user "ann", password "pw", API key "key"
  /old        an instance too old to mint keys (POST /v1/api-keys is 404)
  /big        every answer is one byte over the 16 MiB cap, no Content-Length
  /bigcl      the same with a Content-Length header, so curl can refuse early
  /revokefail DELETE /v1/api-keys/... answers 500
  /notoken    POST /v1/api-keys answers 201 without a token
  /nosave     POST /v1/entries/{id}/save answers 403 (no save integration)

The API key or basic-auth pair a request carried is echoed back by /v1/me as
"seen", so a test can check the script quoted it for curl correctly.
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CAP = 16 * 1024 * 1024
USER, PASSWORD, KEY = "ann", "pw", "key"
next_key = [7]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, body=b"", length=True):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        if length:
            self.send_header("Content-Length", str(len(body)))
        else:
            self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # curl hangs up on an oversized answer, which is what /big tests.
            self.close_connection = True
            return
        if not length:
            self.close_connection = True

    def seen(self):
        token = self.headers.get("X-Auth-Token")
        if token is not None:
            return {"token": token}
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Basic "):
            user, _, password = base64.b64decode(auth[6:]).decode().partition(":")
            return {"user": user, "password": password}
        return {}

    def handle_any(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        mode, _, rest = self.path.lstrip("/").partition("/")
        if mode not in ("old", "big", "bigcl", "revokefail", "notoken", "nosave"):
            mode, rest = "", self.path.lstrip("/")
        route = "/" + rest.split("?")[0]
        query = rest.partition("?")[2]
        seen = self.seen()
        with open(sys.argv[2], "a") as log:
            log.write(json.dumps({"method": self.command, "mode": mode, "route": route,
                                  "query": query, "body": body, "seen": seen}) + "\n")

        if self.command == "CONNECT":
            # Refused, and the connection closed with it: curl resets a
            # tunnel it could not open, which would otherwise show up as a
            # traceback from the handler thread.
            self.close_connection = True
            return self.reply(405)
        if mode in ("big", "bigcl"):
            return self.reply(200, b"x" * (CAP + 1), length=(mode == "bigcl"))
        good = seen == {"token": KEY} or seen == {"user": USER, "password": PASSWORD}
        if route == "/v1/me":
            if not good:
                return self.reply(401, {"error_message": "Access Unauthorized", "seen": seen})
            return self.reply(200, {"id": 1, "username": USER, "seen": seen})
        if not good:
            return self.reply(401, {"error_message": "Access Unauthorized"})
        if route == "/v1/api-keys" and self.command == "POST":
            if mode == "old":
                return self.reply(404, b"404 page not found")
            if mode == "notoken":
                return self.reply(201, {"id": 99, "description": "x"})
            key_id = next_key[0]
            next_key[0] += 1
            return self.reply(201, {"id": key_id, "token": KEY, "description": "x"})
        if route.startswith("/v1/api-keys/") and self.command == "DELETE":
            return self.reply(500 if mode == "revokefail" else 204)
        if route == "/v1/entries" and self.command == "GET":
            return self.reply(200, {"total": 1, "entries": [{"id": 1, "title": "One", "status": "unread"}]})
        if route == "/v1/entries" and self.command == "PUT":
            return self.reply(204)
        if route == "/v1/discover" and self.command == "POST":
            url = json.loads(body)["url"]
            if "nofeed" in url:
                return self.reply(500, {"error_message": "Unable to discover subscriptions"})
            if "empty" in url:
                return self.reply(200, [])
            # Go's encoder writes & as \u0026, which the script has to undo.
            kind = "atom" if "atom" in url else "rss"
            return self.reply(200, ('[{"title":"T","url":"%s","type":"%s"}]' % (url.replace("&", "\\u0026"), kind)).encode())
        if route == "/v1/categories" and self.command == "GET":
            return self.reply(200, [{"id": 3, "title": "All"}, {"id": 4, "title": "Other"}])
        if route == "/v1/feeds" and self.command == "POST":
            if "refused" in json.loads(body)["feed_url"]:
                return self.reply(400, {"error_message": "Unable to fetch this feed"})
            return self.reply(201, {"feed_id": 5})
        if route.startswith("/v1/icons/") and self.command == "GET":
            return self.reply(200, {"id": int(route.rsplit("/", 1)[1]), "mime_type": "image/png",
                                    "data": "image/png;base64,iVBORw0KGgo="})
        if route.startswith("/v1/entries/") and route.endswith("/save"):
            return self.reply(403 if mode == "nosave" else 202)
        return self.reply(404, b"404 page not found")

    # CONNECT is what curl sends when the fixture is named as an https proxy;
    # it is logged like any request (and refused), so a test can see that the
    # proxy was consulted at all.
    do_GET = do_POST = do_PUT = do_DELETE = do_CONNECT = handle_any


class Server(ThreadingHTTPServer):
    daemon_threads = True


server = Server(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()

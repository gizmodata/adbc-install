#!/usr/bin/env python3
"""A local stand-in for github.com's release pages, for the installer tests (standard library only).

It answers the paths install.sh and install.ps1 use, as github.com does:

  /<owner>/<repo>/releases/latest                 302 to /<owner>/<repo>/releases/tag/<latest tag>
  /<owner>/<repo>/releases/tag/<tag>              200 (an HTML stand-in) or 404
  /<owner>/<repo>/releases/download/<tag>/<name>  302 to /storage/... (as GitHub's go to its storage host), or 404
  /storage/<owner>/<repo>/<tag>/<name>            the file

Fixtures: <root>/<owner>/<repo>/<tag>/<files>. The latest release is the highest version, unless
<root>/<owner>/<repo>/latest holds a tag. Every request is logged to --log as "<method> <path>".

  python3 fake_github.py --root DIR --port-file FILE --log FILE [--port 0]
"""

from __future__ import annotations

import argparse
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def version_key(tag: str) -> tuple[int, ...]:
    return tuple(int(n) for n in re.findall(pattern=r"\d+", string=tag)[:3])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    root = os.path.abspath(args.root)

    def tags(repo_dir: str) -> list[str]:
        if not os.path.isdir(repo_dir):
            return []
        found = [t for t in os.listdir(repo_dir) if os.path.isdir(os.path.join(repo_dir, t))]
        return sorted(found, key=version_key)

    def latest(repo_dir: str) -> str | None:
        pinned = os.path.join(repo_dir, "latest")
        if os.path.isfile(pinned):
            with open(pinned, encoding="utf-8") as f:
                return f.read().strip()
        all_tags = tags(repo_dir=repo_dir)
        return all_tags[-1] if all_tags else None

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *log_args: object) -> None:  # noqa: A002
            pass

        def send(self, code: int, body: bytes = b"", ctype: str = "text/html", location: str | None = None) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            if location:
                self.send_header("Location", location)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self) -> None:  # noqa: N802
            self.do_GET()

        def do_GET(self) -> None:  # noqa: N802
            path = self.path.split("?")[0]
            with open(args.log, "a", encoding="utf-8") as log:
                log.write(f"{self.command} {path}\n")
            port = self.server.server_address[1]
            web = f"http://127.0.0.1:{port}"

            m = re.fullmatch(pattern=r"/storage/([^/]+)/([^/]+)/([^/]+)/([^/]+)", string=path)
            if m:
                f = os.path.join(root, *m.groups())
                if os.path.isfile(f):
                    with open(f, "rb") as fh:
                        return self.send(code=200, body=fh.read(), ctype="application/octet-stream")
                return self.send(code=404, body=b"Not Found", ctype="text/plain")

            m = re.fullmatch(pattern=r"/([^/]+)/([^/]+)/releases/(latest|tag/([^/]+)|download/([^/]+)/([^/]+))", string=path)
            if not m:
                return self.send(code=404, body=b"Not Found", ctype="text/plain")
            owner, repo = m.group(1), m.group(2)
            repo_dir = os.path.join(root, owner, repo)
            if m.group(3) == "latest":
                tag = latest(repo_dir=repo_dir)
                if not tag:
                    # github.com sends a repository without releases to its releases page.
                    return self.send(code=302, location=f"{web}/{owner}/{repo}/releases")
                return self.send(code=302, location=f"{web}/{owner}/{repo}/releases/tag/{tag}")
            if m.group(4):
                if m.group(4) in tags(repo_dir=repo_dir):
                    return self.send(code=200, body=b"<html>release</html>")
                return self.send(code=404, body=b"Not Found")
            tag, name = m.group(5), m.group(6)
            if os.path.isfile(os.path.join(repo_dir, tag, name)):
                return self.send(code=302, location=f"{web}/storage/{owner}/{repo}/{tag}/{name}?sig=x")
            return self.send(code=404, body=b"Not Found", ctype="text/plain")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    with open(args.port_file, "w", encoding="utf-8") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()

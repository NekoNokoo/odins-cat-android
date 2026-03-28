#!/usr/bin/env python3

import hashlib
import http.server
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import urllib.parse


ROOTS = {
    "maven2": "https://repo.maven.apache.org/maven2/",
    "google": "https://dl.google.com/dl/android/maven2/",
    "plugins": "https://plugins.gradle.org/m2/",
}


def safe_cache_name(url: str) -> pathlib.Path:
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()
    parsed = urllib.parse.urlparse(url)
    suffix = pathlib.Path(parsed.path).name or "index"
    return pathlib.Path(digest[:2]) / digest[2:4] / f"{digest}-{suffix}"


class MirrorHandler(http.server.BaseHTTPRequestHandler):
    server_version = "OdinGradleMirror/1.0"

    def do_GET(self):
        self._handle(False)

    def do_HEAD(self):
        self._handle(True)

    def log_message(self, fmt, *args):
        sys.stderr.write(
            "[mirror] %s - - [%s] %s\n"
            % (self.address_string(), self.log_date_time_string(), fmt % args)
        )

    def _handle(self, head_only: bool):
        parsed = urllib.parse.urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]
        if not parts:
            self.send_response(200)
            self.end_headers()
            return

        root = ROOTS.get(parts[0])
        if root is None:
            self.send_error(404, "Unknown repo root")
            return

        upstream_path = "/".join(parts[1:])
        upstream_url = urllib.parse.urljoin(root, upstream_path)
        if parsed.query:
            upstream_url += f"?{parsed.query}"

        cache_root = pathlib.Path(self.server.cache_dir) / parts[0]
        cache_path = cache_root / safe_cache_name(upstream_url)
        cache_path.parent.mkdir(parents=True, exist_ok=True)

        if cache_path.exists():
            self._serve_cached(cache_path, head_only)
            return

        if head_only:
            self._head_upstream(upstream_url)
            return

        self._get_upstream(upstream_url, cache_path)

    def _serve_cached(self, cache_path: pathlib.Path, head_only: bool):
        self.send_response(200)
        self.send_header("Content-Length", str(cache_path.stat().st_size))
        self.send_header("Content-Type", self._content_type(cache_path.name))
        self.end_headers()
        if not head_only:
            with cache_path.open("rb") as f:
                shutil.copyfileobj(f, self.wfile)

    def _head_upstream(self, upstream_url: str):
        proc = subprocess.run(
            ["curl", "-I", "-L", "-sS", "-o", "/dev/null", "-w", "%{http_code}", upstream_url],
            capture_output=True,
            text=True,
        )
        code = 502 if proc.returncode != 0 else int(proc.stdout.strip() or "502")
        if code == 200:
            self.send_response(200)
            self.end_headers()
        elif code == 404:
            self.send_error(404, "Not found upstream")
        else:
            self.send_error(502, f"Upstream HEAD failed: {code}")

    def _get_upstream(self, upstream_url: str, cache_path: pathlib.Path):
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp_path = tmp.name
        try:
            proc = subprocess.run(
                ["curl", "-L", "-sS", "-f", "-o", tmp_path, upstream_url],
                capture_output=True,
                text=True,
            )
            if proc.returncode != 0:
                stderr = proc.stderr or ""
                if "404" in stderr or "The requested URL returned error: 404" in stderr:
                    self.send_error(404, "Not found upstream")
                else:
                    self.send_error(502, "Upstream GET failed")
                return

            os.replace(tmp_path, cache_path)
            self._serve_cached(cache_path, head_only=False)
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

    @staticmethod
    def _content_type(name: str) -> str:
        if name.endswith(".pom") or name.endswith(".xml"):
            return "application/xml"
        if name.endswith(".module") or name.endswith(".json"):
            return "application/json"
        if name.endswith(".jar"):
            return "application/java-archive"
        if name.endswith(".aar"):
            return "application/zip"
        return "application/octet-stream"


def main():
    port = int(os.environ.get("ODIN_GRADLE_MIRROR_PORT", "4873"))
    cache_dir = os.environ.get("ODIN_GRADLE_MIRROR_CACHE", "/tmp/odin-gradle-mirror-cache")
    pathlib.Path(cache_dir).mkdir(parents=True, exist_ok=True)

    class ThreadingServer(http.server.ThreadingHTTPServer):
        daemon_threads = True

    server = ThreadingServer(("127.0.0.1", port), MirrorHandler)
    server.cache_dir = cache_dir
    print(f"[mirror] listening on http://127.0.0.1:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

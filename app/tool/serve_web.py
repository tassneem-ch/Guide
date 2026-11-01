"""Minimal static server with SPA fallback, for local web testing only.

Usage:
    python tool/serve_web.py [port]     # default port 8081

Serves the release build in `build/web`. Two reasons this exists instead of
a plain `python -m http.server`:

1. Flutter web uses the *hash* URL strategy by default, so a deep link is
   `http://localhost:8081/#/settings`. The `#...` part never reaches the
   server, so even a plain static server handles refresh/deep links. This
   script is used anyway so the layout also works if the project ever
   switches to the path strategy (`usePathUrlStrategy()`), where a request
   for `/settings` must return index.html rather than 404. Real hosting does
   the same via a rewrite rule (see docs/WEB_DEPLOY.md).
2. It binds to 127.0.0.1 on a fixed port, so the backend's CORS_ORIGINS can
   list that origin precisely.

This is a development convenience, not production hosting.
"""
from __future__ import annotations

import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BUILD_DIR = Path(__file__).resolve().parent.parent / "build" / "web"


class SpaHandler(SimpleHTTPRequestHandler):
    """Serve real files; fall back to index.html for app routes."""

    def send_head(self):  # noqa: D102
        path = self.translate_path(self.path)
        # A request for an existing file (asset, js, css, image) is served as
        # usual; anything else is an app route and must return the shell.
        if not Path(path).is_file():
            self.path = "/index.html"
        return super().send_head()

    def log_message(self, fmt: str, *args) -> None:  # quieter console
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8081
    if not BUILD_DIR.joinpath("index.html").is_file():
        sys.exit(f"No build found at {BUILD_DIR}. Run: flutter build web --release")
    handler = partial(SpaHandler, directory=str(BUILD_DIR))
    with ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        print(f"Serving {BUILD_DIR} on http://localhost:{port} (SPA fallback)")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()

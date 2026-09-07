"""Asserts the safety invariants of the VPS tunnel config.

Run: python3 tests/test_tunnel_config.py

The ACL in configs/chisel/users.json.template is the security property this
whole arrangement rests on. chisel matches its patterns as unanchored
substrings against EVERY remote a client asks for — the string differs by
kind (`R:h:p` reverse, `h:p` forward, the literal `socks`) — so an anchored
pattern is what stops a stolen credential opening a different listener or
pivoting into matrix-net. Both designs say so at length:
  music: docs/superpowers/specs/2026-08-29-navidrome-tunnel-design.md   D4
  music: docs/superpowers/specs/2026-09-07-homeserver-ssh-tunnel-design.md D3, D4
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
fails = []


def check(label, got, want):
    if got != want:
        fails.append(f"{label}\n     got  {got!r}\n     want {want!r}")


# --- the chisel ACL -------------------------------------------------------
acl_text = (ROOT / "configs" / "chisel" / "users.json.template").read_text(encoding="utf-8")

# Render with stub values so the result can be parsed as the strict JSON
# chisel will load. A template that only looks right but does not parse
# fails the server at its next restart, with the tunnel down.
stub = {
    "CHISEL_AUTH_USER": "navidrome-tunnel", "CHISEL_AUTH_PASS": "p1",
    "SSH_TUNNEL_USER": "ssh-tunnel", "SSH_TUNNEL_PASS": "p2",
    "SSH_CLIENT_USER": "ssh-client", "SSH_CLIENT_PASS": "p3",
}
rendered = acl_text
for k, v in stub.items():
    rendered = rendered.replace("${" + k + "}", v)
check("authfile template interpolates only known variables",
      re.findall(r"\$\{[A-Z_]+\}", rendered), [])
try:
    acl = json.loads(rendered)
except json.JSONDecodeError as e:
    acl = {}
    fails.append(f"authfile template is not valid JSON once rendered\n     {e}")

check("three users", sorted(u.split(":")[0] for u in acl),
      ["navidrome-tunnel", "ssh-client", "ssh-tunnel"])

by_user = {u.split(":")[0]: pats for u, pats in acl.items()}
check("navidrome-tunnel keeps its one anchored listener",
      by_user.get("navidrome-tunnel"), [r"^R:0\.0\.0\.0:4533$"])
check("ssh-tunnel opens the loopback listener and nothing else",
      by_user.get("ssh-tunnel"), [r"^R:127\.0\.0\.1:2222$"])
check("ssh-client may dial that listener and nothing else",
      by_user.get("ssh-client"), [r"^127\.0\.0\.1:2222$"])

# Every pattern anchored at both ends, every user has exactly one.
for user, pats in by_user.items():
    check(f"{user} has exactly one pattern", len(pats or []), 1)
    for p in pats or []:
        check(f"{user}'s pattern is anchored at the start", p.startswith("^"), True)
        check(f"{user}'s pattern is anchored at the end", p.endswith("$"), True)
        check(f"{user}'s pattern is not a wildcard", p in ("", "*", "^.*$"), False)

# The travelling credential must not be able to CLAIM the listener, only
# dial it. `R:` is the whole difference between the two SSH roles.
check("ssh-client cannot open any listener",
      any("R:" in p for p in by_user.get("ssh-client") or []), False)
check("ssh-tunnel can only open a listener",
      all(p.startswith("^R:") for p in by_user.get("ssh-tunnel") or []), True)

# --- the credentials are generated, preserved, and never committed --------
gen = (ROOT / "scripts" / "generate-env.sh").read_text(encoding="utf-8")
for key in ("SSH_TUNNEL_PASS", "SSH_CLIENT_PASS"):
    check(f"{key} is generated or preserved", f"{key}=$(get_or_generate {key})" in gen, True)
    check(f"{key} is written to .env", f"{key}=${{{key}}}" in gen, True)
for key, value in (("SSH_TUNNEL_USER", "ssh-tunnel"), ("SSH_CLIENT_USER", "ssh-client")):
    check(f"{key} is the fixed literal {value}", f"{key}={value}" in gen, True)

# --- the chisel server is still unpublished and still not a socks proxy ---
compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
chisel_block = re.split(r"\n  (?=\S)", compose.split("\n  chisel:\n", 1)[1])[0]
chisel_code = "\n".join(
    l for l in chisel_block.splitlines() if not l.lstrip().startswith("#"))
check("chisel publishes no ports", "ports:" in chisel_code, False)
check("chisel is not a socks proxy", "--socks5" in chisel_code, False)
check("chisel pinned by digest",
      "jpillora/chisel:1.12.0@sha256:e5538d0a8432f53788bf63089d918a4b9979e6df408a2f1aa36575917eacd314"
      in chisel_code, True)
check("chisel never uses :latest", ":latest" in chisel_code, False)

# --- the rendered authfile is gitignored ----------------------------------
try:
    ignored = subprocess.run(
        ["git", "check-ignore", "--no-index", "-q", "configs/chisel/users.json"],
        cwd=ROOT, capture_output=True).returncode == 0
    check("rendered configs/chisel/users.json is gitignored", ignored, True)
except (FileNotFoundError, OSError):
    check("git available (required for gitignore verification)", False, True)

# --- the dial-in route on the music site block ----------------------------
# Ordering is the whole point of wrapping these in `route`: Caddy sorts
# `handle` blocks by matcher specificity, but a `route` runs its directives
# in written order. The WebSocket proxy must be tried before the 404, and
# both before Navidrome's catch-all — otherwise the dial-in path either
# 404s or is answered by Navidrome's SPA handler with the player's HTML.
caddy = (ROOT / "configs" / "caddy" / "Caddyfile.template").read_text(encoding="utf-8")
music_block = caddy.split("${SUBDOMAIN_MUSIC}.${DOMAIN} {", 1)[1].split("\n}\n", 1)[0]

check("the music block routes in written order", "route {" in music_block, True)
check("the dial-in path is matched on a websocket upgrade",
      "path /__tunnel /__tunnel/*" in music_block, True)
check("the dial-in matcher requires the upgrade header",
      "header Upgrade websocket" in music_block, True)
check("the dial-in matcher requires the connection header",
      "header Connection *Upgrade*" in music_block, True)
check("websocket upgrades reach chisel's control port",
      "reverse_proxy @ssh_tunnel chisel:8080" in music_block, True)
check("anything else under the prefix is a flat 404",
      "respond /__tunnel /__tunnel/* 404" in music_block, True)
check("Navidrome is still the catch-all", "reverse_proxy chisel:4533" in music_block, True)
check("Remote-User is still stripped before Navidrome",
      "header_up -Remote-User" in music_block, True)
check("the offline page is still there", "handle_errors" in music_block, True)

# Caddy's `*` glob requires the literal `/` in front of it, so
# `/__tunnel/*` alone does not match the bare prefix with no trailing
# slash — that request would fall through the route to Navidrome's
# catch-all and get its SPA HTML instead of a 404.
check("the bare prefix is covered too, not just /__tunnel/*",
      "path /__tunnel /__tunnel/*" in music_block, True)
check("the 404 covers the bare prefix too",
      "respond /__tunnel /__tunnel/* 404" in music_block, True)

# .index() would raise before any of the above got reported, so only
# compare positions once all three are actually present.
wanted = ["reverse_proxy @ssh_tunnel chisel:8080",
          "respond /__tunnel /__tunnel/* 404",
          "reverse_proxy chisel:4533"]
if all(w in music_block for w in wanted):
    order = [music_block.index(w) for w in wanted]
    check("websocket, then 404, then Navidrome", order, sorted(order))
else:
    fails.append("cannot check handler order — one of the three directives is missing")

# The tunnel. hostname is untouched and still hides chisel from plain GETs.
tunnel_block = caddy.split("${SUBDOMAIN_TUNNEL}.${DOMAIN} {", 1)[1].split("\n}\n", 1)[0]
check("tunnel. still 404s non-websocket requests", "respond 404" in tunnel_block, True)

if fails:
    print(f"FAIL — {len(fails)} checks\n")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("all tunnel config checks pass")

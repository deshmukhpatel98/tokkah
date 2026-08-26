#!/usr/bin/env python3
"""Verify a Kin release without trusting the server that served it.

Kin is not notarized by Apple -- there is no Apple Developer ID behind this
project and there never will be. What stands in for it is an Ed25519 signature
over the release manifest, made with a key that lives on the maintainer's
machine and never in this repository. The public half is below, in the open,
where you can compare it against any other copy you can find.

This script is deliberately dependency-free: stock python3 on a clean macOS,
no pip, no Homebrew. That matters, because the machines most likely to run it
are the ones that have installed nothing yet. LibreSSL 3.3.6 -- what macOS
ships as `openssl` -- cannot do Ed25519 at all, so "just use openssl" is not an
answer here. The RFC 8032 verify below is about fifty lines and is exercised
against known-bad inputs by tools/verify-release-selftest.sh.

    python3 tools/verify-release.py                    # check the live release
    python3 tools/verify-release.py --file tk.tar.gz   # check a file you have
    python3 tools/verify-release.py --base https://your.host/macos --key <hex>

Exit code 0 means every check passed. Any other exit code means do not install
what you downloaded.
"""

import argparse, base64, hashlib, json, shutil, subprocess, sys, urllib.request

# The Kin update-signing public key. Publishing it is the whole point: a
# signature you verify against a key the same server handed you proves nothing.
KIN_PUBKEY_HEX = "d07822edb36c8692c83f3478c26683102cd3cf6fb1d0c263496404c15fd95b2a"
DEFAULT_BASE = "https://room.tokkah.com/macos"

# ---- Ed25519 verify, RFC 8032, no dependencies -----------------------------
P = 2**255 - 19
D = -121665 * pow(121666, P - 2, P) % P
L = 2**252 + 27742317777372353535851937790883648493
_I = pow(2, (P - 1) // 4, P)


def _xrecover(y):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P:
        x = x * _I % P
    return P - x if x % 2 else x


_By = 4 * pow(5, P - 2, P) % P
_B = [_xrecover(_By), _By, 1, _xrecover(_By) * _By % P]


def _add(p1, p2):
    a = (p1[1] - p1[0]) * (p2[1] - p2[0]) % P
    b = (p1[1] + p1[0]) * (p2[1] + p2[0]) % P
    c = 2 * p1[3] * p2[3] * D % P
    dd = 2 * p1[2] * p2[2] % P
    e, f, g, h = b - a, dd - c, dd + c, b + a
    return [e * f % P, g * h % P, f * g % P, e * h % P]


def _mul(pt, e):
    r = [0, 1, 1, 0]
    while e:
        if e & 1:
            r = _add(r, pt)
        pt = _add(pt, pt)
        e >>= 1
    return r


def _on_curve(pt):
    x, y, z, t = pt
    return z % P and x * y % P == z * t % P and \
        (y * y - x * x - z * z - D * t * t) % P == 0


def _decode(s):
    y = int.from_bytes(s, "little") & ((1 << 255) - 1)
    x = _xrecover(y)
    if x & 1 != (s[31] >> 7) & 1:
        x = P - x
    pt = [x, y, 1, x * y % P]
    if not _on_curve(pt):
        raise ValueError("point is not on the curve")
    return pt


def ed25519_verify(sig, msg, pk):
    """True only if `sig` is a valid Ed25519 signature over `msg` under `pk`."""
    if len(sig) != 64 or len(pk) != 32:
        return False
    try:
        r_pt, a_pt = _decode(sig[:32]), _decode(pk)
    except ValueError:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= L:                       # a non-canonical S is a forged signature
        return False
    h = int.from_bytes(hashlib.sha512(sig[:32] + pk + msg).digest(), "little")
    lhs, rhs = _mul(_B, s), _add(r_pt, _mul(a_pt, h))
    return (lhs[0] * rhs[2] - rhs[0] * lhs[2]) % P == 0 and \
           (lhs[1] * rhs[2] - rhs[1] * lhs[2]) % P == 0
# ---------------------------------------------------------------------------


def _get(url, what):
    """Fetch over HTTPS using whatever this machine actually has.

    curl first, and not for style: the python3 that ships with macOS Command
    Line Tools has no CA bundle wired up until someone runs Install
    Certificates.command, so urllib raises CERTIFICATE_VERIFY_FAILED on a
    clean Mac. Measured here on 2026-08-26. curl uses the system trust store
    and just works. urllib stays as the fallback for machines without curl.
    """
    if shutil.which("curl"):
        r = subprocess.run(["curl", "-fsSL", "--max-time", "60", url],
                           capture_output=True)
        if r.returncode == 0:
            return r.stdout
        err = r.stderr.decode("utf-8", "replace").strip() or ("curl exit %d" % r.returncode)
        sys.exit("could not fetch the %s (%s): %s" % (what, url, err))
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.read()
    except Exception as e:
        sys.exit("could not fetch the %s (%s): %s" % (what, url, e))


def main():
    ap = argparse.ArgumentParser(description="Verify a Kin release.")
    ap.add_argument("--base", default=DEFAULT_BASE,
                    help="release directory to check (default: %s)" % DEFAULT_BASE)
    ap.add_argument("--key", default=KIN_PUBKEY_HEX,
                    help="Ed25519 public key, hex. Self-hosters pass their own.")
    ap.add_argument("--file", help="verify this local file instead of downloading")
    ap.add_argument("--dmg", action="store_true",
                    help="check the .dmg rather than the .tar.gz")
    a = ap.parse_args()

    base = a.base.rstrip("/")
    manifest = _get(base + "/manifest.json", "manifest")
    sig_b64 = _get(base + "/manifest.json.sig", "signature")

    try:
        sig = base64.b64decode(sig_b64.strip(), validate=True)
    except Exception:
        sys.exit("FAIL: manifest.json.sig is not valid base64 -- it did not arrive intact")
    try:
        pk = bytes.fromhex(a.key.strip())
    except ValueError:
        sys.exit("FAIL: --key is not hex")

    if not ed25519_verify(sig, manifest, pk):
        sys.exit("FAIL: the manifest signature does not match the public key.\n"
                 "      Someone other than the holder of the signing key wrote this\n"
                 "      manifest, or it was altered in transit. Install nothing.")
    print("ok  manifest signature is valid under %s..." % a.key[:16])

    m = json.loads(manifest)
    want = m["dmgSha256"] if a.dmg else m["sha256"]
    url = m["dmg"] if a.dmg else m["url"]
    print("ok  manifest says version %s" % m.get("version", "?"))

    if a.file:
        blob = open(a.file, "rb").read()
        where = a.file
    else:
        blob = _get(url, "release archive")
        where = url

    got = hashlib.sha256(blob).hexdigest()
    if got != want:
        sys.exit("FAIL: %s does not match the signed manifest.\n"
                 "      manifest: %s\n      actual:   %s" % (where, want, got))
    print("ok  %s matches the signed sha256 (%d bytes)" % (where, len(blob)))
    if "size" in m and not a.dmg and len(blob) != m["size"]:
        sys.exit("FAIL: byte count disagrees with the manifest (%d vs %d)"
                 % (len(blob), m["size"]))
    print("\nVERIFIED. This is the release the signing key signed.")


if __name__ == "__main__":
    main()

/**
 * The ICE candidate rewrite that puts media on netsim's delay line.
 *
 * Shared because a reconstructed copy of it FAILS SILENTLY: a version that
 * hooked only setRemoteDescription (this app trickles) and rewrote the IP
 * instead of the port produced 0 rewrites, which the guard caught only because
 * the guard exists. Anything subtler would have reported clean loopback numbers
 * under an "80 ms" heading. One copy, imported by every harness that shapes the
 * link.
 *
 * Contract: the page must have `window.__simProxy(ip, port) -> proxyPort`
 * exposed BEFORE this runs as an init script, and the caller must assert
 * `window.__rewrites` is non-empty once ICE has settled.
 */
export const P2P_REWRITE = `
  const OrigPC = window.RTCPeerConnection;
  window.__rewrites = [];
  const rewrite = async (line) => {
    const f = String(line).split(' ');
    if (f.length < 7 || !/^udp$/i.test(f[2])) return null;   // TCP candidates carry no media here
    const ip = f[4], port = Number(f[5]);
    if (!ip || !Number.isFinite(port) || port <= 0) return null;
    const np = await window.__simProxy(ip, port);
    if (!np) return null;
    f[5] = String(np);
    window.__rewrites.push({ from: ip + ':' + port, to: ip + ':' + np, typ: f[7] || '?' });
    return f.join(' ');
  };
  class SimPC extends OrigPC {
    async addIceCandidate(cand) {
      try {
        const line = typeof cand === 'string' ? cand : cand && cand.candidate;
        if (line) {   // an empty candidate is end-of-candidates and must pass through
          const out = await rewrite(line);
          if (out) {
            const init = typeof cand === 'string'
              ? out
              : { candidate: out, sdpMid: cand.sdpMid, sdpMLineIndex: cand.sdpMLineIndex,
                  usernameFragment: cand.usernameFragment };
            return super.addIceCandidate(init);
          }
        }
      } catch (e) { window.__rewrites.push({ error: String(e).slice(0, 120) }); }
      return super.addIceCandidate(cand);
    }
    async setRemoteDescription(desc) {
      // Chrome sometimes ships candidates inside the SDP instead of trickling them.
      // Missing those is how a run reports 80 ms while measuring 0.
      try {
        const sdp = desc && desc.sdp;
        if (sdp && /^a=candidate:/m.test(sdp)) {
          const lines = sdp.split(/\\r?\\n/);
          for (let i = 0; i < lines.length; i++) {
            if (!lines[i].startsWith('a=candidate:')) continue;
            const out = await rewrite(lines[i].slice(2));
            if (out) lines[i] = 'a=' + out;
          }
          return super.setRemoteDescription({ type: desc.type, sdp: lines.join('\\r\\n') });
        }
      } catch (e) { window.__rewrites.push({ error: 'sdp ' + String(e).slice(0, 100) }); }
      return super.setRemoteDescription(desc);
    }
  }
  window.RTCPeerConnection = SimPC;
`;

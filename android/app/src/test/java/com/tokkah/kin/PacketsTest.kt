package com.tokkah.kin

import com.tokkah.kin.net.KinClock
import com.tokkah.kin.net.Rendezvous
import com.tokkah.kin.net.Stun
import com.tokkah.kin.net.TimeSync
import com.tokkah.kin.net.Wire
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PacketsTest {
    @Test
    fun constantsMatchNetSwift() {
        assertEquals(0x544B0001, Wire.MAGIC)
        assertEquals(0x544B0006, Wire.HMAGIC)
        assertEquals(20, Wire.HDR)
        assertEquals(24, Wire.VHDR)
        assertEquals(32, Wire.TPKT)
        assertEquals(40, Wire.TPKTX)
        assertEquals(48, Wire.TPKTY)
        assertEquals(0x544B0009, com.tokkah.kin.net.Crypto.HS_MAGIC)
        assertEquals(136, com.tokkah.kin.net.Crypto.HS_LEN)
    }

    @Test
    fun signedHandshakeLayout() {
        val c = com.tokkah.kin.net.Crypto("room-x", ByteArray(32) { 7 })
        val pkt = c.handshakePacket(Wire.CAP_PCM16 or Wire.CAP_PCM_LP)
        assertEquals(com.tokkah.kin.net.Crypto.HS_LEN, pkt.size)
        // Little-endian magic on the wire: 09 00 4B 54.
        assertEquals(0x09, pkt[0].toInt())
        assertEquals(0x00, pkt[1].toInt())
        assertEquals(0x4B, pkt[2].toInt())
        assertEquals(0x54, pkt[3].toInt())
        assertTrue(pkt.copyOfRange(4, 36).contentEquals(c.myPublic))
        assertEquals(Wire.CAP_PCM16 or Wire.CAP_PCM_LP, com.tokkah.kin.net.Crypto.capsOf(pkt, pkt.size))
        assertTrue(pkt.copyOfRange(40, 72).contentEquals(c.myIdentity))
        // A same-key beat is the cached packet, byte for byte.
        assertTrue(pkt.contentEquals(c.handshakePacket(Wire.CAP_PCM16 or Wire.CAP_PCM_LP)))
    }

    @Test
    fun audioHeaderTagBits() {
        val samples = ShortArray(Wire.FPP) { (it * 100).toShort() }
        val out = ByteArray(2048)
        val n = Wire.packAudio(7, 0x1122334455667788L, samples, Wire.FPP, pcm16 = true, lp = true, out = out)
        val h = Wire.audioHeader(out, n)!!
        assertEquals(7, h.seq)
        assertEquals(0x1122334455667788L, h.capHost)
        assertEquals(Wire.FPP, h.frames)
        assertTrue(h.pcm16); assertTrue(h.lp)
        // LP payload carries its own length byte (Net.swift:516).
        val m = out[Wire.HDR].toInt() and 0xff
        assertEquals(Wire.HDR + 1 + m, n)
        // Decode the block back to the samples.
        val block = out.copyOfRange(Wire.HDR + 1, Wire.HDR + 1 + m)
        val dec = ShortArray(Wire.FPP)
        assertTrue(com.tokkah.kin.net.Lpc.decode(block, block.size, Wire.FPP, dec))
        assertTrue(dec.contentEquals(samples.copyOf(Wire.FPP)))
    }

    @Test
    fun videoHeaderRoundtrip() {
        val payload = ByteArray(3000) { it.toByte() }
        val out = ByteArray(Wire.VHDR + Wire.VPAYLOAD)
        val n = Wire.packVideoFragment(42, 99L, 1, 3, payload, Wire.VPAYLOAD, Wire.VPAYLOAD, out)
        assertEquals(Wire.VHDR + Wire.VPAYLOAD, n)
        val h = Wire.videoHeader(out, n)!!
        assertEquals(42, h.seq); assertEquals(99L, h.capHost)
        assertEquals(1, h.frag); assertEquals(3, h.nfrag)
        assertFalse(h.isParity); assertEquals(0, h.lastLen)
    }

    @Test
    fun textPacketRoundtripUtf8() {
        val pkt = Wire.packText("mm-hm 日本語", final = false, listening = true)
        val t = Wire.parseText(pkt, pkt.size)!!
        assertEquals("mm-hm 日本語", t.text)
        assertFalse(t.final); assertTrue(t.listening)
        assertNull(Wire.parseText(pkt, 6))
    }

    @Test
    fun timeProbeLayoutAndStateBytes() {
        val r = Wire.RxReport(lost = 5, recovered = 2, played = 1234, muted = true,
            qLevel = 3, status = Wire.ST_CLAIM or Wire.ST_VOICING, endProbByte = 128)
        val pkt = Wire.packReply(t1 = 111L, t2 = 222L, t3 = 333L, report = r)
        assertEquals(Wire.TPKTY, pkt.size)
        val p = Wire.parseT(pkt, pkt.size)!!
        assertEquals(1, p.kind)
        assertEquals(111L, p.t1); assertEquals(222L, p.t2); assertEquals(333L, p.t3)
        assertTrue(p.hasState)
        assertEquals(5, p.report!!.lost); assertEquals(2, p.report!!.recovered)
        assertEquals(1234, p.report!!.played)
        assertTrue(p.report!!.muted)
        assertEquals(3, p.report!!.qLevel)
        assertEquals(Wire.ST_CLAIM or Wire.ST_VOICING, p.report!!.status)
        assertEquals(128, p.report!!.endProbByte)
        // Old-build packet: TPKT bytes only still parses, no report.
        val old = Wire.parseT(pkt, Wire.TPKT)!!
        assertNull(old.report); assertFalse(old.hasState)
    }

    @Test
    fun timeSyncTakesMinDelaySampleAndRefusesNegative() {
        val ts = TimeSync()
        // In tick units (ns * 3/125). Base offsets cancel in the formula.
        fun t(ns: Long) = ns * 3 / 125
        // Three samples; the middle one has the smallest delay.
        ts.note(t(0), t(1_000_000_000L + 50_000_000), t(1_000_000_000L + 51_000_000), t(120_000_000))
        ts.note(t(0), t(1_000_000_000L + 20_000_000), t(1_000_000_000L + 21_000_000), t(50_000_000))
        ts.note(t(0), t(1_000_000_000L + 90_000_000), t(1_000_000_000L + 91_000_000), t(200_000_000))
        // Negative delay refused (turnaround exceeds round trip).
        ts.note(t(0), t(500), t(1_000_000_000L), t(100))
        assertEquals(3, ts.samples)
        assertNotNull(ts.thetaNs)
        // Min-delay sample: theta = ((t2-t1)+(t3-t4))/2 with ~48.6ms magnitudes.
        val expTheta = ((1_020_000_000L - 0) + (1_021_000_000L - 50_000_000)) / 2
        // Tick conversion truncates; allow 100 ns.
        assertTrue(Math.abs(ts.thetaNs!! - expTheta) < 100)
        assertEquals(49.0, ts.bestRttMs!!, 0.01)
    }

    @Test
    fun stunXorMappedAddressParsesByHand() {
        // Craft a Binding Success with XOR-MAPPED-ADDRESS 203.0.113.7:54321.
        val ip = intArrayOf(203, 0, 113, 7)
        val port = 54321
        val resp = ByteArray(32)
        resp[0] = 0x01; resp[1] = 0x01
        resp[2] = 0x00; resp[3] = 12                     // one attribute
        resp[4] = 0x21; resp[5] = 0x12; resp[6] = 0xA4.toByte(); resp[7] = 0x42
        // txid bytes 8..19 (zeros fine — parse helper checks via socket path only)
        resp[20] = 0x00; resp[21] = 0x20                 // XOR-MAPPED-ADDRESS
        resp[22] = 0x00; resp[23] = 8
        resp[24] = 0; resp[25] = 0x01                    // IPv4
        val xport = port xor (Stun.COOKIE ushr 16)
        resp[26] = (xport shr 8).toByte(); resp[27] = xport.toByte()
        for (k in 0 until 4) resp[28 + k] = (ip[k] xor ((Stun.COOKIE ushr (8 * (3 - k))) and 0xff)).toByte()
        // Drive the parser through a loopback socket pair.
        val server = java.net.DatagramSocket(0, java.net.InetAddress.getLoopbackAddress())
        val client = java.net.DatagramSocket(0, java.net.InetAddress.getLoopbackAddress())
        val responder = Thread {
            val buf = ByteArray(64)
            val pkt = java.net.DatagramPacket(buf, buf.size)
            server.receive(pkt)
            System.arraycopy(buf, 8, resp, 8, 12)        // echo the txid
            server.send(java.net.DatagramPacket(resp, resp.size, pkt.socketAddress))
        }
        responder.start()
        val m = Stun.discover(client, "127.0.0.1", server.localPort, timeoutMs = 3000)
        responder.join()
        server.close(); client.close()
        assertNotNull(m)
        assertEquals("203.0.113.7", m!!.ip)
        assertEquals(port, m.port)
    }

    @Test
    fun rendezvousParserShapes() {
        val peers = Rendezvous.parsePeers(
            """{"peers":[{"id":"abc","addr":"1.2.3.4:5000","local":"192.168.1.9:5000","relay":"9.8.7.6:41234","ageMs":150},{"id":"x","addr":"bad"}]}""")!!
        assertEquals(1, peers.size)
        val p = peers[0]
        assertEquals("abc", p.id); assertEquals("1.2.3.4", p.ip); assertEquals(5000, p.port)
        assertEquals("192.168.1.9", p.localIP); assertEquals(150, p.ageMs)
        assertEquals(41234, p.relayPort)
        assertEquals(0, Rendezvous.parsePeers("""{"peers":[]}""")!!.size)
        assertNull(Rendezvous.parsePeers("not json"))
    }

    @Test
    fun endProbByteMatchesSwiftRounding() {
        assertEquals(0, Wire.endProbByte(0.0))
        assertEquals(255, Wire.endProbByte(1.0))
        assertEquals(255, Wire.endProbByte(7.5))
        assertEquals(128, Wire.endProbByte(0.5019608))
        assertEquals(0.5019608, Wire.endProb(128), 1e-6)
    }

    @Test
    fun clockUnitsRoundTrip() {
        val ns = 1_234_567_890L
        val ticks = ns * 3 / 125
        assertTrue(Math.abs(KinClock.ns(ticks) - ns) <= 125 / 3 + 1)
    }
}

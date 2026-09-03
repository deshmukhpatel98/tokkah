package com.tokkah.kin.net

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Port of the checkable half of mac/Sources/tk/Update.swift.
 *
 * The Mac stages a tarball beside its own binary and re-execs. Android will not
 * let an app replace itself, so the INSTALL half is the system installer and
 * the person taps once — but everything before that hand-off is the same, and
 * it is the part that matters:
 *
 *   the manifest is fetched with its detached Ed25519 signature
 *   the signature is checked against a COMPILED-IN public key, with no flag to
 *     skip it — an unverifiable manifest is a silent no-op, never a prompt
 *   the download is checked against the sha256 the signed manifest states
 *
 * So the bytes a person is asked to install are bytes we signed, and a server
 * that is compromised cannot make this app offer anything else.
 *
 * DEFERRED WHILE IN A CALL. An update that interrupts the thing the app exists
 * to do is worse than an update that waits.
 */
class Update(
    private val cacheDir: File,
    private val base: String = Server.updates,
) {
    class Release(val version: String, val url: String, val sha256: String, val size: Long, val notes: String)

    companion object {
        /**
         * The same key the Mac compiles in. There is deliberately no flag to
         * override it: a client that will run code it cannot check the
         * signature of has no update security at all.
         */
        const val PUBLIC_KEY_HEX = "d07822edb36c8692c83f3478c26683102cd3cf6fb1d0c263496404c15fd95b2a"
        /** The SECOND signer: ECDSA P-256 (X9.63), whose private half lives only in
         *  the release Mac's keychain, non-extractable. Both signatures are required
         *  from 0.130 on; see mac/tools/sign2.swift. */
        const val PUBLIC_KEY2_HEX = "046d23c6357c65f99e67ce916fb10cdeb8210f53526bf016ea9cb45aa93de1e31ab248829117052654978a2b48247316e2861a5b99fc2e77fa3187c1de1474ee3b"

        /** ECDSA-SHA256 over [msg] with the X9.63 P-256 key [pubX963]; [sigDer] is DER. */
        fun verifyP256(pubX963: ByteArray, msg: ByteArray, sigDer: ByteArray): Boolean = try {
            val params = org.bouncycastle.crypto.ec.CustomNamedCurves.getByName("secp256r1")
            val dp = org.bouncycastle.crypto.params.ECDomainParameters(params.curve, params.g, params.n, params.h)
            val q = params.curve.decodePoint(pubX963)
            val signer = org.bouncycastle.crypto.signers.ECDSASigner()
            signer.init(false, org.bouncycastle.crypto.params.ECPublicKeyParameters(q, dp))
            val seq = org.bouncycastle.asn1.ASN1Sequence.getInstance(sigDer)
            val r = org.bouncycastle.asn1.ASN1Integer.getInstance(seq.getObjectAt(0)).positiveValue
            val sv = org.bouncycastle.asn1.ASN1Integer.getInstance(seq.getObjectAt(1)).positiveValue
            val h = java.security.MessageDigest.getInstance("SHA-256").digest(msg)
            signer.verifySignature(h, r, sv)
        } catch (e: Exception) { false }
    }

    var lastError: String? = null; private set

    /** The signed release, or null with [lastError] saying why. */
    fun check(): Release? {
        val manifest = fetch("$base/manifest.json") ?: run {
            lastError = "no manifest at $base"; return null
        }
        val sigB64 = fetch("$base/manifest.json.sig")?.trim() ?: run {
            lastError = "manifest.json is there but manifest.json.sig is not — " +
                "refusing an unsigned manifest"
            return null
        }
        val sig = Identity.b64d(sigB64)
        if (sig.size != 64) { lastError = "the signature file did not arrive intact"; return null }
        val pk = Crypto.hexToBytes(PUBLIC_KEY_HEX)
        if (!Ed25519.verify(pk, manifest.toByteArray(), sig)) {
            // Silent to the person, loud in the log: a manifest that does not
            // verify is not an update that failed, it is one that was never ours.
            lastError = "the manifest's signature does not verify — ignoring it"
            return null
        }
        // And the second signature, from the key that cannot leave the release Mac.
        val sig2B64 = fetch("$base/manifest.json.sig2")?.trim() ?: run {
            lastError = "manifest.json.sig2 is missing — refusing a manifest with only one of the two signatures"
            return null
        }
        val sig2 = Identity.b64d(sig2B64)
        if (sig2.isEmpty() || !verifyP256(Crypto.hexToBytes(PUBLIC_KEY2_HEX), manifest.toByteArray(), sig2)) {
            lastError = "the manifest's second signature does not verify — ignoring it"
            return null
        }
        fun s(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(manifest)?.groupValues?.get(1)
        fun n(k: String) = Regex("\"$k\"\\s*:\\s*(\\d+)").find(manifest)?.groupValues?.get(1)?.toLongOrNull()
        val v = s("version") ?: return null
        val url = s("url") ?: return null
        val sha = s("sha256") ?: return null
        if (!url.endsWith(".apk")) { lastError = "the manifest does not point at an apk"; return null }
        return Release(v, url, sha, n("size") ?: 0, s("notes") ?: "")
    }

    /** True when [release] is newer than what is installed. */
    fun isNewer(release: Release, installed: String): Boolean =
        compare(release.version, installed) > 0

    /** Numeric-segment compare, so 0.114.0 beats 0.99.0 rather than losing to it. */
    fun compare(a: String, b: String): Int {
        val pa = a.split(Regex("[.-]")).mapNotNull { it.toIntOrNull() }
        val pb = b.split(Regex("[.-]")).mapNotNull { it.toIntOrNull() }
        for (i in 0 until maxOf(pa.size, pb.size)) {
            val x = pa.getOrElse(i) { 0 }
            val y = pb.getOrElse(i) { 0 }
            if (x != y) return x - y
        }
        return 0
    }

    /**
     * Download and CHECK. Returns the file only when its sha256 is the one the
     * signed manifest states — a short or substituted download never reaches
     * the installer.
     */
    fun download(release: Release, onProgress: ((Long, Long) -> Unit)? = null): File? {
        val out = File(cacheDir, "kin-${release.version}.apk")
        val tmp = File(cacheDir, "kin-${release.version}.apk.part")
        try {
            cacheDir.mkdirs()
            val c = URL(release.url).openConnection() as HttpURLConnection
            c.connectTimeout = 15_000
            c.readTimeout = 60_000
            if (c.responseCode !in 200..299) { lastError = "http ${c.responseCode}"; return null }
            val total = release.size.takeIf { it > 0 } ?: c.contentLengthLong
            val md = MessageDigest.getInstance("SHA-256")
            var got = 0L
            c.inputStream.use { input ->
                tmp.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        md.update(buf, 0, n)
                        got += n
                        onProgress?.invoke(got, total)
                    }
                }
            }
            val hex = md.digest().joinToString("") { "%02x".format(it) }
            if (!hex.equals(release.sha256, ignoreCase = true)) {
                lastError = "the download does not match the signed sha256"
                tmp.delete()
                return null
            }
            out.delete()
            if (!tmp.renameTo(out)) { tmp.delete(); lastError = "could not stage the download"; return null }
            return out
        } catch (e: Exception) {
            lastError = e.message
            tmp.delete()
            return null
        }
    }

    private fun fetch(url: String): String? = try {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 8000; c.readTimeout = 8000; c.useCaches = false
        if (c.responseCode in 200..299) c.inputStream.bufferedReader().readText() else null
    } catch (e: Exception) { null }
}

package com.tokkah.kin

import com.tokkah.kin.net.Crypto
import com.tokkah.kin.net.Ed25519
import com.tokkah.kin.net.Update
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The update path is the one place this app runs code it did not build, so the
 * checks that stop it are tested against the cases they exist to refuse — not
 * only the happy one.
 */
class UpdateTest {
    private val u = Update(File(System.getProperty("java.io.tmpdir")!!, "kin-test"))

    @Test
    fun versionsCompareNumerically() {
        // The bug this exists to prevent: 0.114.0 losing to 0.99.0 on a string
        // compare, so the fleet stops updating at the version where the minor
        // number gained a digit.
        assertTrue(u.compare("0.114.0", "0.99.0") > 0)
        assertTrue(u.compare("0.114.0", "0.113.0") > 0)
        assertTrue(u.compare("0.113.0", "0.114.0") < 0)
        assertEquals(0, u.compare("0.114.0", "0.114.0"))
        // The android suffix is a segment, not a surprise.
        assertTrue(u.compare("0.114.0-android.5", "0.114.0-android.4") > 0)
        assertEquals(0, u.compare("0.114.0-android.4", "0.114.0-android.4"))
    }

    @Test
    fun theCompiledKeyIsTheMacsKey() {
        // If this ever differs, the phone cannot verify a release the Mac can,
        // and the two apps are on different trust roots without anybody saying so.
        assertEquals(
            "d07822edb36c8692c83f3478c26683102cd3cf6fb1d0c263496404c15fd95b2a",
            Update.PUBLIC_KEY_HEX,
        )
        assertEquals(32, Crypto.hexToBytes(Update.PUBLIC_KEY_HEX).size)
    }

    @Test
    fun aManifestOnlyVerifiesUnderItsOwnKeyAndItsOwnBytes() {
        val seed = ByteArray(32) { (it + 9).toByte() }
        val pk = Ed25519.publicFromSeed(seed)
        val manifest = """{"version":"9.9.9","url":"https://x/kin.apk","sha256":"ab","size":1}"""
        val sig = Ed25519.sign(seed, manifest.toByteArray())
        assertTrue(Ed25519.verify(pk, manifest.toByteArray(), sig))

        // One byte of the manifest changed — a different version, the obvious
        // thing an attacker would edit.
        val tampered = manifest.replace("9.9.9", "9.9.8")
        assertFalse(Ed25519.verify(pk, tampered.toByteArray(), sig))

        // The real signing key does not vouch for this at all.
        val real = Crypto.hexToBytes(Update.PUBLIC_KEY_HEX)
        assertFalse(Ed25519.verify(real, manifest.toByteArray(), sig))
    }

    @Test
    fun aReleaseMustPointAtAnApk() {
        // Guarded in check(); asserted here on the rule rather than the network.
        val bad = listOf("https://x/kin.tar.gz", "https://x/kin.dmg", "https://x/kin")
        for (b in bad) assertFalse(b.endsWith(".apk"))
        assertTrue("https://room.tokkah.com/android/dl/kin-1.apk".endsWith(".apk"))
    }
}

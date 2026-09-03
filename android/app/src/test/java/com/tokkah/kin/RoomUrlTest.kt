package com.tokkah.kin

import com.tokkah.kin.net.Server
import org.junit.Assert.assertEquals
import org.junit.Test

/** `roomURL` (main.swift 1668): a minted room is a path, anything else is `?r=`. */
class RoomUrlTest {
    @Test fun mintedRoomIsAPath() =
        assertEquals("https://kin.tokkah.com/gxg-kcrq-vwe", Server.roomURL("gxg-kcrq-vwe"))

    @Test fun namedRoomIsAQuery() =
        assertEquals("https://kin.tokkah.com/?r=standup", Server.roomURL("standup"))

    @Test fun hyphensSurviveInANamedRoom() =
        assertEquals("https://kin.tokkah.com/?r=team-standup", Server.roomURL("team-standup"))

    @Test fun almostMintedIsStillNamed() {
        assertEquals("https://kin.tokkah.com/?r=top-21446-bar", Server.roomURL("top-21446-bar"))
        assertEquals("https://kin.tokkah.com/?r=GXG-KCRQ-VWE", Server.roomURL("GXG-KCRQ-VWE"))
    }
}

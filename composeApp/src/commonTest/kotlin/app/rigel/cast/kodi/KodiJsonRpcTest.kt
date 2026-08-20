package app.rigel.cast.kodi

import kotlin.test.Test
import kotlin.test.assertEquals

class KodiJsonRpcTest {

    @Test
    fun playerOpenFileBuildsExactRequest() {
        val body = KodiJsonRpc.playerOpenFile("http://192.168.1.5:8080/movie.mkv")
        val expected = """{"jsonrpc":"2.0","id":1,"method":"Player.Open","params":{"item":{"file":"http://192.168.1.5:8080/movie.mkv"}}}"""
        assertEquals(expected, body)
    }

    @Test
    fun playerOpenFileEscapesQuotesAndBackslashes() {
        val body = KodiJsonRpc.playerOpenFile("""http://x/a"b\c.mkv""")
        assertEquals(true, body.contains("""a\"b\\c.mkv"""))
    }

    @Test
    fun playPauseAndStopExact() {
        assertEquals("""{"jsonrpc":"2.0","id":1,"method":"Player.PlayPause","params":{"playerid":1}}""", KodiJsonRpc.playerPlayPause())
        assertEquals("""{"jsonrpc":"2.0","id":1,"method":"Player.Stop","params":{"playerid":1}}""", KodiJsonRpc.playerStop())
    }

    @Test
    fun seekUsesPercentage() {
        val body = KodiJsonRpc.playerSeekPercentage(42.5)
        assertEquals(true, body.contains("""{"playerid":1,"value":{"percentage":42.5}}"""))
    }

    @Test
    fun getPropertiesRequestsTimeAndTotal() {
        val body = KodiJsonRpc.playerGetProperties()
        assertEquals(true, body.contains("\"percentage\""))
        assertEquals(true, body.contains("\"time\""))
        assertEquals(true, body.contains("\"totaltime\""))
    }

    @Test
    fun positionParsesTimeObjects() {
        val json = """{"id":1,"jsonrpc":"2.0","result":{"percentage":25.0,"time":{"hours":0,"minutes":1,"seconds":2,"milliseconds":500},"totaltime":{"hours":0,"minutes":4,"seconds":10,"milliseconds":0}}}"""
        assertEquals(62_500L, KodiJsonRpc.parseTimeObject(json, "time"))
        assertEquals(250_000L, KodiJsonRpc.parseTimeObject(json, "totaltime"))
        assertEquals(null, KodiJsonRpc.parseTimeObject("""{"result":{}}""", "time"))
    }

    @Test
    fun requestWithoutParamsOmitsParamsKey() {
        val body = KodiJsonRpc.request("Player.GetActivePlayers")
        assertEquals("""{"jsonrpc":"2.0","id":1,"method":"Player.GetActivePlayers"}""", body)
    }

    @Test
    fun seekZeroRendersExactly() {
        assertEquals(true, KodiJsonRpc.playerSeekPercentage(0.0).contains("\"percentage\":0.0"))
    }

    @Test
    fun jsonEscapeEscapesBackslashAndQuote() {
        assertEquals("""a\\b\"c""", KodiJsonRpc.jsonEscape("""a\b"c"""))
    }
}

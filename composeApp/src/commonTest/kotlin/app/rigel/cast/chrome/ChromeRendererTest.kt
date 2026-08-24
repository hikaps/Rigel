package app.rigel.cast.chrome

import app.rigel.cast.CastTarget
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class ChromeRendererTest {
    private lateinit var bridge: ScriptedBridge
    private val device = ChromeDevice("chrome-1", "192.168.1.50", 8009, "Living Room TV")

    @BeforeTest
    fun setUp() {
        bridge = ScriptedBridge()
        ChromecastBridgeFactory.register(bridge)
    }

    @AfterTest
    fun tearDown() {
        ChromecastBridgeFactory.register(null)
    }

    @Test
    fun launchSendsCastV2SequenceAndConfirmsPlayback() = runTest {
        val result = ChromeRenderer(bridge).launch(device, "http://host/movie.mp4", "Movie")

        assertEquals("Sent to Living Room TV", result)
        assertEquals(
            listOf("CONNECT", "LAUNCH", "PONG", "CONNECT", "LOAD"),
            bridge.sent.map { ChromePayloads.messageType(it.payloadUtf8) },
        )
        assertEquals("192.168.1.50", bridge.openHost)
        assertEquals(8009, bridge.openPort)
    }

    @Test
    fun adapterAndDispatcherTargetChromecast() = runTest {
        val target = CastTarget.Chrome(device)
        val result = ChromeAdapter.cast(target, "http://host/movie.mp4", "Movie", HttpClient(MockEngine { respond("") }))

        assertEquals("Sent to Living Room TV", result)
        assertFalse(ChromeAdapter.capabilities().supportsSeek)
        assertFalse(ChromeAdapter.capabilities().supportsPosition)
    }

    @Test
    fun launchErrorIsReported() = runTest {
        bridge.launchError = true
        assertEquals(
            "Chromecast launch failed (NOT_FOUND)",
            ChromeRenderer(bridge).launch(device, "http://host/movie.mp4", "Movie"),
        )
    }

    @Test
    fun probeUsesReceiverStatus() = runTest {
        assertTrue(ChromeRenderer(bridge).probe(device.host, device.port))
        bridge.probeResponse = false
        assertFalse(ChromeRenderer(bridge).probe(device.host, device.port))
    }

    @Test
    fun timeoutReturnsConfirmationError() = runTest {
        bridge.respond = false
        val result = async { ChromeRenderer(bridge).launch(device, "http://host/movie.mp4", "Movie") }
        runCurrent()
        advanceTimeBy(15_001)
        assertEquals("Chromecast did not confirm playback", result.await())
    }

    private class ScriptedBridge : ChromecastBridge {
        var respond = true
        var launchError = false
        var probeResponse = true
        var openHost: String? = null
        var openPort: Int? = null
        val sent = mutableListOf<CastFrame>()
        private var onFrame: ((ByteArray) -> Unit)? = null

        override fun discover(timeoutMs: Int, onResult: (List<ChromeDevice>) -> Unit) {
            onResult(listOf(ChromeDevice("discovered", "192.168.1.51", 8009, "Kitchen TV")))
        }

        override fun open(
            host: String,
            port: Int,
            onFrame: (ByteArray) -> Unit,
            onError: (String) -> Unit,
            onOpen: (CastWireConnection?, String?) -> Unit,
        ) {
            openHost = host
            openPort = port
            this.onFrame = onFrame
            onOpen(
                object : CastWireConnection {
                    override fun send(frame: ByteArray) {
                        val decoded = CastWire.decode(frame) ?: return
                        sent += decoded
                        if (!respond) return
                        val responseRequestId = ChromePayloads.requestId(decoded.payloadUtf8) ?: 0
                        when (ChromePayloads.messageType(decoded.payloadUtf8)) {
                            "LAUNCH" -> {
                                if (launchError) {
                                    emit(
                                        source = "receiver-0",
                                        destination = "sender-rigel",
                                        namespace = ChromePayloads.NS_RECEIVER,
                                        payload = "{\"type\":\"LAUNCH_ERROR\",\"reason\":\"NOT_FOUND\",\"requestId\":$responseRequestId}",
                                    )
                                } else {
                                    emit(
                                        source = "receiver-0",
                                        destination = "sender-rigel",
                                        namespace = ChromePayloads.NS_HEARTBEAT,
                                        payload = "{\"type\":\"PING\"}",
                                    )
                                    // Stale receiver status must not select this wrong transport.
                                    emit(
                                        source = "receiver-0",
                                        destination = "sender-rigel",
                                        namespace = ChromePayloads.NS_RECEIVER,
                                        payload = "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1,\"status\":{\"applications\":[{\"transportId\":\"wrong\"}]} }",
                                    )
                                    emit(
                                        source = "receiver-0",
                                        destination = "sender-rigel",
                                        namespace = ChromePayloads.NS_RECEIVER,
                                        payload = "{\"type\":\"RECEIVER_STATUS\",\"requestId\":$responseRequestId,\"status\":{\"applications\":[{\"transportId\":\"transport-1\"}]}}",
                                    )
                                }
                            }
                            "LOAD" -> {
                                // A stale media update must not complete this request.
                                emit(
                                    source = "transport-1",
                                    destination = "sender-rigel",
                                    namespace = ChromePayloads.NS_MEDIA,
                                    payload = "{\"type\":\"MEDIA_STATUS\",\"requestId\":1,\"status\":[{\"playerState\":\"PLAYING\"}]}",
                                )
                                emit(
                                    source = "transport-1",
                                    destination = "sender-rigel",
                                    namespace = ChromePayloads.NS_MEDIA,
                                    payload = "{\"type\":\"MEDIA_STATUS\",\"requestId\":$responseRequestId,\"status\":[{\"playerState\":\"BUFFERING\"}]}",
                                )
                            }
                            "GET_STATUS" -> if (probeResponse) emit(
                                source = "receiver-0",
                                destination = "sender-rigel",
                                namespace = ChromePayloads.NS_RECEIVER,
                                payload = "{\"type\":\"RECEIVER_STATUS\",\"requestId\":$responseRequestId,\"status\":{}}",
                            )
                        }
                    }

                    override fun close() = Unit
                },
                null,
            )
        }

        private fun emit(source: String, destination: String, namespace: String, payload: String) {
            onFrame?.invoke(CastWire.encode(CastFrame(source, destination, namespace, payload)))
        }
    }
}

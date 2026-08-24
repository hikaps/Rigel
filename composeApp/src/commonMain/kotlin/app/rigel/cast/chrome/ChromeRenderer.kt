package app.rigel.cast.chrome

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * CASTV2 launch driver. The native bridge only supplies a byte-oriented TLS
 * connection; all protocol sequencing remains common Kotlin and testable.
 */
class ChromeRenderer(private val bridge: ChromecastBridge) {
    private val senderId = "sender-rigel"
    private val receiverId = "receiver-0"

    suspend fun launch(device: ChromeDevice, url: String, title: String): String = try {
        withTimeout(15_000) {
            launchInternal(device, url, title)
        }
    } catch (_: TimeoutCancellationException) {
        "Chromecast did not confirm playback"
    } catch (e: CancellationException) {
        throw e
    } catch (_: Throwable) {
        "Chromecast did not respond"
    }

    suspend fun probe(host: String, port: Int): Boolean = try {
        withTimeout<Boolean>(3_000) {
            val frames = Channel<ByteArray>(Channel.UNLIMITED)
            val connection = open(host, port) { frames.trySend(it) }
            try {
                var requestId = 1
                send(connection, receiverId, ChromePayloads.NS_CONNECTION, ChromePayloads.connect(requestId++))
                send(connection, receiverId, ChromePayloads.NS_RECEIVER, ChromePayloads.getStatus(requestId++))
                var found = false
                while (!found) {
                    val frame = nextFrame(frames, connection, requestId)
                    found = frame.namespace == ChromePayloads.NS_RECEIVER &&
                        ChromePayloads.messageType(frame.payloadUtf8) == "RECEIVER_STATUS"
                }
                found
            } finally {
                connection.close()
                frames.close()
            }
        }
    } catch (_: TimeoutCancellationException) {
        false
    } catch (e: CancellationException) {
        throw e
    } catch (_: Throwable) {
        false
    }

    private suspend fun launchInternal(device: ChromeDevice, url: String, title: String): String {
        val frames = Channel<ByteArray>(Channel.UNLIMITED)
        var connection: CastWireConnection? = null
        try {
            connection = open(device.host, device.port) { frames.trySend(it) }
            var requestId = 1
            send(connection, receiverId, ChromePayloads.NS_CONNECTION, ChromePayloads.connect(requestId++))
            send(
                connection,
                receiverId,
                ChromePayloads.NS_RECEIVER,
                ChromePayloads.launch(ChromePayloads.DEFAULT_MEDIA_APP_ID, requestId++),
            )

            var transportId: String? = null
            while (transportId == null) {
                val frame = nextFrame(frames, connection, requestId)
                if (frame.namespace != ChromePayloads.NS_RECEIVER) continue
                when (ChromePayloads.messageType(frame.payloadUtf8)) {
                    "LAUNCH_ERROR" -> {
                        val reason = ChromePayloads.errorReason(frame.payloadUtf8) ?: "unknown error"
                        return "Chromecast launch failed ($reason)"
                    }
                    "RECEIVER_STATUS" -> transportId = ChromePayloads.extractTransportId(frame.payloadUtf8)
                }
            }

            send(
                connection,
                transportId,
                ChromePayloads.NS_CONNECTION,
                ChromePayloads.connect(requestId++),
            )
            send(
                connection,
                transportId,
                ChromePayloads.NS_MEDIA,
                ChromePayloads.load(
                    url = url,
                    title = title,
                    contentType = ChromePayloads.contentTypeFor(url),
                    requestId = requestId++,
                ),
            )

            while (true) {
                val frame = nextFrame(frames, connection, requestId)
                if (frame.namespace != ChromePayloads.NS_MEDIA) continue
                when (ChromePayloads.messageType(frame.payloadUtf8)) {
                    "LOAD_FAILED" -> return "Chromecast load failed"
                    "MEDIA_STATUS" -> {
                        if (frame.payloadUtf8.contains("\"playerState\"")) {
                            return "Sent to ${device.name.ifBlank { "Chromecast" }}"
                        }
                    }
                }
            }
        } finally {
            connection?.close()
            frames.close()
        }
    }

    private suspend fun open(
        host: String,
        port: Int,
        onFrame: (ByteArray) -> Unit,
    ): CastWireConnection = suspendCancellableCoroutine { continuation ->
        bridge.open(host, port, onFrame) { connection, errorMsg ->
            if (!continuation.isActive) {
                connection?.close()
            } else if (connection != null) {
                continuation.resume(connection)
            } else {
                continuation.resumeWithException(
                    IllegalStateException(errorMsg ?: "Chromecast connection failed"),
                )
            }
        }
    }

    private suspend fun nextFrame(
        frames: Channel<ByteArray>,
        connection: CastWireConnection,
        requestId: Int,
    ): CastFrame {
        while (true) {
            val decoded = CastWire.decode(frames.receive()) ?: continue
            if (decoded.namespace == ChromePayloads.NS_HEARTBEAT &&
                ChromePayloads.messageType(decoded.payloadUtf8) == "PING"
            ) {
                send(
                    connection,
                    decoded.sourceId,
                    ChromePayloads.NS_HEARTBEAT,
                    ChromePayloads.pong(requestId),
                )
                continue
            }
            return decoded
        }
    }

    private fun send(
        connection: CastWireConnection,
        destinationId: String,
        namespace: String,
        payload: String,
    ) {
        connection.send(CastWire.encode(CastFrame(senderId, destinationId, namespace, payload)))
    }
}

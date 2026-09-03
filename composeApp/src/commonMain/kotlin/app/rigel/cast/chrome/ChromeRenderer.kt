package app.rigel.cast.chrome

import app.rigel.cast.CastResult
import app.rigel.cast.ChromeDevice
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

    suspend fun launch(device: ChromeDevice, url: String, title: String): CastResult = try {
        withTimeout(15_000) {
            launchInternal(device, url, title)
        }
    } catch (_: TimeoutCancellationException) {
        CastResult.Rejected("Chromecast did not confirm playback")
    } catch (e: CancellationException) {
        throw e
    } catch (e: ChromecastTransportException) {
        CastResult.Rejected("Chromecast connection failed: ${e.message}")
    } catch (_: Throwable) {
        CastResult.Rejected("Chromecast did not respond")
    }

    suspend fun probe(host: String, port: Int): Boolean = try {
        withTimeout<Boolean>(3_000) {
            val events = Channel<Incoming>(Channel.UNLIMITED)
            val connection = open(
                host,
                port,
                onFrame = { events.trySend(Incoming.Frame(it)) },
                onError = { events.trySend(Incoming.Error(it)) },
            )
            try {
                var requestId = 1
                send(connection, receiverId, ChromePayloads.NS_CONNECTION, ChromePayloads.connect(requestId++))
                val statusRequestId = requestId++
                send(connection, receiverId, ChromePayloads.NS_RECEIVER, ChromePayloads.getStatus(statusRequestId))
                var found = false
                while (!found) {
                    val frame = nextFrame(events, connection, requestId)
                    found = isReply(frame, receiverId, ChromePayloads.NS_RECEIVER) &&
                        ChromePayloads.messageType(frame.payloadUtf8) == "RECEIVER_STATUS" &&
                        ChromePayloads.requestId(frame.payloadUtf8) == statusRequestId
                }
                found
            } finally {
                connection.close()
                events.close()
            }
        }
    } catch (_: TimeoutCancellationException) {
        false
    } catch (e: CancellationException) {
        throw e
    } catch (_: Throwable) {
        false
    }

    private suspend fun launchInternal(device: ChromeDevice, url: String, title: String): CastResult {
        val events = Channel<Incoming>(Channel.UNLIMITED)
        val connection = open(
            device.host,
            device.port,
            onFrame = { events.trySend(Incoming.Frame(it)) },
            onError = { events.trySend(Incoming.Error(it)) },
        )
        try {
            var requestId = 1
            send(connection, receiverId, ChromePayloads.NS_CONNECTION, ChromePayloads.connect(requestId++))
            val launchRequestId = requestId++
            send(
                connection,
                receiverId,
                ChromePayloads.NS_RECEIVER,
                ChromePayloads.launch(ChromePayloads.DEFAULT_MEDIA_APP_ID, launchRequestId),
            )

            var transportId: String? = null
            while (transportId == null) {
                val frame = nextFrame(events, connection, requestId)
                if (!isReply(frame, receiverId, ChromePayloads.NS_RECEIVER)) continue
                if (ChromePayloads.requestId(frame.payloadUtf8) != launchRequestId) continue
                when (ChromePayloads.messageType(frame.payloadUtf8)) {
                    "LAUNCH_ERROR" -> {
                        val reason = ChromePayloads.errorReason(frame.payloadUtf8) ?: "unknown error"
                        return CastResult.Rejected("Chromecast launch failed ($reason)")
                    }
                    "RECEIVER_STATUS" -> transportId = ChromePayloads.extractTransportId(frame.payloadUtf8)
                }
            }

            val mediaTransportId = transportId
            send(
                connection,
                mediaTransportId,
                ChromePayloads.NS_CONNECTION,
                ChromePayloads.connect(requestId++),
            )
            val loadRequestId = requestId++
            send(
                connection,
                mediaTransportId,
                ChromePayloads.NS_MEDIA,
                ChromePayloads.load(
                    url = url,
                    title = title,
                    contentType = ChromePayloads.contentTypeFor(url),
                    requestId = loadRequestId,
                ),
            )

            while (true) {
                val frame = nextFrame(events, connection, requestId)
                if (!isReply(frame, mediaTransportId, ChromePayloads.NS_MEDIA)) continue
                if (ChromePayloads.requestId(frame.payloadUtf8) != loadRequestId) continue
                when (ChromePayloads.messageType(frame.payloadUtf8)) {
                    "LOAD_FAILED" -> return CastResult.Rejected("Chromecast load failed")
                    "MEDIA_STATUS" -> {
                        if (frame.payloadUtf8.contains("\"playerState\"")) {
                            return CastResult.Sent("Sent to ${device.name.ifBlank { "Chromecast" }}")
                        }
                    }
                }
            }
        } finally {
            connection.close()
            events.close()
        }
    }

    private suspend fun open(
        host: String,
        port: Int,
        onFrame: (ByteArray) -> Unit,
        onError: (String) -> Unit,
    ): CastWireConnection = suspendCancellableCoroutine { continuation ->
        bridge.open(host, port, onFrame, { errorMsg ->
            if (continuation.isActive) {
                continuation.resumeWithException(ChromecastTransportException(errorMsg))
            } else {
                onError(errorMsg)
            }
        }) { connection, errorMsg ->
            if (!continuation.isActive) {
                connection?.close()
            } else if (connection != null) {
                continuation.resume(connection)
            } else {
                continuation.resumeWithException(
                    ChromecastTransportException(errorMsg ?: "Chromecast connection failed"),
                )
            }
        }
    }

    private suspend fun nextFrame(
        events: Channel<Incoming>,
        connection: CastWireConnection,
        requestId: Int,
    ): CastFrame {
        while (true) {
            when (val incoming = events.receive()) {
                is Incoming.Error -> throw ChromecastTransportException(incoming.message)
                is Incoming.Frame -> {
                    val decoded = CastWire.decode(incoming.bytes) ?: continue
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
        }
    }

    private fun isReply(frame: CastFrame, expectedSourceId: String, expectedNamespace: String): Boolean =
        frame.sourceId == expectedSourceId &&
            frame.destinationId == senderId &&
            frame.namespace == expectedNamespace

    private fun send(
        connection: CastWireConnection,
        destinationId: String,
        namespace: String,
        payload: String,
    ) {
        connection.send(CastWire.encode(CastFrame(senderId, destinationId, namespace, payload)))
    }

    private sealed interface Incoming {
        data class Frame(val bytes: ByteArray) : Incoming
        data class Error(val message: String) : Incoming
    }

    private class ChromecastTransportException(message: String) : Exception(message)
}

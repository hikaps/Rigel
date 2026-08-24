package app.rigel.cast.chrome

/** CASTV2 protobuf envelope payload (the outer message, not the TCP length prefix). */
data class CastFrame(
    val sourceId: String,
    val destinationId: String,
    val namespace: String,
    val payloadUtf8: String,
)

/** Minimal protobuf codec for the CASTV2 CastMessage envelope. */
object CastWire {
    fun encode(frame: CastFrame): ByteArray {
        val out = ArrayList<Byte>()
        addVarintField(out, 1, 0)
        addStringField(out, 2, frame.sourceId)
        addStringField(out, 3, frame.destinationId)
        addStringField(out, 4, frame.namespace)
        addVarintField(out, 5, 0) // PayloadType.STRING
        addStringField(out, 6, frame.payloadUtf8)
        return out.toByteArray()
    }

    fun decode(bytes: ByteArray): CastFrame? {
        var index = 0
        var source: String? = null
        var destination: String? = null
        var namespace: String? = null
        var payload: String? = null
        while (index < bytes.size) {
            val tag = readVarint(bytes, index) ?: return null
            index = tag.next
            val field = (tag.value shr 3).toInt()
            val wire = (tag.value and 7).toInt()
            when (field) {
                1, 5 -> {
                    if (wire != 0) return null
                    val value = readVarint(bytes, index) ?: return null
                    index = value.next
                }
                2, 3, 4, 6 -> {
                    if (wire != 2) return null
                    val length = readVarint(bytes, index) ?: return null
                    index = length.next
                    if (length.value < 0 || length.value > bytes.size - index) return null
                    val end = index + length.value.toInt()
                    val text = bytes.copyOfRange(index, end).decodeToString()
                    when (field) {
                        2 -> source = text
                        3 -> destination = text
                        4 -> namespace = text
                        6 -> payload = text
                    }
                    index = end
                }
                else -> {
                    index = skipField(bytes, index, wire) ?: return null
                }
            }
        }
        return if (source != null && destination != null && namespace != null && payload != null) {
            CastFrame(source, destination, namespace, payload)
        } else null
    }

    private fun addVarintField(out: MutableList<Byte>, field: Int, value: Long) {
        addVarint(out, (field shl 3).toLong())
        addVarint(out, value)
    }

    private fun addStringField(out: MutableList<Byte>, field: Int, value: String) {
        val bytes = value.encodeToByteArray()
        addVarint(out, ((field shl 3) or 2).toLong())
        addVarint(out, bytes.size.toLong())
        out.addAll(bytes.toList())
    }

    private fun addVarint(out: MutableList<Byte>, value: Long) {
        var remaining = value
        do {
            var byte = (remaining and 0x7f).toInt()
            remaining = remaining ushr 7
            if (remaining != 0L) byte = byte or 0x80
            out += byte.toByte()
        } while (remaining != 0L)
    }

    private data class Varint(val value: Long, val next: Int)

    private fun readVarint(bytes: ByteArray, start: Int): Varint? {
        var index = start
        var value = 0L
        var shift = 0
        while (index < bytes.size && shift <= 63) {
            val byte = bytes[index++].toInt() and 0xff
            value = value or ((byte and 0x7f).toLong() shl shift)
            if ((byte and 0x80) == 0) return Varint(value, index)
            shift += 7
        }
        return null
    }

    private fun skipField(bytes: ByteArray, start: Int, wire: Int): Int? {
        var index = start
        return when (wire) {
            0 -> readVarint(bytes, index)?.next
            1 -> if (bytes.size - index >= 8) index + 8 else null
            2 -> {
                val length = readVarint(bytes, index) ?: return null
                index = length.next
                if (length.value < 0 || length.value > bytes.size - index) null
                else index + length.value.toInt()
            }
            5 -> if (bytes.size - index >= 4) index + 4 else null
            else -> null
        }
    }
}

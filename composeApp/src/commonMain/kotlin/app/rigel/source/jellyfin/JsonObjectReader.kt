package app.rigel.source.jellyfin

/**
 * Small dependency-free JSON walker. It exposes scalar fields for every object
 * and recursively visits nested objects, which is sufficient for Jellyfin's
 * item envelopes on all supported targets.
 */
internal class JsonObjectReader(
    private val source: String,
    private val onObjectAtPath: ((List<String>, Map<String, String>) -> Unit)? = null,
    private val onObject: (Map<String, String>) -> Unit = {},
) {
    private var index = 0

    fun parseItems() {
        skipWhitespace()
        when {
            takeIf('[') -> {
                index--
                parseItemArray()
            }
            takeIf('{') -> {
                index--
                parseItemsEnvelope()
            }
            else -> error("Expected Jellyfin item array or envelope")
        }
        skipWhitespace()
        if (index != source.length) error("Trailing JSON content")
    }

    fun parseObjectsWithPaths() {
        skipWhitespace()
        parseValue(emitObjects = true)
        skipWhitespace()
        if (index != source.length) error("Trailing JSON content")
    }


    private fun parseItemsEnvelope() {
        expect('{')
        skipWhitespace()
        if (takeIf('}')) return
        while (true) {
            skipWhitespace()
            val key = parseString()
            skipWhitespace()
            expect(':')
            skipWhitespace()
            if (key == "Items" && index < source.length && source[index] == '[') {
                parseItemArray()
            } else {
                parseValue(emitObjects = false)
            }
            skipWhitespace()
            when {
                takeIf('}') -> return
                takeIf(',') -> Unit
                else -> error("Expected object separator at $index")
            }
        }
    }

    private fun parseItemArray() {
        expect('[')
        skipWhitespace()
        if (takeIf(']')) return
        while (true) {
            skipWhitespace()
            if (index < source.length && source[index] == '{') {
                onObject(parseObject(emitObject = false))
            } else {
                parseValue(emitObjects = false)
            }
            skipWhitespace()
            when {
                takeIf(']') -> return
                takeIf(',') -> Unit
                else -> error("Expected array separator at $index")
            }
        }
    }
    private fun parseValue(
        emitObjects: Boolean,
        path: List<String> = emptyList(),
    ): String? {
        skipWhitespace()
        if (index >= source.length) error("Missing JSON value")
        return when (source[index]) {
            '"' -> parseString()
            '{' -> {
                parseObject(emitObjects, path)
                null
            }
            '[' -> {
                parseArray(emitObjects, path)
                null
            }
            't' -> {
                consumeLiteral("true")
                "true"
            }
            'f' -> {
                consumeLiteral("false")
                "false"
            }
            'n' -> {
                consumeLiteral("null")
                null
            }
            '-', in '0'..'9' -> parseNumber()
            else -> error("Invalid JSON value at $index")
        }
    }

    private fun parseObject(
        emitObject: Boolean,
        path: List<String> = emptyList(),
    ): Map<String, String> {
        expect('{')
        val fields = mutableMapOf<String, String>()
        skipWhitespace()
        if (takeIf('}')) {
            if (emitObject) {
                onObject(fields)
                onObjectAtPath?.invoke(path, fields)
            }
            return fields
        }
        while (true) {
            skipWhitespace()
            val key = parseString()
            skipWhitespace()
            expect(':')
            parseValue(emitObjects = emitObject, path = path + key)?.let { fields[key] = it }
            skipWhitespace()
            when {
                takeIf('}') -> {
                    if (emitObject) {
                        onObject(fields)
                        onObjectAtPath?.invoke(path, fields)
                    }
                    return fields
                }
                takeIf(',') -> Unit
                else -> error("Expected object separator at $index")
            }
        }
    }

    private fun parseArray(
        emitObjects: Boolean,
        path: List<String> = emptyList(),
    ) {
        expect('[')
        skipWhitespace()
        if (takeIf(']')) return
        var elementIndex = 0
        while (true) {
            parseValue(emitObjects, path + elementIndex.toString())
            skipWhitespace()
            when {
                takeIf(']') -> return
                takeIf(',') -> elementIndex++
                else -> error("Expected array separator at $index")
            }
        }
    }

    private fun parseString(): String {
        expect('"')
        val out = StringBuilder()
        while (index < source.length) {
            when (val c = source[index++]) {
                '"' -> return out.toString()
                '\\' -> {
                    if (index >= source.length) error("Unterminated JSON escape")
                    when (val escaped = source[index++]) {
                        '"', '\\', '/' -> out.append(escaped)
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> {
                            if (index + 4 > source.length) error("Incomplete unicode escape")
                            val hex = source.substring(index, index + 4)
                            val code = hex.toIntOrNull(16) ?: error("Invalid unicode escape: $hex")
                            out.append(code.toChar())
                            index += 4
                        }
                        else -> error("Invalid JSON escape: $escaped")
                    }
                }
                else -> {
                    if (c < ' ') error("Unescaped control character")
                    out.append(c)
                }
            }
        }
        error("Unterminated JSON string")
    }

    private fun parseNumber(): String {
        val start = index
        if (index < source.length && source[index] == '-') index++
        // Integer part: single 0 or non-zero lead.
        if (index < source.length && source[index] == '0') {
            index++
        } else {
            val digitsStart = index
            while (index < source.length && source[index] in '0'..'9') index++
            if (index == digitsStart) error("Invalid JSON number at $start")
        }
        if (index < source.length && source[index] !in ",}] \n\r\t" &&
            source[index] != '.' && source[index] != 'e' && source[index] != 'E'
        ) {
            error("Invalid JSON number at $start")
        }
        if (index < source.length && source[index] == '.') {
            index++
            val fracStart = index
            while (index < source.length && source[index] in '0'..'9') index++
            if (index == fracStart) error("Invalid JSON number at $start")
        }
        if (index < source.length && (source[index] == 'e' || source[index] == 'E')) {
            index++
            if (index < source.length && (source[index] == '+' || source[index] == '-')) index++
            val expStart = index
            while (index < source.length && source[index] in '0'..'9') index++
            if (index == expStart) error("Invalid JSON number at $start")
        }
        if (index < source.length && source[index] !in ",}] \n\r\t") {
            error("Invalid JSON number at $start")
        }
        return source.substring(start, index)
    }

    private fun consumeLiteral(literal: String) {
        if (!source.startsWith(literal, index)) error("Invalid JSON literal at $index")
        index += literal.length
    }

    private fun skipWhitespace() {
        while (index < source.length && source[index] in " \n\r\t") index++
    }

    private fun expect(c: Char) {
        if (index >= source.length || source[index] != c) error("Expected '$c' at $index")
        index++
    }

    private fun takeIf(c: Char): Boolean {
        if (index < source.length && source[index] == c) {
            index++
            return true
        }
        return false
    }
}

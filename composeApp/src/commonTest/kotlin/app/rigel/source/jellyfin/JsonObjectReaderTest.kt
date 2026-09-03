package app.rigel.source.jellyfin

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class JsonObjectReaderTest {

    private fun itemFields(json: String): List<Map<String, String>> {
        val out = mutableListOf<Map<String, String>>()
        JsonObjectReader(json) { fields -> out += fields }.parseItems()
        return out
    }

    @Test
    fun parsesBareArrayOfObjects() {
        val fields = itemFields("""[{"Id":"a","Name":"One"},{"Id":"b","Name":"Two"}]""")
        assertEquals(
            listOf(mapOf("Id" to "a", "Name" to "One"), mapOf("Id" to "b", "Name" to "Two")),
            fields,
        )
    }

    @Test
    fun parsesItemsEnvelopeAndSkipsOtherEnvelopeKeys() {
        val json = """{"TotalRecordCount":2,"StartIndex":0,"Items":[{"Id":"x"},{"Id":"y"}]}"""
        assertEquals(listOf(mapOf("Id" to "x"), mapOf("Id" to "y")), itemFields(json))
    }

    @Test
    fun parsesEmptyArrayAndEmptyEnvelope() {
        assertTrue(itemFields("[]").isEmpty())
        assertTrue(itemFields("""{"Items":[]}""").isEmpty())
    }

    @Test
    fun nestedObjectsInsideItemsDoNotEmitTwice() {
        val fields = itemFields("""[{"Id":"a","UserData":{"Played":true}}]""")
        assertEquals(listOf(mapOf("Id" to "a")), fields)
    }

    @Test
    fun scalarTypesRoundTripThroughStrings() {
        val fields = itemFields(
            """[{"S":"text","I":42,"N":-7,"F":1.5,"E":1e3,"T":true,"F2":false,"Null":null}]""",
        )
        assertEquals(
            mapOf("S" to "text", "I" to "42", "N" to "-7", "F" to "1.5", "E" to "1e3", "T" to "true", "F2" to "false"),
            fields.single(),
        )
    }

    @Test
    fun escapeSequencesDecodeInObjectValues() {
        // JSON wire text: [{"v":"A\\\/line\n\ttab\f q"}] — every backslash literal.
        val fields = itemFields("[{\"v\":\"A\\\\\\/line\\n\\ttab\\u000Cq\"}]")
        assertEquals("A\\/line\n\ttab\u000Cq", fields.single()["v"])
    }

    @Test
    fun unicodeEscapeDecodes() {
        val fields = itemFields("[{\"v\":\"\\u00e9\\u4e2d\"}]")
        assertEquals("é中", fields.single()["v"])
    }

    @Test
    fun parseObjectsWithPathsEmitsNestedObjectsWithArrayIndexPaths() {
        val json = """{"MediaSources":[{"Id":"src1","MediaStreams":[{"Index":0,"Type":"Subtitle"}]}]}"""
        val paths = mutableListOf<Pair<List<String>, Map<String, String>>>()
        JsonObjectReader(
            source = json,
            onObjectAtPath = { path, fields -> paths += path to fields },
        ).parseObjectsWithPaths()

        assertTrue(paths.contains(listOf("MediaSources", "0") to mapOf("Id" to "src1")))
        assertTrue(
            paths.contains(
                listOf("MediaSources", "0", "MediaStreams", "0") to mapOf("Index" to "0", "Type" to "Subtitle"),
            ),
        )
    }

    @Test
    fun trailingContentIsRejected() {
        assertFailsWith<IllegalStateException> { itemFields("""[{"Id":"a"}] oops""") }
        assertFailsWith<IllegalStateException> { itemFields("""[{"Id":"a"}][]""") }
    }

    @Test
    fun nonCollectionTopLevelIsRejected() {
        assertFailsWith<IllegalStateException> { itemFields("42") }
        assertFailsWith<IllegalStateException> { itemFields("\"just a string\"") }
    }

    @Test
    fun malformedInputsAreRejected() {
        assertFailsWith<IllegalStateException> { itemFields("""[{"Id":}]""") }
        assertFailsWith<IllegalStateException> { itemFields("""[{"Id":"unterminated]""") }
        assertFailsWith<IllegalStateException> { itemFields("""[{"Id":"a",}]""") }
        assertFailsWith<IllegalStateException> { itemFields("[tru]") }
        assertFailsWith<IllegalStateException> { itemFields("[01x]") }
        assertFailsWith<IllegalStateException> { itemFields("""[{"a" "b"}]""") }
    }

    @Test
    fun unescapedControlCharacterInStringIsRejected() {
        assertFailsWith<IllegalStateException> { itemFields("[{\"a\":\"\u0001\"}]") }
    }

    @Test
    fun incompleteUnicodeEscapeIsRejected() {
        assertFailsWith<IllegalStateException> { itemFields("[{\"a\":\"\\u00\"}]") }
    }
}

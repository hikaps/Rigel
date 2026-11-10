@file:OptIn(
    kotlinx.cinterop.BetaInteropApi::class,
    kotlinx.cinterop.ExperimentalForeignApi::class,
)

package app.rigel.settings

import com.russhwolf.settings.Settings
import kotlinx.cinterop.MemScope
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArrayOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.value
import platform.CoreFoundation.CFDictionaryCreate
import platform.CoreFoundation.CFDictionaryRef
import platform.CoreFoundation.CFStringRef
import platform.CoreFoundation.CFTypeRef
import platform.CoreFoundation.CFTypeRefVar
import platform.CoreFoundation.kCFAllocatorDefault
import platform.CoreFoundation.kCFBooleanTrue
import platform.Foundation.CFBridgingRelease
import platform.Foundation.CFBridgingRetain
import platform.Foundation.NSData
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.create
import platform.Foundation.dataUsingEncoding
import platform.Security.SecItemAdd
import platform.Security.SecItemCopyMatching
import platform.Security.SecItemDelete
import platform.Security.SecItemUpdate
import platform.Security.errSecItemNotFound
import platform.Security.errSecSuccess
import platform.Security.kSecAttrAccessible
import platform.Security.kSecAttrAccessibleWhenUnlockedThisDeviceOnly
import platform.Security.kSecAttrAccount
import platform.Security.kSecAttrService
import platform.Security.kSecClass
import platform.Security.kSecClassGenericPassword
import platform.Security.kSecMatchLimit
import platform.Security.kSecMatchLimitOne
import platform.Security.kSecReturnData
import platform.Security.kSecValueData
import platform.darwin.OSStatus

private class IosJellyfinTokenStore : JellyfinTokenStore {
    override val persistsAcrossInstances = true
    private val service = "com.rigel.player.jellyfin"
    private val account = "token"

    override fun read(): String? = memScoped {
        val result = alloc<CFTypeRefVar>()
        val status = withQuery(returnData = true) { query ->
            SecItemCopyMatching(query, result.ptr)
        }
        if (status != errSecSuccess) {
            reportStatus("read", status, expected = errSecItemNotFound)
            return@memScoped null
        }

        val value = result.value
        if (value == null) {
            println("Jellyfin Keychain read failed (OSStatus=0, missing result)")
            return@memScoped null
        }
        // SecItemCopyMatching transfers a +1 result to the caller. The
        // bridging release consumes that ownership after NSData is decoded.
        decodeData(value)
    }

    override fun write(value: String): Boolean {
        if (value.isEmpty()) return false
        val data = value.toNSString().dataUsingEncoding(NSUTF8StringEncoding)
            ?: return false

        return withRetained(data) { retainedData ->
            val updateStatus = withQuery(returnData = false) { query ->
                withDictionary(kSecValueData to retainedData) { attributes ->
                    SecItemUpdate(query, attributes)
                }
            }
            if (updateStatus == errSecSuccess) return@withRetained true
            if (updateStatus != errSecItemNotFound) {
                reportStatus("update", updateStatus)
                return@withRetained false
            }

            val addStatus = addItem(retainedData)
            if (addStatus != errSecSuccess) reportStatus("add", addStatus)
            addStatus == errSecSuccess
        }
    }

    override fun clear(): Boolean {
        val status = withQuery(returnData = false) { query ->
            SecItemDelete(query)
        }
        reportStatus("delete", status, expected = errSecItemNotFound)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private inline fun <T> withQuery(
        returnData: Boolean,
        block: (CFDictionaryRef?) -> T,
    ): T = withRetained(service) { serviceRef ->
        withRetained(account) { accountRef ->
            memScoped {
                val query = if (returnData) {
                    cfDictionaryOf(
                        kSecClass to kSecClassGenericPassword,
                        kSecAttrService to serviceRef,
                        kSecAttrAccount to accountRef,
                        kSecReturnData to kCFBooleanTrue,
                        kSecMatchLimit to kSecMatchLimitOne,
                    )
                } else {
                    cfDictionaryOf(
                        kSecClass to kSecClassGenericPassword,
                        kSecAttrService to serviceRef,
                        kSecAttrAccount to accountRef,
                    )
                }
                try {
                    block(query)
                } finally {
                    // The dictionary is created at +1. Its null callbacks
                    // match the library's proven bridge: retained values stay
                    // alive in the surrounding scopes until the API returns.
                    CFBridgingRelease(query)
                }
            }
        }
    }

    private inline fun <T> withDictionary(
        vararg values: Pair<CFStringRef?, CFTypeRef?>,
        block: (CFDictionaryRef?) -> T,
    ): T = memScoped {
        val dictionary = cfDictionaryOf(*values)
        try {
            block(dictionary)
        } finally {
            CFBridgingRelease(dictionary)
        }
    }

    private fun addItem(value: CFTypeRef?): OSStatus = withRetained(service) { serviceRef ->
        withRetained(account) { accountRef ->
            memScoped {
                val item = cfDictionaryOf(
                    kSecClass to kSecClassGenericPassword,
                    kSecAttrService to serviceRef,
                    kSecAttrAccount to accountRef,
                    kSecValueData to value,
                    kSecAttrAccessible to kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                )
                try {
                    SecItemAdd(item, null)
                } finally {
                    CFBridgingRelease(item)
                }
            }
        }
    }

    private inline fun <T> withRetained(value: Any?, block: (CFTypeRef?) -> T): T = memScoped {
        val retained = CFBridgingRetain(value)
        try {
            block(retained)
        } finally {
            CFBridgingRelease(retained)
        }
    }

    private fun reportStatus(operation: String, status: OSStatus, expected: OSStatus? = null) {
        if (status != errSecSuccess && status != expected) {
            println("Jellyfin Keychain $operation failed (OSStatus=$status)")
        }
    }

    private fun decodeData(value: CFTypeRef): String? =
        (CFBridgingRelease(value) as? NSData)
            ?.let { NSString.create(it, NSUTF8StringEncoding)?.toKString() }

    @Suppress("CAST_NEVER_SUCCEEDS")
    private fun String.toNSString() = this as NSString

    @Suppress("CAST_NEVER_SUCCEEDS")
    private fun NSString.toKString() = this as String

    private fun MemScope.cfDictionaryOf(
        vararg items: Pair<CFStringRef?, CFTypeRef?>,
    ): CFDictionaryRef? {
        val keys = allocArrayOf(*items.map { it.first }.toTypedArray())
        val values = allocArrayOf(*items.map { it.second }.toTypedArray())
        return CFDictionaryCreate(
            kCFAllocatorDefault,
            keys.reinterpret(),
            values.reinterpret(),
            items.size.convert(),
            null,
            null,
        )
    }
}

internal actual fun createPlatformJellyfinTokenStore(): JellyfinTokenStore =
    IosJellyfinTokenStore()

internal actual fun createPlatformSettingsStore(): SettingsStore =
    SettingsStore(Settings(), createPlatformJellyfinTokenStore())

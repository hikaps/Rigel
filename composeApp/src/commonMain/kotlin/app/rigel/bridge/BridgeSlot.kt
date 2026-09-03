package app.rigel.bridge

/**
 * One mutable registration slot for a native bridge. Swift registers concrete
 * implementations at app startup; Kotlin only reads. Tests register fakes and
 * must reset them in teardown — a missing registration fails explicitly.
 */
class BridgeSlot<T : Any> {
    private var impl: T? = null

    fun register(bridge: T?) {
        impl = bridge
    }

    val current: T? get() = impl

    val isRegistered: Boolean get() = impl != null
}

package local.simhub.phone

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge between Flutter's PhoneCore and the process-wide SIP core owned by
 * [PhoneCallService]. Destroying the Flutter activity hides the UI but does not
 * stop SIP registration, the call or the audio path.
 */
class PhoneCoreBridge(
    engine: FlutterEngine,
    private val onScanQrRequested: ((Boolean, MethodChannel.Result) -> Unit)? = null,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methods =
        MethodChannel(engine.dartExecutor.binaryMessenger, "simhub.phone/core")
    private val events =
        EventChannel(engine.dartExecutor.binaryMessenger, "simhub.phone/events")
    private var eventSink: EventChannel.EventSink? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        PhoneRuntime.bridge = this
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initialize" -> {
                    val args = call.arguments as? Map<*, *>
                        ?: throw IllegalArgumentException("initialize requires a map")
                    PhoneRuntime.pendingConfig = args
                    ensureCore().initialize(args)
                    PhoneCallService.startCore(requireContext())
                    replayState()
                    result.success(null)
                }
                "loadAccounts" -> {
                    val ctx = requireContext()
                    val stored = PhoneAccountStore.loadAll(ctx)
                    val core = ensureCore()
                    if (stored.isNotEmpty()) {
                        core.syncAccounts(stored, registerNow = false)
                        PhoneCallService.startCore(ctx)
                    }
                    result.success(core.accountsPayload())
                }
                "upsertAccounts" -> {
                    val ctx = requireContext()
                    @Suppress("UNCHECKED_CAST")
                    val rawAccounts = (call.argument<List<*>>("accounts") ?: emptyList<Any>())
                        .filterIsInstance<Map<*, *>>()
                    val registerNow = call.argument<Boolean>("register_now") != false
                    val stored = PhoneAccountStore.upsert(ctx, rawAccounts)
                    val core = ensureCore()
                    core.syncAccounts(stored, registerNow = registerNow)
                    if (stored.any { it.enabled }) {
                        PhoneCallService.startCore(ctx)
                    }
                    result.success(null)
                }
                "updateAccountMeta" -> {
                    val ctx = requireContext()
                    val key = call.argument<String>("account_key").orEmpty()
                    val label = call.argument<String>("label")
                    val group = call.argument<String>("group")
                    val stored = PhoneAccountStore.updateMeta(ctx, key, label, group)
                    ensureCore().syncAccounts(stored, registerNow = false)
                    result.success(null)
                }
                "setAccountEnabled" -> {
                    val ctx = requireContext()
                    val key = call.argument<String>("account_key").orEmpty()
                    val enabled = call.argument<Boolean>("enabled") == true
                    val stored = PhoneAccountStore.setEnabled(ctx, key, enabled)
                    ensureCore().syncAccounts(stored, registerNow = enabled)
                    result.success(null)
                }
                "removeAccount" -> {
                    val ctx = requireContext()
                    val key = call.argument<String>("account_key").orEmpty()
                    val stored = PhoneAccountStore.remove(ctx, key)
                    ensureCore().syncAccounts(stored, registerNow = false)
                    result.success(null)
                }
                "selectDefaultAccount" -> {
                    val ctx = requireContext()
                    val key = call.argument<String>("account_key").orEmpty()
                    val stored = PhoneAccountStore.selectDefault(ctx, key)
                    ensureCore().syncAccounts(stored, registerNow = false)
                    result.success(null)
                }
                "register" -> {
                    val ctx = requireContext()
                    val stored = PhoneAccountStore.loadAll(ctx)
                    val core = ensureCore()
                    if (stored.isNotEmpty()) {
                        core.syncAccounts(stored, registerNow = true)
                        PhoneCallService.startCore(ctx)
                    }
                    core.registerAll()
                    result.success(null)
                }
                "unregister" -> {
                    PhoneRuntime.core?.unregisterAll()
                    result.success(null)
                }
                "dial" -> {
                    val number = call.argument<String>("number").orEmpty()
                    val accountKey = call.argument<String>("account_key")
                    if (!SimHubConnectionService.place(requireContext(), number, accountKey)) {
                        requireCore().dial(number, accountKey)
                    }
                    result.success(null)
                }
                "answer" -> {
                    requireCore().answer(call.argument<String>("call_id").orEmpty())
                    result.success(null)
                }
                "hangup" -> {
                    requireCore().hangup(call.argument<String>("call_id"))
                    result.success(null)
                }
                "setMute" -> {
                    requireCore().setMute(call.argument<Boolean>("muted") == true)
                    result.success(null)
                }
                "setHold" -> {
                    requireCore().setHold(call.argument<Boolean>("held") == true)
                    result.success(null)
                }
                "setAudioRoute" -> {
                    val route = call.argument<String>("route").orEmpty()
                    requireCore().setAudioRoute(route)
                    PhoneCallService.setSpeaker(requireContext(), route == "speaker")
                    PhoneRuntime.telecomConnection?.setSpeaker(route == "speaker")
                    result.success(null)
                }
                "sendDtmf" -> {
                    requireCore().sendDtmf(call.argument<String>("digit").orEmpty())
                    result.success(null)
                }
                "scanQrCode" -> {
                    val scanner = onScanQrRequested
                    if (scanner != null) {
                        scanner(false, result)
                    } else {
                        result.success(null)
                    }
                }
                "scanQrCodes" -> {
                    val scanner = onScanQrRequested
                    if (scanner != null) {
                        scanner(true, result)
                    } else {
                        result.success(emptyList<String>())
                    }
                }
                "loadHistory" -> {
                    result.success(historyPrefs().getString("call_history", "[]"))
                }
                "saveHistory" -> {
                    val json = call.argument<String>("json").orEmpty()
                    historyPrefs().edit().putString("call_history", json).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            Log.e("PhoneCoreBridge", "${call.method} failed: ${error.message}")
            result.error("PJSIP_ERROR", error.message ?: "native core error", null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        replayState()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        if (PhoneRuntime.bridge === this) PhoneRuntime.bridge = null
    }

    internal fun emitFromService(event: Map<String, Any?>) {
        try {
            eventSink?.success(event)
        } catch (error: Exception) {
            Log.e("PhoneCoreBridge", "event delivery failed", error)
        }
    }

    internal val hasListener: Boolean
        get() = eventSink != null

    private fun replayState() {
        PhoneRuntime.lastAccounts?.let { emitFromService(it) }
        PhoneRuntime.lastRegistration?.let { emitFromService(it) }
        PhoneRuntime.lastCall?.let { emitFromService(it) }
    }

    private fun ensureCore(): PjsipCore {
        val existing = PhoneRuntime.core
        if (existing != null) return existing
        val created = PjsipCore(PhoneRuntime::onCoreEvent)
        PhoneRuntime.core = created
        return created
    }

    private fun requireCore(): PjsipCore =
        PhoneRuntime.core ?: throw IllegalStateException("PJSIP core is not initialized")

    private fun requireContext(): Context =
        PhoneRuntime.context ?: throw IllegalStateException("application context is not set")

    private fun historyPrefs() =
        requireContext().getSharedPreferences("simhub_phone", Context.MODE_PRIVATE)
}

package local.simhub.phone

import android.content.Context

/**
 * Process-wide state shared by the Flutter bridge, the SIP core and the call
 * service. The service owns [core], so destroying the Flutter activity does
 * not stop SIP registration or an active call.
 */
internal object PhoneRuntime {
    var context: Context? = null
    var bridge: PhoneCoreBridge? = null
    var core: PjsipCore? = null
    var pendingConfig: Map<*, *>? = null
    var lastRegistration: Map<String, Any?>? = null
    var lastAccounts: Map<String, Any?>? = null
    var lastCall: Map<String, Any?>? = null
    var telecomConnection: SimHubConnection? = null
    var telecomCallId: String? = null

    fun onCoreEvent(event: Map<String, Any?>) {
        when (event["type"]) {
            "registration" -> lastRegistration = event
            "accounts" -> lastAccounts = event
            "call" -> {
                val call = event["call"] as? Map<*, *>
                if (call == null) {
                    val ended = lastCall?.get("call") as? Map<*, *>
                    if (ended != null) PhoneCallService.recordEndedCall(ended, event)
                }
                lastCall = event
            }
        }
        PhoneCallService.onCoreEvent(event)
        bridge?.emitFromService(event)
    }
}

package local.simhub.phone

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log

/**
 * Self-managed ConnectionService. Telecom uses it to treat the SIP call as a
 * real call for audio routing, audio focus, Bluetooth and call state. The app
 * keeps its own notification/UI because self-managed accounts do not use the
 * system dialer UI.
 */
class SimHubConnectionService : ConnectionService() {
    companion object {
        private const val TAG = "SimHubTelecom"
        private const val ACCOUNT_ID = "simhub-phone"
        private const val EXTRA_CALL_ID = "simhub.call_id"
        private const val EXTRA_NUMBER = "simhub.number"
        private const val EXTRA_ACCOUNT_KEY = "simhub.account_key"

        fun accountHandle(context: Context): PhoneAccountHandle =
            PhoneAccountHandle(
                ComponentName(context, SimHubConnectionService::class.java),
                ACCOUNT_ID,
            )

        fun ensureRegistered(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val account = PhoneAccount.builder(accountHandle(context), "SimHub Phone")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .setSupportedUriSchemes(listOf("tel"))
                .build()
            try {
                telecom.registerPhoneAccount(account)
            } catch (error: Exception) {
                Log.e(TAG, "registerPhoneAccount failed", error)
            }
        }

        fun reportIncoming(context: Context, callId: String, peer: String) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return
            val address = Uri.fromParts("tel", peer.ifBlank { "unknown" }, null)
            val extras = Bundle().apply {
                putString(EXTRA_CALL_ID, callId)
                putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, address)
            }
            try {
                telecom.addNewIncomingCall(accountHandle(context), extras)
                Log.i(TAG, "reported incoming call to telecom")
            } catch (error: Exception) {
                Log.e(TAG, "addNewIncomingCall failed", error)
            }
        }

        fun place(context: Context, number: String, accountKey: String? = null): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
            val telecom = context.getSystemService(TelecomManager::class.java) ?: return false
            val callExtras = Bundle().apply {
                putString(EXTRA_NUMBER, number)
                if (!accountKey.isNullOrBlank()) {
                    putString(EXTRA_ACCOUNT_KEY, accountKey)
                }
            }
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, accountHandle(context))
                putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, callExtras)
            }
            return try {
                telecom.placeCall(Uri.fromParts("tel", number, null), extras)
                Log.i(TAG, "placed outgoing call through telecom")
                true
            } catch (error: Exception) {
                Log.e(TAG, "placeCall failed", error)
                false
            }
        }
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val callId = request.extras?.getString(EXTRA_CALL_ID).orEmpty()
        val connection = SimHubConnection(callId, request.address, incoming = true)
        PhoneRuntime.telecomConnection = connection
        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ) {
        PhoneRuntime.telecomConnection = null
        Log.e(TAG, "incoming connection failed")
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection? {
        val number = request.address?.schemeSpecificPart
            ?: request.extras?.getString(EXTRA_NUMBER).orEmpty()
        val accountKey = request.extras?.getString(EXTRA_ACCOUNT_KEY)
        if (number.isBlank()) {
            Log.e(TAG, "outgoing connection without destination")
            return null
        }
        val connection = SimHubConnection("", request.address, incoming = false)
        PhoneRuntime.telecomConnection = connection
        PhoneRuntime.telecomCallId = null
        connection.dial(number, accountKey)
        return connection
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ) {
        Log.e(TAG, "outgoing connection failed")
    }
}

class SimHubConnection(
    private val callId: String,
    address: Uri?,
    private val incoming: Boolean,
) : Connection() {
    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setConnectionProperties(PROPERTY_SELF_MANAGED)
        }
        setConnectionCapabilities(CAPABILITY_MUTE)
        setAudioModeIsVoip(true)
        if (address != null) {
            setAddress(address, TelecomManager.PRESENTATION_ALLOWED)
            setCallerDisplayName(address.schemeSpecificPart, TelecomManager.PRESENTATION_ALLOWED)
        }
        if (incoming) setRinging() else setDialing()
    }

    fun dial(number: String, accountKey: String? = null) {
        try {
            PhoneRuntime.core?.dial(number, accountKey)
        } catch (error: Exception) {
            Log.e("SimHubTelecom", "outgoing dial failed", error)
            markEnded()
            PhoneRuntime.onCoreEvent(mapOf("type" to "call", "call" to null, "reason" to error.message))
        }
    }

    override fun onAnswer() {
        if (callId.isNotBlank()) {
            PhoneRuntime.core?.answer(callId)
            setActive()
        }
    }

    override fun onReject() {
        hangup()
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
    }

    override fun onDisconnect() {
        hangup()
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
    }

    override fun onAbort() {
        hangup()
        setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
        destroy()
    }

    private fun hangup() {
        PhoneRuntime.core?.hangup(callId.takeIf { it.isNotBlank() })
    }

    fun markActive() {
        if (state != STATE_ACTIVE) setActive()
    }

    fun isSystemSpeakerActive(): Boolean =
        callAudioState?.route == CallAudioState.ROUTE_SPEAKER

    override fun onCallAudioStateChanged(state: CallAudioState?) {
        super.onCallAudioStateChanged(state)
        val audioState = state ?: return
        val routeName = when (audioState.route) {
            CallAudioState.ROUTE_SPEAKER -> "speaker"
            CallAudioState.ROUTE_BLUETOOTH -> "bluetooth"
            else -> "earpiece"
        }
        Log.i("SimHubTelecom", "onCallAudioStateChanged route=$routeName")
        val core = PhoneRuntime.core ?: return
        if (core.hasPendingUserSpeakerOverride() && audioState.route == CallAudioState.ROUTE_EARPIECE) {
            setSpeaker(true)
            return
        }
        if (audioState.route == CallAudioState.ROUTE_SPEAKER) {
            core.clearPendingUserSpeakerOverride()
        }
        core.syncHardwareAudioRoute(routeName)
    }

    fun setSpeaker(on: Boolean) {
        setAudioRoute(if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_EARPIECE)
    }

    fun markEnded() {
        if (state == STATE_DISCONNECTED) return
        setDisconnected(DisconnectCause(DisconnectCause.REMOTE))
        destroy()
    }
}

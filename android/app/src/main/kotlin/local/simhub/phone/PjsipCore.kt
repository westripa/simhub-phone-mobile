package local.simhub.phone

import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import org.pjsip.pjsua2.Account
import org.pjsip.pjsua2.AccountConfig
import org.pjsip.pjsua2.AuthCredInfo
import org.pjsip.pjsua2.Call
import org.pjsip.pjsua2.CallInfo
import org.pjsip.pjsua2.CallOpParam
import org.pjsip.pjsua2.Endpoint
import org.pjsip.pjsua2.EpConfig
import org.pjsip.pjsua2.OnCallMediaStateParam
import org.pjsip.pjsua2.OnCallStateParam
import org.pjsip.pjsua2.OnCallTsxStateParam
import org.pjsip.pjsua2.OnIncomingCallParam
import org.pjsip.pjsua2.OnRegStateParam
import org.pjsip.pjsua2.SipEvent
import org.pjsip.pjsua2.SipHeader
import org.pjsip.pjsua2.SipHeaderVector
import org.pjsip.pjsua2.TlsConfig
import org.pjsip.pjsua2.TransportConfig
import org.pjsip.pjsua2.LogEntry
import org.pjsip.pjsua2.LogWriter
import org.pjsip.pjsua2.pjmedia_srtp_use
import org.pjsip.pjsua2.pjmedia_type
import org.pjsip.pjsua2.pjsip_cred_data_type
import org.pjsip.pjsua2.pjsip_inv_state
import org.pjsip.pjsua2.pjsip_status_code
import org.pjsip.pjsua2.pjsip_transport_type_e
import org.pjsip.pjsua2.pjsua_call_flag
import org.pjsip.pjsua2.pjsua_call_media_status
import java.security.KeyStore
import java.time.Instant
import java.util.UUID
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

private class AndroidLogWriter : LogWriter() {
    override fun write(entry: LogEntry) {
        Log.i("PJSIP", entry.msg.trimEnd())
    }
}

private data class ManagedAccount(
    val stored: StoredSipAccount,
    val signature: String,
    val account: PjsipAccount,
)

/**
 * Multi-account PJSIP endpoint owned by [PhoneCallService].
 *
 * Supports Digest HA1 credentials, UDP/TCP/TLS signaling, SDES-SRTP,
 * hold/unhold, DTMF, single-call microphone exclusivity, and custom SimHub
 * incoming headers (`X-SimHub-Own-Number`, `X-SimHub-Transfer*`).
 */
class PjsipCore(private val emitEvent: (Map<String, Any?>) -> Unit) {
    companion object {
        private const val MAX_LIVE_PJSIP_ACCOUNTS = 128
        private const val REGISTER_WAVE_BATCH_SIZE = 4
        private const val REGISTER_WAVE_INTERVAL_MS = 60L
    }

    private val main = Handler(Looper.getMainLooper())
    private val logWriter = AndroidLogWriter()

    private var endpoint: Endpoint? = null
    private var endpointVerifyServer = true
    private var endpointNullAudio = false

    private val storedOrder = mutableListOf<StoredSipAccount>()
    private val managedAccounts = LinkedHashMap<String, ManagedAccount>()
    private val regStates = LinkedHashMap<String, String>()
    private val regReasons = LinkedHashMap<String, String?>()
    private val capacityBlockedAccountKeys = mutableSetOf<String>()
    private var regWaveGen = 0

    private val callLock = Any()
    private var activeCall: PjsipCall? = null
    private var muted = false
    private var speakerOn = false
    private var pendingSpeakerApply = false

    private var retryAttempt = 0
    private var retryScheduled = false
    private val retryDelaysMs = longArrayOf(5_000L, 10_000L, 20_000L, 30_000L, 60_000L)
    private val retryRunnable = Runnable {
        retryScheduled = false
        ensureRegistered(fromTimer = true)
    }

    fun isSpeakerOn(): Boolean = speakerOn

    fun hasPendingUserSpeakerOverride(): Boolean = pendingSpeakerApply

    fun clearPendingUserSpeakerOverride() {
        pendingSpeakerApply = false
    }

    fun initialize(values: Map<*, *>) {
        val nullAudio = values["null_audio"] == true
        val allowSelfSigned = values["allow_self_signed_tls"] == true
        ensureEndpoint(nullAudio = nullAudio, allowSelfSignedTls = allowSelfSigned)
        emit(mapOf("type" to "registration", "state" to "unregistered"))
    }

    fun syncAccounts(accounts: List<StoredSipAccount>, registerNow: Boolean) {
        storedOrder.clear()
        storedOrder.addAll(accounts)

        val anySelfSigned = accounts.any { it.enabled && it.allowSelfSignedTls }
        val anyNullAudio = accounts.any { it.enabled && it.nullAudio }
        val needActiveEndpoint = accounts.any { it.enabled && it.hasCredential }

        if (needActiveEndpoint) {
            if (endpoint != null &&
                synchronized(callLock) { activeCall == null } &&
                (endpointVerifyServer != !anySelfSigned || endpointNullAudio != anyNullAudio)
            ) {
                shutdownEndpointOnly()
            }
            ensureEndpoint(nullAudio = anyNullAudio, allowSelfSignedTls = anySelfSigned)
        }

        val desiredByKey = accounts.associateBy { it.accountKey }
        val enabledBySipKey = LinkedHashMap<String, MutableList<StoredSipAccount>>()
        for (acc in accounts) {
            if (acc.enabled && acc.hasCredential) {
                enabledBySipKey.getOrPut(acc.sipTransportKey()) { mutableListOf() }.add(acc)
            }
        }

        // Tear down transport accounts removed, disabled, or changed in connection signature.
        val keysToRemove = managedAccounts.keys.filter { sipKey ->
            val group = enabledBySipKey[sipKey]
            group == null || managedAccounts[sipKey]?.signature != group.first().configSignature()
        }
        for (sipKey in keysToRemove) {
            val existing = managedAccounts.remove(sipKey) ?: continue
            destroyAccount(existing.account)
        }

        // Clean stale per-UI-account states for deleted accounts.
        regStates.keys.retainAll(desiredByKey.keys)
        regReasons.keys.retainAll(desiredByKey.keys)
        capacityBlockedAccountKeys.retainAll(desiredByKey.keys)

        for (acc in accounts) {
            if (!acc.enabled || !acc.hasCredential || endpoint == null) {
                capacityBlockedAccountKeys.remove(acc.accountKey)
                regStates[acc.accountKey] = "unregistered"
                regReasons[acc.accountKey] = if (!acc.hasCredential && acc.enabled) "缺少凭据" else null
            }
        }

        val toRegisterKeys = mutableListOf<String>()
        if (endpoint != null) {
            for ((sipKey, group) in enabledBySipKey) {
                val representative = group.first()
                val existing = managedAccounts[sipKey]
                if (existing != null) {
                    managedAccounts[sipKey] = existing.copy(stored = representative)
                    val sharedState = group.mapNotNull { regStates[it.accountKey] }
                        .firstOrNull { it == "registered" || it == "registering" }
                        ?: group.mapNotNull { regStates[it.accountKey] }.firstOrNull()
                        ?: "unregistered"
                    val sharedReason = if (sharedState == "failed") {
                        group.mapNotNull { regReasons[it.accountKey] }.firstOrNull()
                    } else {
                        null
                    }
                    for (member in group) {
                        capacityBlockedAccountKeys.remove(member.accountKey)
                        regStates[member.accountKey] = sharedState
                        regReasons[member.accountKey] = sharedReason
                    }
                    if (registerNow && sharedState != "registered" && sharedState != "registering") {
                        toRegisterKeys.add(sipKey)
                    }
                    continue
                }
                if (createManagedAccount(sipKey, representative, group) && registerNow) {
                    toRegisterKeys.add(sipKey)
                }
            }
        }

        if (toRegisterKeys.isNotEmpty()) {
            scheduleRegisterWave(toRegisterKeys)
        }

        emitAccountsSnapshot()
        emitAggregateRegistration()
    }

    internal fun ensurePjThread(name: String = "android") {
        val ep = endpoint ?: return
        runCatching {
            if (!ep.libIsThreadRegistered()) {
                ep.libRegisterThread(name)
            }
        }
    }

    private fun destroyAccount(acc: PjsipAccount) {
        ensurePjThread("main")
        runCatching { acc.setRegistration(false) }
        runCatching { acc.shutdown() }
        runCatching { acc.delete() }
    }

    fun registerAll() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { registerAll() }
            return
        }
        ensurePjThread("main")
        main.removeCallbacks(retryRunnable)
        retryScheduled = false
        retryAttempt = 0
        val enabledBySipKey = LinkedHashMap<String, MutableList<StoredSipAccount>>()
        for (acc in storedOrder) {
            if (acc.enabled && acc.hasCredential) {
                enabledBySipKey.getOrPut(acc.sipTransportKey()) { mutableListOf() }.add(acc)
            }
        }
        val toRegisterKeys = mutableListOf<String>()
        for ((sipKey, group) in enabledBySipKey) {
            val managed = managedAccounts[sipKey]
            if (managed == null) {
                if (createManagedAccount(sipKey, group.first(), group)) {
                    toRegisterKeys.add(sipKey)
                }
            } else {
                val alreadyInFlight = group.all { regStates[it.accountKey] == "registering" }
                if (!alreadyInFlight) {
                    toRegisterKeys.add(sipKey)
                }
            }
        }
        if (toRegisterKeys.isNotEmpty()) {
            scheduleRegisterWave(toRegisterKeys)
        }
        emitAccountsSnapshot()
        emitAggregateRegistration()
    }

    fun ensureRegistered(fromTimer: Boolean = false) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { ensureRegistered(fromTimer) }
            return
        }
        ensurePjThread("main")
        if (!fromTimer) {
            main.removeCallbacks(retryRunnable)
            retryScheduled = false
            retryAttempt = 0
        }
        if (storedOrder.isEmpty()) return
        val snapshot = storedOrder.toList()
        val anySelfSigned = snapshot.any { it.enabled && it.allowSelfSignedTls }
        val anyNullAudio = snapshot.any { it.enabled && it.nullAudio }
        val needActiveEndpoint = snapshot.any { it.enabled && it.hasCredential }
        if (needActiveEndpoint && endpoint == null) {
            ensureEndpoint(nullAudio = anyNullAudio, allowSelfSignedTls = anySelfSigned)
        }
        val enabledBySipKey = LinkedHashMap<String, MutableList<StoredSipAccount>>()
        for (acc in snapshot) {
            if (acc.enabled && acc.hasCredential) {
                enabledBySipKey.getOrPut(acc.sipTransportKey()) { mutableListOf() }.add(acc)
            }
        }
        var changed = false
        val toRegisterKeys = mutableListOf<String>()
        for ((sipKey, group) in enabledBySipKey) {
            val allActiveOrInFlight = group.all {
                val s = regStates[it.accountKey]
                s == "registered" || s == "registering"
            }
            if (allActiveOrInFlight) continue
            val managed = managedAccounts[sipKey]
            if (managed == null) {
                if (createManagedAccount(sipKey, group.first(), group)) {
                    toRegisterKeys.add(sipKey)
                }
                changed = true
            } else {
                toRegisterKeys.add(sipKey)
                changed = true
            }
        }
        if (toRegisterKeys.isNotEmpty()) {
            scheduleRegisterWave(toRegisterKeys)
        }
        if (changed) {
            emitAccountsSnapshot()
            emitAggregateRegistration()
        }
        if (hasRetryableUnregisteredAccounts(snapshot)) {
            scheduleRetryIfNeeded()
        }
    }

    private fun hasRetryableUnregisteredAccounts(list: List<StoredSipAccount> = storedOrder): Boolean =
        list.any {
            it.enabled &&
                it.hasCredential &&
                !capacityBlockedAccountKeys.contains(it.accountKey) &&
                regStates[it.accountKey] != "registered"
        }

    private fun scheduleRegisterWave(sipKeys: List<String>) {
        val uniqueKeys = sipKeys.distinct().filter { managedAccounts.containsKey(it) }
        val gen = ++regWaveGen
        if (uniqueKeys.isEmpty()) return
        for (sipKey in uniqueKeys) {
            for (acc in storedOrder) {
                if (acc.enabled && acc.hasCredential && acc.sipTransportKey() == sipKey &&
                    regStates[acc.accountKey] != "registered"
                ) {
                    regStates[acc.accountKey] = "registering"
                    regReasons[acc.accountKey] = null
                }
            }
        }
        val batches = uniqueKeys.chunked(REGISTER_WAVE_BATCH_SIZE)
        for ((batchIdx, batch) in batches.withIndex()) {
            main.postDelayed({
                if (gen != regWaveGen || endpoint == null) return@postDelayed
                ensurePjThread("main")
                var snapshotChanged = false
                for (sipKey in batch) {
                    val managed = managedAccounts[sipKey] ?: continue
                    runCatching {
                        managed.account.setRegistration(true)
                    }.onFailure { err ->
                        val msg = err.message.orEmpty()
                        if (msg.contains("PJSIP_EBUSY") || msg.contains("171001")) {
                            Log.i("PjsipCore", "registration already in flight for account=${maskId(sipKey)}")
                        } else {
                            managedAccounts.remove(sipKey)
                            destroyAccount(managed.account)
                            val group = storedOrder.filter {
                                it.enabled && it.hasCredential && it.sipTransportKey() == sipKey
                            }
                            if (group.isNotEmpty() && createManagedAccount(sipKey, group.first(), group)) {
                                runCatching { managedAccounts[sipKey]?.account?.setRegistration(true) }
                                    .onFailure { retryErr ->
                                        for (m in group) {
                                            regStates[m.accountKey] = "failed"
                                            regReasons[m.accountKey] = retryErr.message ?: msg
                                        }
                                    }
                            } else {
                                for (m in group) {
                                    regStates[m.accountKey] = "failed"
                                    regReasons[m.accountKey] = msg.ifBlank { "账号注册失败" }
                                }
                            }
                            snapshotChanged = true
                        }
                    }
                }
                if (snapshotChanged) {
                    emitAccountsSnapshot()
                    emitAggregateRegistration()
                }
            }, batchIdx * REGISTER_WAVE_INTERVAL_MS)
        }
    }

    private fun scheduleRetryIfNeeded() {
        if (!hasRetryableUnregisteredAccounts()) {
            main.removeCallbacks(retryRunnable)
            retryScheduled = false
            retryAttempt = 0
            return
        }
        if (retryScheduled) return
        val delay = retryDelaysMs[retryAttempt.coerceAtMost(retryDelaysMs.lastIndex)]
        retryAttempt++
        retryScheduled = true
        Log.i("PjsipCore", "scheduling SIP registration retry in ${delay}ms (attempt=$retryAttempt)")
        main.postDelayed(retryRunnable, delay)
    }

    fun unregisterAll() {
        ensurePjThread("main")
        regWaveGen++
        main.removeCallbacks(retryRunnable)
        retryScheduled = false
        retryAttempt = 0
        for ((_, managed) in managedAccounts) {
            runCatching { managed.account.setRegistration(false) }
        }
        for (acc in storedOrder) {
            regStates[acc.accountKey] = "unregistered"
            regReasons[acc.accountKey] = null
        }
        emitAccountsSnapshot()
        emitAggregateRegistration()
    }

    fun accountsPayload(): List<Map<String, Any?>> = storedOrder.map { acc ->
        acc.toFlutterMap(
            registrationState = regStates[acc.accountKey] ?: "unregistered",
            reason = regReasons[acc.accountKey],
        )
    }

    fun dial(number: String, accountKey: String? = null) {
        ensurePjThread("caller")
        synchronized(callLock) {
            if (activeCall != null) error("当前已有通话正在进行")
        }
        val (cfg, targetAccount) = selectDialAccount(accountKey)
            ?: error("没有可用的已注册 SIP 号码")
        val cleanTarget = number.trim()
        val destination = if (cleanTarget.startsWith("sip:")) {
            cleanTarget
        } else {
            "sip:$cleanTarget@${cfg.domain}"
        }
        Log.i(
            "PjsipCore",
            "dial target=${maskId(cleanTarget)} from=${maskId(cfg.displayNumber)}",
        )
        syncInitialCallAudioState()
        val call = PjsipCall(this, targetAccount.account, cfg.accountKey, -1, incoming = false).apply {
            peer = cleanTarget
            ownNumber = cfg.displayNumber
            lineLabel = cfg.label.ifBlank { cfg.displayNumber }
        }
        synchronized(callLock) {
            if (activeCall != null) error("当前已有通话正在进行")
            activeCall = call
        }
        val param = CallOpParam(true)
        if (cfg.multiplex && cfg.phoneNumber.isNotBlank()) {
            val fromHdr = SipHeader().apply {
                hName = "X-SimHub-From-Number"
                hValue = cfg.phoneNumber.trim()
            }
            val headers = param.txOption.headers ?: SipHeaderVector()
            headers.add(fromHdr)
            param.txOption.headers = headers
        }
        try {
            call.makeCall(destination, param)
        } catch (error: Exception) {
            Log.e("PjsipCore", "makeCall failed: ${error.message}")
            synchronized(callLock) {
                call.disconnected = true
                if (activeCall?.callUid == call.callUid) activeCall = null
            }
            resetCallAudioState()
            emit(
                mapOf(
                    "type" to "call",
                    "call" to null,
                    "reason" to error.message,
                    "local_hangup" to false,
                ),
            )
            runCatching { call.delete() }
            throw error
        }
        val snapshot = synchronized(callLock) {
            if (!call.disconnected && activeCall?.callUid == call.callUid) callEvent(call) else null
        }
        if (snapshot != null) emit(snapshot)
    }

    fun answer(callId: String) {
        ensurePjThread("caller")
        val call = synchronized(callLock) { activeCall } ?: return
        if (callId.isNotBlank() && call.callUid != callId) return
        val param = CallOpParam(true)
        param.statusCode = pjsip_status_code.PJSIP_SC_OK
        call.answer(param)
    }

    fun hangup(callId: String? = null) {
        ensurePjThread("caller")
        val call = synchronized(callLock) {
            val current = activeCall
            current?.localHangupRequested = true
            current
        }
        if (call == null) {
            // UI or Telecom out of sync: always emit null call so UI unsticks immediately.
            resetCallAudioState()
            emit(
                mapOf(
                    "type" to "call",
                    "call" to null,
                    "reason" to "Force hangup",
                    "local_hangup" to true,
                ),
            )
            return
        }
        val hungUpCleanly = runCatching {
            call.hangup(CallOpParam(true))
            true
        }.getOrElse { err ->
            Log.w("PjsipCore", "hangup force-clearing terminated/stale call: ${err.message}")
            false
        }
        if (!hungUpCleanly) {
            forceClearCall(call, reason = "Locally ended")
        } else {
            // Safety watchdog: if SIP CANCEL/BYE gets no DISCONNECTED callback within 1.5s,
            // force-clear local state so tapping Hangup always stops the call promptly.
            main.postDelayed({
                forceClearCall(call, reason = "Hangup timeout")
            }, 1500L)
        }
    }

    private fun forceClearCall(call: PjsipCall, code: Int? = null, reason: String? = null) {
        var localHangup = false
        var reasonsSnapshot: List<String> = emptyList()
        var hadRinging = false
        val cleared = synchronized(callLock) {
            if (call.disconnected) {
                if (activeCall?.callUid == call.callUid) activeCall = null
                false
            } else {
                call.disconnected = true
                if (activeCall?.callUid == call.callUid) activeCall = null
                localHangup = call.localHangupRequested
                reasonsSnapshot = call.sipReasons.toList()
                hadRinging = call.phase == "ringing"
                true
            }
        }
        if (!cleared) return
        if (reasonsSnapshot.isNotEmpty()) {
            Log.i("PjsipCore", "call ${call.callUid.take(8)} end reasons=${reasonsSnapshot.joinToString(" | ")}")
        }
        resetCallAudioState()
        val payload = mutableMapOf<String, Any?>(
            "type" to "call",
            "call" to null,
            "local_hangup" to localHangup,
            "sip_reasons" to reasonsSnapshot,
            "peer" to call.peer,
            "direction" to if (call.incoming) "incoming" else "outgoing",
            "had_ringing" to hadRinging,
        )
        if (code != null) payload["code"] = code
        if (!reason.isNullOrBlank()) payload["reason"] = reason
        emit(payload)
        main.post {
            ensurePjThread("main")
            runCatching { call.delete() }
        }
    }

    fun setMute(value: Boolean) {
        ensurePjThread("caller")
        muted = value
        try {
            endpoint?.audDevManager()?.setInputVolume(if (value) 0 else 100)
        } catch (_: Exception) {
        }
        val snapshot = synchronized(callLock) {
            activeCall?.takeIf { !it.disconnected }?.let { callEvent(it) }
        }
        if (snapshot != null) emit(snapshot)
    }

    fun setHold(value: Boolean) {
        ensurePjThread("caller")
        val call = synchronized(callLock) { activeCall?.takeIf { !it.disconnected } } ?: return
        if (call.held == value) return
        val param = CallOpParam(true)
        if (value) {
            call.setHold(param)
        } else {
            param.opt.setFlag(pjsua_call_flag.PJSUA_CALL_UNHOLD.toLong())
            call.reinvite(param)
        }
        val snapshot = synchronized(callLock) {
            if (call.disconnected) null else {
                call.held = value
                callEvent(call)
            }
        }
        if (snapshot != null) emit(snapshot)
    }

    fun setAudioRoute(route: String) {
        val nextSpeaker = route == "speaker"
        pendingSpeakerApply = nextSpeaker
        speakerOn = nextSpeaker
        emit(mapOf("type" to "audioRoute", "route" to route))
        val snapshot = synchronized(callLock) {
            activeCall?.takeIf { !it.disconnected }?.let { callEvent(it) }
        }
        if (snapshot != null) emit(snapshot)
    }

    fun syncHardwareAudioRoute(route: String) {
        val nextSpeaker = route == "speaker"
        if (nextSpeaker) {
            pendingSpeakerApply = false
        }
        if (speakerOn != nextSpeaker) {
            speakerOn = nextSpeaker
            emit(mapOf("type" to "audioRoute", "route" to route))
            val snapshot = synchronized(callLock) {
                activeCall?.takeIf { !it.disconnected }?.let { callEvent(it) }
            }
            if (snapshot != null) emit(snapshot)
        }
    }

    fun resetCallAudioState() {
        muted = false
        speakerOn = false
        pendingSpeakerApply = false
    }

    private fun syncInitialCallAudioState() {
        muted = false
        pendingSpeakerApply = false
        speakerOn = PhoneRuntime.context?.let { PhoneCallService.isHardwareSpeakerActive(it) } == true ||
            PhoneRuntime.telecomConnection?.isSystemSpeakerActive() == true
    }

    fun sendDtmf(digit: String) {
        ensurePjThread("caller")
        synchronized(callLock) { activeCall?.takeIf { !it.disconnected } }?.dialDtmf(digit)
    }

    internal fun onRegState(sipKey: String, prm: OnRegStateParam) {
        val code = prm.code
        val reason = prm.reason.trim()
        val registered = code == 200
        Log.i(
            "PjsipCore",
            "reg state account=${maskId(sipKey)} code=$code",
        )
        main.post {
            if (!managedAccounts.containsKey(sipKey)) return@post
            val nextState = if (registered) "registered" else "failed"
            val nextReason = if (registered) {
                null
            } else {
                listOfNotNull(
                    code.takeIf { it > 0 }?.toString(),
                    reason.takeIf { it.isNotEmpty() },
                ).joinToString(" ").ifBlank { "注册失败" }
            }
            for (acc in storedOrder) {
                if (acc.enabled && acc.hasCredential && acc.sipTransportKey() == sipKey) {
                    regStates[acc.accountKey] = nextState
                    regReasons[acc.accountKey] = nextReason
                }
            }
            emitAccountsSnapshot()
            emitAggregateRegistration(code = code, reason = reason)
            if (!hasRetryableUnregisteredAccounts()) {
                main.removeCallbacks(retryRunnable)
                retryScheduled = false
                retryAttempt = 0
            } else if (!registered) {
                scheduleRetryIfNeeded()
            }
        }
    }

    internal fun onIncomingCall(sipKey: String, prm: OnIncomingCallParam) {
        val managed = managedAccounts[sipKey] ?: return
        val isBusy = synchronized(callLock) { activeCall != null }
        if (isBusy) {
            // Single-call mic exclusivity: immediately reject secondary calls with 486 Busy Here.
            var busyCall: PjsipCall? = null
            runCatching {
                busyCall = PjsipCall(this, managed.account, sipKey, prm.callId, incoming = true)
                val busyParam = CallOpParam(true)
                busyParam.statusCode = pjsip_status_code.PJSIP_SC_BUSY_HERE
                busyCall?.answer(busyParam)
            }
            busyCall?.let { toDelete ->
                main.post {
                    ensurePjThread("main")
                    runCatching { toDelete.delete() }
                }
            }
            Log.i("PjsipCore", "rejected incoming call with 486 while call is active")
            return
        }

        val headers = parseHeaders(prm.rdata?.wholeMsg.orEmpty())
        val headerLineId = headers["x-simhub-line-id"]?.takeIf { it.isNotBlank() }
        val headerPeer = headers["x-simhub-peer-number"]?.takeIf { it.isNotBlank() }
        val headerOwn = headers["x-simhub-own-number"]?.takeIf { it.isNotBlank() }
        val matchedStored = resolveInboundStoredAccount(sipKey, headerOwn) ?: managed.stored
        val ownNum = headerOwn ?: matchedStored.displayNumber
        val transferSrc = headers["x-simhub-transfer"]?.takeIf { it.isNotBlank() }
        val transferReason = headers["x-simhub-transfer-reason"]?.takeIf { it.isNotBlank() }
        val gatewayCallId = headers["x-simhub-call-id"]?.takeIf { it.isNotBlank() }

        val call = PjsipCall(this, managed.account, matchedStored.accountKey, prm.callId, incoming = true).apply {
            phase = "incoming"
            peer = headerPeer.orEmpty()
            ownNumber = ownNum
            lineLabel = matchedStored.label.ifBlank { ownNum }
            lineId = headerLineId
            transferSource = transferSrc
            this.transferReason = transferReason
            this.gatewayCallId = gatewayCallId
        }
        if (call.peer.isBlank()) {
            runCatching {
                val info = call.info
                call.peer = parsePeer(info.remoteUri, "未知来电")
            }
        }
        if (call.peer.isBlank()) {
            call.peer = "未知来电"
        }
        val accepted = synchronized(callLock) {
            if (activeCall != null) {
                false
            } else {
                activeCall = call
                true
            }
        }
        if (!accepted) {
            runCatching {
                val busyParam = CallOpParam(true)
                busyParam.statusCode = pjsip_status_code.PJSIP_SC_BUSY_HERE
                call.answer(busyParam)
            }
            main.post {
                ensurePjThread("main")
                runCatching { call.delete() }
            }
            return
        }
        syncInitialCallAudioState()
        val snapshot = synchronized(callLock) {
            if (!call.disconnected && activeCall?.callUid == call.callUid) callEvent(call) else null
        }
        if (snapshot != null) emit(snapshot)
    }

    private fun captureReasonHeaders(call: PjsipCall, sipEvent: SipEvent?) {
        if (sipEvent == null) return
        runCatching {
            val msgs = listOf(
                sipEvent.body?.tsxState?.src?.rdata?.wholeMsg.orEmpty(),
                sipEvent.body?.rxMsg?.rdata?.wholeMsg.orEmpty(),
            ).filter { it.isNotBlank() }
            if (msgs.isEmpty()) return
            val collected = LinkedHashSet<String>()
            for (rawMsg in msgs) {
                collected.addAll(parseReasonHeaders(rawMsg))
            }
            if (collected.isNotEmpty()) {
                synchronized(callLock) {
                    for (reason in collected) {
                        if (!call.sipReasons.contains(reason)) {
                            call.sipReasons.add(reason)
                        }
                    }
                }
            }
        }
    }

    internal fun onCallTsxState(call: PjsipCall, prm: OnCallTsxStateParam? = null) {
        if (synchronized(callLock) { call.disconnected }) return
        captureReasonHeaders(call, prm?.e)
    }

    internal fun onCallState(call: PjsipCall, prm: OnCallStateParam? = null) {
        if (synchronized(callLock) { call.disconnected }) return
        captureReasonHeaders(call, prm?.e)
        val info: CallInfo = try {
            call.info
        } catch (error: Exception) {
            forceClearCall(call, reason = error.message)
            return
        }
        Log.i(
            "PjsipCore",
            "call ${call.callUid.take(8)} state=${info.state} code=${info.lastStatusCode}",
        )
        val phase = when (info.state) {
            pjsip_inv_state.PJSIP_INV_STATE_CALLING -> "dialing"
            pjsip_inv_state.PJSIP_INV_STATE_INCOMING -> "incoming"
            pjsip_inv_state.PJSIP_INV_STATE_EARLY -> "ringing"
            pjsip_inv_state.PJSIP_INV_STATE_CONNECTING -> "ringing"
            pjsip_inv_state.PJSIP_INV_STATE_CONFIRMED -> "active"
            pjsip_inv_state.PJSIP_INV_STATE_DISCONNECTED -> {
                forceClearCall(call, code = info.lastStatusCode, reason = info.lastReason)
                return
            }
            else -> "dialing"
        }

        val parsedPeer = parsePeer(info.remoteUri, "")
        val snapshot = synchronized(callLock) {
            if (call.disconnected || activeCall?.callUid != call.callUid) {
                null
            } else {
                call.phase = phase
                if (call.incoming) {
                    if (call.peer.isBlank() && parsedPeer.isNotBlank() && parsedPeer != "gateway") {
                        call.peer = parsedPeer
                    }
                } else if (parsedPeer.isNotBlank()) {
                    call.peer = parsedPeer
                }
                if (phase == "active" && call.answeredAt == null) {
                    call.answeredAt = Instant.now().toString()
                }
                callEvent(call)
            }
        }
        if (snapshot != null) emit(snapshot)
    }

    internal fun onCallMediaState(call: PjsipCall) {
        val ep = endpoint ?: return
        val info = try {
            call.info
        } catch (_: Exception) {
            return
        }
        for (index in info.media.indices) {
            val media = info.media[index]
            if (media.type == pjmedia_type.PJMEDIA_TYPE_AUDIO &&
                (media.status == pjsua_call_media_status.PJSUA_CALL_MEDIA_ACTIVE ||
                    media.status == pjsua_call_media_status.PJSUA_CALL_MEDIA_REMOTE_HOLD)
            ) {
                try {
                    val audio = call.getAudioMedia(index)
                    ep.audDevManager().captureDevMedia.startTransmit(audio)
                    audio.startTransmit(ep.audDevManager().playbackDevMedia)
                } catch (error: Exception) {
                    ep.utilLogWrite(2, "PjsipCore", "audio connect: ${error.message}")
                }
            }
        }
    }

    fun dispose() {
        ensurePjThread("main")
        val call = synchronized(callLock) {
            val c = activeCall
            if (c != null) {
                c.localHangupRequested = true
                c.disconnected = true
            }
            activeCall = null
            c
        }
        runCatching { call?.hangup(CallOpParam(true)) }
        call?.let { runCatching { it.delete() } }
        shutdownEndpointOnly()
    }

    private fun shutdownEndpointOnly() {
        ensurePjThread("main")
        regWaveGen++
        main.removeCallbacks(retryRunnable)
        retryScheduled = false
        retryAttempt = 0
        for ((_, managed) in managedAccounts) {
            destroyAccount(managed.account)
        }
        managedAccounts.clear()
        val ep = endpoint
        endpoint = null
        if (ep != null) {
            runCatching { ep.libDestroy() }
            runCatching { ep.delete() }
        }
    }

    private fun loadSystemCaBundlePem(): String = runCatching {
        // Export Android's active TrustManager CAs (supports Android 10-15 APEX Conscrypt store)
        // so PJSIP's bundled OpenSSL validates public SIP/TLS certs out of the box.
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(null as KeyStore?)
        val sb = StringBuilder()
        var count = 0
        for (tm in tmf.trustManagers) {
            val xtm = tm as? X509TrustManager ?: continue
            for (cert in xtm.acceptedIssuers) {
                val b64 = Base64.encodeToString(cert.encoded, Base64.NO_WRAP)
                sb.append("-----BEGIN CERTIFICATE-----\n")
                var i = 0
                while (i < b64.length) {
                    val end = minOf(i + 64, b64.length)
                    sb.append(b64, i, end).append('\n')
                    i = end
                }
                sb.append("-----END CERTIFICATE-----\n")
                count++
            }
        }
        Log.i("PjsipCore", "loaded $count Android system CA certs")
        sb.toString()
    }.getOrElse { err ->
        Log.w("PjsipCore", "failed to load Android system CAs: ${err.message}")
        ""
    }

    private fun ensureEndpoint(nullAudio: Boolean, allowSelfSignedTls: Boolean) {
        if (endpoint != null) return
        val ep = Endpoint()
        val epConfig = EpConfig()
        epConfig.uaConfig.userAgent = "SimHub Phone"
        epConfig.logConfig.level = 3
        epConfig.logConfig.setMsgLogging(0L)
        epConfig.logConfig.writer = logWriter
        ep.libCreate()
        ep.libInit(epConfig)

        val udp = TransportConfig().apply { port = 0 }
        val tcp = TransportConfig().apply { port = 0 }
        val systemCaPem = if (!allowSelfSignedTls) loadSystemCaBundlePem() else ""
        val tls = TransportConfig().apply {
            port = 0
            setTlsConfig(
                TlsConfig().apply {
                    verifyServer = !allowSelfSignedTls
                    if (verifyServer && systemCaPem.isNotEmpty()) {
                        caBuf = systemCaPem
                    }
                },
            )
        }
        ep.transportCreate(pjsip_transport_type_e.PJSIP_TRANSPORT_UDP, udp)
        ep.transportCreate(pjsip_transport_type_e.PJSIP_TRANSPORT_TCP, tcp)
        runCatching {
            ep.transportCreate(pjsip_transport_type_e.PJSIP_TRANSPORT_TLS, tls)
        }.onFailure { err ->
            Log.e("PjsipCore", "TLS transport unavailable: ${err.message}")
        }

        ep.libStart()
        if (nullAudio) {
            ep.audDevManager().setNullDev()
            Log.i("PjsipCore", "using null audio device")
        }
        endpoint = ep
        endpointVerifyServer = !allowSelfSignedTls
        endpointNullAudio = nullAudio

        Thread {
            @Suppress("UNUSED_VARIABLE")
            var probe: FinalizerThreadProbe? = FinalizerThreadProbe {
                ensurePjThread("FinalizerDaemon")
            }
            probe = null
            System.gc()
            System.runFinalization()
        }.start()

        runCatching {
            for (codec in ep.codecEnum2()) {
                val id = codec.codecId
                val prio: Short? = when {
                    id.startsWith("opus/48000", ignoreCase = true) -> 255
                    id.startsWith("G722/16000", ignoreCase = true) -> 254
                    id.startsWith("PCMU/8000", ignoreCase = true) -> 240
                    id.startsWith("PCMA/8000", ignoreCase = true) -> 239
                    else -> null
                }
                if (prio != null) ep.codecSetPriority(id, prio)
            }
        }.onFailure { err ->
            Log.e("PjsipCore", "codec priority warning: ${err.message}")
        }
        Log.i("PjsipCore", "PJSIP started verifyServer=$endpointVerifyServer")
    }

    private fun createManagedAccount(
        sipKey: String,
        acc: StoredSipAccount,
        group: List<StoredSipAccount>,
    ): Boolean {
        if (managedAccounts.size >= MAX_LIVE_PJSIP_ACCOUNTS) {
            val reason = "超过客户端并发账号上限 ($MAX_LIVE_PJSIP_ACCOUNTS)"
            for (member in group) {
                capacityBlockedAccountKeys.add(member.accountKey)
                regStates[member.accountKey] = "failed"
                regReasons[member.accountKey] = reason
            }
            Log.w("PjsipCore", "skipped creating account=${maskId(sipKey)}: reached limit $MAX_LIVE_PJSIP_ACCOUNTS")
            return false
        }

        val registrar = normalizeRegistrar(acc.registrarUri, acc.transport)
        val accountConfig = AccountConfig()
        accountConfig.idUri = "sip:${acc.username}@${acc.domain}"
        accountConfig.regConfig.registrarUri = registrar
        accountConfig.regConfig.registerOnAdd = false
        accountConfig.regConfig.setTimeoutSec(acc.registrationExpiresSec.toLong())
        // Retries are owned solely by PjsipCore's backoff scheduler and network callbacks;
        // disabling PJSIP's internal failure retry avoids overlapping REGISTER PJSIP_EBUSY errors.
        accountConfig.regConfig.setRetryIntervalSec(0)
        accountConfig.regConfig.setFirstRetryIntervalSec(0)
        accountConfig.sipConfig.proxies.add(proxyUri(registrar))

        val authUser = acc.authUsername.ifBlank { acc.username }
        val realm = acc.realm.ifBlank { "*" }
        val cred = if (acc.ha1.isNotBlank()) {
            AuthCredInfo(
                "Digest",
                realm,
                authUser,
                pjsip_cred_data_type.PJSIP_CRED_DATA_DIGEST,
                acc.ha1.lowercase(),
            )
        } else {
            AuthCredInfo(
                "Digest",
                realm,
                authUser,
                pjsip_cred_data_type.PJSIP_CRED_DATA_PLAIN_PASSWD,
                acc.password,
            )
        }
        accountConfig.sipConfig.authCreds.add(cred)

        val srtpUse = when (acc.srtp) {
            "disabled" -> pjmedia_srtp_use.PJMEDIA_SRTP_DISABLED
            "optional" -> pjmedia_srtp_use.PJMEDIA_SRTP_OPTIONAL
            else -> pjmedia_srtp_use.PJMEDIA_SRTP_MANDATORY
        }
        accountConfig.mediaConfig.setSrtpUse(srtpUse)
        accountConfig.mediaConfig.setSrtpSecureSignaling(0)

        val pjAcc = PjsipAccount(this, sipKey)
        return try {
            pjAcc.create(accountConfig, false)
            managedAccounts[sipKey] = ManagedAccount(acc, acc.configSignature(), pjAcc)
            for (member in group) {
                capacityBlockedAccountKeys.remove(member.accountKey)
                regStates[member.accountKey] = "unregistered"
                regReasons[member.accountKey] = null
            }
            true
        } catch (err: Exception) {
            destroyAccount(pjAcc)
            for (member in group) {
                regStates[member.accountKey] = "failed"
                regReasons[member.accountKey] = err.message ?: "账号注册初始化失败"
            }
            Log.e("PjsipCore", "account create failed account=${maskId(sipKey)}")
            main.post { scheduleRetryIfNeeded() }
            false
        }
    }

    private fun selectDialAccount(accountKey: String?): Pair<StoredSipAccount, ManagedAccount>? {
        fun resolveRegistered(acc: StoredSipAccount?): Pair<StoredSipAccount, ManagedAccount>? {
            if (acc == null || !acc.enabled) return null
            if (regStates[acc.accountKey] != "registered") return null
            val managed = managedAccounts[acc.sipTransportKey()] ?: return null
            return acc to managed
        }
        if (!accountKey.isNullOrBlank()) {
            resolveRegistered(storedOrder.firstOrNull { it.accountKey == accountKey })?.let { return it }
        }
        resolveRegistered(storedOrder.firstOrNull { it.isDefault })?.let { return it }
        for (acc in storedOrder) {
            resolveRegistered(acc)?.let { return it }
        }
        return null
    }

    private fun resolveInboundStoredAccount(sipKey: String, ownNumber: String?): StoredSipAccount? {
        val candidates = storedOrder.filter { it.sipTransportKey() == sipKey }
        if (candidates.isEmpty()) return null
        if (!ownNumber.isNullOrBlank()) {
            val clean = ownNumber.trim()
            val digits = clean.removePrefix("+")
            candidates.firstOrNull {
                val p = it.phoneNumber.trim()
                p.isNotEmpty() && (p == clean || p.removePrefix("+") == digits)
            }?.let { return it }
        }
        return candidates.firstOrNull { it.enabled } ?: candidates.first()
    }

    private fun normalizeRegistrar(raw: String, transport: String): String {
        var cleaned = raw.trim()
        if (cleaned.startsWith("<") && cleaned.endsWith(">")) {
            cleaned = cleaned.substring(1, cleaned.length - 1).trim()
        }
        if (!cleaned.startsWith("sip:", ignoreCase = true) &&
            !cleaned.startsWith("sips:", ignoreCase = true)
        ) {
            cleaned = "sip:$cleaned"
        }
        val base = cleaned.substringBefore(';')
        val hasTransport = cleaned.contains("transport=", ignoreCase = true)
        return if (hasTransport) cleaned else "$base;transport=$transport"
    }

    private fun proxyUri(registrar: String): String {
        val base = registrar.substringBefore(';')
        val transport = registrar.substringAfter("transport=", "").substringBefore(';')
        return if (transport.isBlank()) "$base;lr" else "$base;lr;transport=$transport"
    }

    private fun parseHeaders(wholeMsg: String): Map<String, String> {
        if (wholeMsg.isBlank()) return emptyMap()
        val result = HashMap<String, String>()
        val headerBlock = wholeMsg.substringBefore("\r\n\r\n").substringBefore("\n\n")
        for (line in headerBlock.lineSequence()) {
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val name = line.substring(0, colon).trim().lowercase()
            val value = line.substring(colon + 1).trim()
            if (name.startsWith("x-simhub-")) {
                result[name] = value
            }
        }
        return result
    }

    private fun emitAccountsSnapshot() {
        emit(mapOf("type" to "accounts", "accounts" to accountsPayload()))
    }

    private fun emitAggregateRegistration(code: Int? = null, reason: String? = null) {
        val state = when {
            regStates.values.any { it == "registered" } -> "registered"
            regStates.values.any { it == "registering" } -> "registering"
            regStates.values.any { it == "failed" } -> "failed"
            else -> "unregistered"
        }
        val map = mutableMapOf<String, Any?>("type" to "registration", "state" to state)
        if (code != null) map["code"] = code
        if (!reason.isNullOrBlank()) map["reason"] = reason
        emit(map)
    }

    private fun callEvent(call: PjsipCall): Map<String, Any?> {
        return mapOf(
            "type" to "call",
            "call" to mapOf(
                "id" to call.callUid,
                "peer" to call.peer,
                "direction" to if (call.incoming) "incoming" else "outgoing",
                "phase" to call.phase,
                "line_label" to call.lineLabel.ifBlank { call.ownNumber.ifBlank { "本机出局" } },
                "started_at" to call.startedAt,
                "answered_at" to call.answeredAt,
                "muted" to muted,
                "speaker_on" to speakerOn,
                "account_key" to call.accountKey,
                "own_number" to call.ownNumber,
                "held" to call.held,
                "line_id" to call.lineId,
                "transfer_source" to call.transferSource,
                "transfer_reason" to call.transferReason,
                "gateway_call_id" to call.gatewayCallId,
            ),
        )
    }

    private fun parsePeer(remoteUri: String, fallback: String): String {
        val value = remoteUri.substringAfter("sip:", remoteUri)
        return value.substringBefore("@").substringBefore(";").substringBefore(">").ifBlank { fallback }
    }

    private fun maskId(value: String): String {
        val clean = value.trim()
        if (clean.length <= 5) return "***"
        return "${clean.take(3)}***${clean.takeLast(2)}"
    }

    private fun parseReasonHeaders(wholeMsg: String): List<String> {
        if (wholeMsg.isBlank()) return emptyList()
        val reasons = mutableListOf<String>()
        for (rawLine in wholeMsg.split('\n')) {
            val line = rawLine.trimEnd('\r').trim()
            if (line.isEmpty()) break
            if (line.startsWith("reason:", ignoreCase = true)) {
                val value = line.substringAfter(':', "").trim()
                if (value.isNotEmpty()) {
                    reasons.add(value)
                }
            }
        }
        return reasons
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { emitEvent(event) }
    }
}

private class FinalizerThreadProbe(private val onFinalize: () -> Unit) {
    @Suppress("ProtectedInFinal", "unused")
    protected fun finalize() {
        onFinalize()
    }
}

private class PjsipAccount(
    private val owner: PjsipCore,
    private val accountKey: String,
) : Account() {
    override fun onRegState(prm: OnRegStateParam) {
        owner.onRegState(accountKey, prm)
    }

    override fun onIncomingCall(prm: OnIncomingCallParam) {
        owner.onIncomingCall(accountKey, prm)
    }

    @Synchronized
    override fun delete() {
        owner.ensurePjThread("gc")
        super.delete()
    }
}

internal class PjsipCall(
    private val owner: PjsipCore,
    account: Account,
    val accountKey: String,
    callId: Int,
    val incoming: Boolean,
) : Call(account, callId) {
    val callUid: String = UUID.randomUUID().toString()
    @Volatile
    var disconnected: Boolean = false
    var peer: String = ""
    var ownNumber: String = ""
    var lineLabel: String = ""
    var phase: String = "dialing"
    var held: Boolean = false
    var lineId: String? = null
    var transferSource: String? = null
    var transferReason: String? = null
    var gatewayCallId: String? = null
    val startedAt: String = Instant.now().toString()
    var answeredAt: String? = null
    @Volatile
    var localHangupRequested: Boolean = false
    val sipReasons: MutableList<String> = mutableListOf()

    override fun onCallState(prm: OnCallStateParam) {
        owner.onCallState(this, prm)
    }

    override fun onCallTsxState(prm: OnCallTsxStateParam) {
        owner.onCallTsxState(this, prm)
    }

    override fun onCallMediaState(prm: OnCallMediaStateParam) {
        owner.onCallMediaState(this)
    }

    @Synchronized
    override fun delete() {
        owner.ensurePjThread("gc")
        super.delete()
    }
}

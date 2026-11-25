package local.simhub.phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/**
 * Owns the process-wide SIP core and keeps it alive after the Flutter activity
 * is closed. The same service renders the ready, incoming and active call
 * notifications and answers/hangs up directly from notification actions.
 */
class PhoneCallService : Service() {
    companion object {
        private const val TAG = "PhoneCallService"
        private const val CHANNEL_INCOMING = "incoming_calls"
        private const val CHANNEL_ACTIVE = "ongoing_calls"
        private const val CHANNEL_READY = "sip_ready"
        private const val NOTIFICATION_READY = 1000
        private const val NOTIFICATION_INCOMING = 1001
        private const val NOTIFICATION_ACTIVE = 1002
        private const val ACTION_START_CORE = "local.simhub.phone.START_CORE"
        private const val ACTION_READY = "local.simhub.phone.READY"
        private const val ACTION_INCOMING = "local.simhub.phone.INCOMING"
        private const val ACTION_ACTIVE = "local.simhub.phone.ACTIVE"
        private const val ACTION_ANSWER = "local.simhub.phone.ANSWER"
        private const val ACTION_HANGUP = "local.simhub.phone.HANGUP"
        private const val EXTRA_CALL_ID = "call_id"
        private const val EXTRA_PEER = "peer"
        private const val EXTRA_OWN_NUMBER = "own_number"
        private const val EXTRA_TRANSFER_SOURCE = "transfer_source"
        private const val EXTRA_TRANSFER_REASON = "transfer_reason"

        fun startCore(context: Context) {
            start(
                context,
                Intent(context, PhoneCallService::class.java).setAction(ACTION_START_CORE),
            )
        }

        fun incoming(
            context: Context,
            callId: String,
            peer: String,
            ownNumber: String = "",
            transferSource: String = "",
            transferReason: String = "",
        ) {
            start(
                context,
                Intent(context, PhoneCallService::class.java)
                    .setAction(ACTION_INCOMING)
                    .putExtra(EXTRA_CALL_ID, callId)
                    .putExtra(EXTRA_PEER, peer)
                    .putExtra(EXTRA_OWN_NUMBER, ownNumber)
                    .putExtra(EXTRA_TRANSFER_SOURCE, transferSource)
                    .putExtra(EXTRA_TRANSFER_REASON, transferReason),
            )
        }

        fun active(context: Context, callId: String, peer: String, ownNumber: String = "") {
            start(
                context,
                Intent(context, PhoneCallService::class.java)
                    .setAction(ACTION_ACTIVE)
                    .putExtra(EXTRA_CALL_ID, callId)
                    .putExtra(EXTRA_PEER, peer)
                    .putExtra(EXTRA_OWN_NUMBER, ownNumber),
            )
        }

        fun ready(context: Context) {
            start(
                context,
                Intent(context, PhoneCallService::class.java).setAction(ACTION_READY),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PhoneCallService::class.java))
        }

        fun onCoreEvent(event: Map<String, Any?>) {
            val context = PhoneRuntime.context ?: return
            when (event["type"]) {
                "registration" -> {
                    if (event["state"] == "registered") ready(context)
                }
                "call" -> {
                    val call = event["call"] as? Map<*, *>
                    if (call == null) {
                        PhoneRuntime.telecomConnection?.markEnded()
                        PhoneRuntime.telecomConnection = null
                        PhoneRuntime.telecomCallId = null
                        PhoneRuntime.core?.resetCallAudioState()
                        ready(context)
                    } else {
                        val callId = call["id"]?.toString() ?: return
                        val peer = call["peer"]?.toString().orEmpty()
                        val ownNumber = call["own_number"]?.toString().orEmpty()
                        val transferSource = call["transfer_source"]?.toString().orEmpty()
                        val transferReason = call["transfer_reason"]?.toString().orEmpty()
                        when (call["phase"]?.toString()) {
                            "incoming" -> {
                                if (PhoneRuntime.telecomCallId != callId) {
                                    PhoneRuntime.telecomCallId = callId
                                    SimHubConnectionService.reportIncoming(context, callId, peer)
                                }
                                incoming(context, callId, peer, ownNumber, transferSource, transferReason)
                            }
                            "active" -> {
                                PhoneRuntime.telecomConnection?.markActive()
                                active(context, callId, peer, ownNumber)
                            }
                        }
                    }
                }
            }
        }

        fun recordEndedCall(call: Map<*, *>, endEvent: Map<String, Any?> = emptyMap()) {
            if (PhoneRuntime.bridge?.hasListener == true) return
            val context = PhoneRuntime.context ?: return
            val direction = call["direction"]?.toString() ?: "outgoing"
            val answeredAt = call["answered_at"]?.toString()?.takeIf { it.isNotBlank() }
            val code = (endEvent["code"] as? Number)?.toInt()
            val localHangup = endEvent["local_hangup"] == true
            val sipReasons = (endEvent["sip_reasons"] as? List<*>)
                ?.mapNotNull { it?.toString() }
                .orEmpty()
            val reasonToken = extractBackgroundReasonToken(sipReasons)
            val q850 = extractBackgroundQ850Cause(sipReasons)
            val completedElsewhere = sipReasons.any {
                it.contains("Call completed elsewhere", ignoreCase = true)
            }
            val midCallFailure = answeredAt != null && !localHangup &&
                (isMidCallFailureToken(reasonToken) || isMidCallFailureQ850(q850))
            val outcome = when {
                midCallFailure -> "failed"
                answeredAt != null -> "completed"
                direction == "incoming" -> when {
                    localHangup -> "rejected"
                    completedElsewhere -> "cancelled"
                    else -> "missed"
                }
                localHangup -> "cancelled"
                code == 486 || code == 603 -> "rejected"
                reasonToken == "CARRIER_BUSY" || reasonToken == "CARRIER_CALL_REJECTED" -> "rejected"
                code != null && code >= 400 -> "failed"
                reasonToken != null -> "failed"
                else -> "cancelled"
            }
            val durationMs = answeredAt?.let {
                runCatching {
                    (System.currentTimeMillis() - Instant.parse(it).toEpochMilli()).coerceAtLeast(0)
                }.getOrNull()
            }
            val ownNumber = call["own_number"]?.toString()?.trim().orEmpty()
            val transferSource = call["transfer_source"]?.toString()?.trim().orEmpty()
            val transferReason = call["transfer_reason"]?.toString()?.trim().orEmpty()
            val endReason = when {
                outcome == "cancelled" && direction == "incoming" && completedElsewhere ->
                    "已在其他设备接听"
                midCallFailure || outcome == "rejected" || outcome == "failed" ->
                    describeBackgroundEndReason(reasonToken, q850, code)
                else -> ""
            }

            val record = JSONObject().apply {
                put("id", call["id"]?.toString() ?: "")
                put("peer", call["peer"]?.toString() ?: "")
                put("direction", direction)
                put("outcome", outcome)
                put("started_at", call["started_at"]?.toString() ?: "")
                put("line_label", call["line_label"]?.toString() ?: "")
                if (durationMs != null) put("duration_ms", durationMs)
                if (ownNumber.isNotEmpty()) put("own_number", ownNumber)
                if (transferSource.isNotEmpty()) put("transfer_source", transferSource)
                if (transferReason.isNotEmpty()) put("transfer_reason", transferReason)
                if (endReason.isNotEmpty()) put("end_reason", endReason)
            }
            val prefs = context.getSharedPreferences("simhub_phone", Context.MODE_PRIVATE)
            val existing = runCatching {
                JSONArray(prefs.getString("call_history", "[]") ?: "[]")
            }.getOrElse { JSONArray() }
            val updated = JSONArray().put(record)
            for (index in 0 until minOf(existing.length(), 199)) {
                updated.put(existing.get(index))
            }
            prefs.edit().putString("call_history", updated.toString()).apply()
            Log.i(TAG, "recorded ended call direction=$direction outcome=$outcome")
        }

        private fun extractBackgroundReasonToken(sipReasons: List<String>): String? {
            val regex = Regex("""SIP\s*;\s*cause\s*=\s*\d{3}\s*(?:;[^;]*)?;\s*text\s*=\s*"([A-Za-z0-9_]+)"""", RegexOption.IGNORE_CASE)
            for (header in sipReasons) {
                val m = regex.find(header)
                if (m != null) return m.groupValues[1].uppercase()
            }
            return null
        }

        private fun extractBackgroundQ850Cause(sipReasons: List<String>): Int? {
            val regex = Regex("""Q\.850\s*;\s*cause\s*=\s*(\d+)""", RegexOption.IGNORE_CASE)
            for (header in sipReasons) {
                val m = regex.find(header)
                if (m != null) return m.groupValues[1].toIntOrNull()
            }
            return null
        }

        private fun isMidCallFailureToken(token: String?): Boolean {
            if (token == null) return false
            return token in setOf(
                "ENGINE_MEDIA_FAILED",
                "ENGINE_MEDIA_TIMEOUT",
                "ENGINE_NO_AUDIO",
                "ENGINE_CALL_POLICY_ENDED",
                "ENGINE_EPOCH_CHANGED",
                "ENGINE_CALL_FAILED",
                "ENGINE_STATE_UNCERTAIN",
                "ENGINE_UNREACHABLE",
                "ENGINE_RESULT_UNKNOWN",
                "ENGINE_CALL_DISAPPEARED",
                "ENGINE_HANGUP_UNCONFIRMED",
                "UPSTREAM_CALL_FAILED",
            ) || token.startsWith("UPSTREAM_SIP_")
        }

        private fun isMidCallFailureQ850(q850: Int?): Boolean {
            return q850 in setOf(38, 41, 47, 102)
        }

        private fun describeBackgroundEndReason(
            token: String?,
            q850: Int?,
            code: Int?,
        ): String {
            return when {
                token == "CARRIER_BUSY" -> "对方正在通话中或忙线。"
                token == "CARRIER_CALL_REJECTED" -> "对方拒绝了来电。"
                token == "CARRIER_NO_ANSWER" -> "对方无人接听。"
                token == "CARRIER_CREDIT_LIMIT" -> "当前号码余额不足，无法拨打。"
                token == "CARRIER_SERVICE_DENIED" -> "运营商拒绝提供本次通话服务。"
                token == "CARRIER_USER_UNKNOWN" -> "拨打的号码不存在。"
                token == "CARRIER_AUTH_REJECTED" -> "当前线路被运营商限制呼出。"
                token == "TEST_ROUTE_DISABLED" -> "该测试短号未启用。"
                token == "TEST_ENGINE_UNAVAILABLE" || token == "TEST_ENGINE_ERROR" -> "测试语音服务暂不可用。"
                token == "ENGINE_IMS_NOT_READY" -> "当前号码线路尚未完成 IMS 注册。"
                token == "ENGINE_LINE_BUSY" || token == "CALL_IN_PROGRESS" -> "当前线路正在通话中。"
                token == "ENGINE_LINE_NOT_FOUND" || token == "OUTBOUND_NOT_BOUND" -> "当前账号未绑定可用的外呼线路。"
                token == "LINE_SUSPENDED" -> "当前号码线路已被停用或暂停服务。"
                token == "LINE_UNAVAILABLE" -> "当前号码线路暂不可用。"
                token == "ENGINE_MEDIA_FAILED" || token == "ENGINE_NO_AUDIO" ->
                    "语音媒体连接中断，通话已结束。"
                token == "ENGINE_MEDIA_TIMEOUT" ->
                    "通话媒体超时中断，已自动结束。"
                token == "ENGINE_MEDIA_NOT_READY" || token == "ENGINE_MEDIA_CONFLICT" ->
                    "线路媒体通道尚未就绪或被占用。"
                token == "ENGINE_CALL_POLICY_ENDED" -> "通话因线路策略限制或资源不可用已结束。"
                token == "ENGINE_EPOCH_CHANGED" -> "网关状态已变更，请重新发起呼叫。"
                token == "ENGINE_DIAL_TIMEOUT" -> "呼叫响应超时，结果未知。"
                token == "ENGINE_UNREACHABLE" || token == "ENGINE_CALL_FAILED" -> "网关或线路异常，通话未能维持。"
                token == "ENGINE_RESULT_UNKNOWN" || token == "ENGINE_STATE_UNCERTAIN" || token == "ENGINE_CALL_DISAPPEARED" || token == "ENGINE_HANGUP_UNCONFIRMED" ->
                    "通话状态未确认，请先核对线路状态。"
                token == "UPSTREAM_SIP_487" || token == "UPSTREAM_CALL_FAILED" -> "呼叫被上游网络中止。"
                token == "CODEC_MISMATCH" -> "双方没有可用的音频编码。"
                token == "FORBIDDEN" || token == "MISSING_GATEWAY_ACCOUNT" || token == "ENGINE_UNAUTHORIZED" ->
                    "当前账号无权拨打该号码。"
                q850 == 41 -> "语音媒体连接中断，通话已结束。"
                q850 == 102 -> "通话媒体超时中断，已自动结束。"
                q850 == 47 -> "通话因线路策略限制或资源不可用已结束。"
                q850 == 38 -> "网关或线路连接异常，通话已中断。"
                q850 == 1 -> "拨打的号码不存在。"
                q850 == 17 -> "对方正在通话中或忙线。"
                q850 == 19 -> "对方无人接听。"
                q850 == 20 -> "对方暂时关机或不在服务区。"
                q850 == 21 -> "呼叫被对方或运营商拒绝。"
                code == 486 || code == 603 -> "对方正忙或已拒接。"
                code == 487 -> "呼叫被远端中止。"
                code != null && code >= 400 -> "未接通（SIP $code）"
                else -> "呼叫未成功"
            }
        }

        fun isHardwareSpeakerActive(context: Context): Boolean {
            val audio = context.getSystemService(AudioManager::class.java) ?: return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val dev = audio.communicationDevice
                if (dev != null) {
                    return dev.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                }
            }
            @Suppress("DEPRECATION")
            return audio.isSpeakerphoneOn
        }

        fun setSpeaker(context: Context, on: Boolean) {
            val audio = context.getSystemService(AudioManager::class.java) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audio.mode = AudioManager.MODE_IN_COMMUNICATION
                val type = if (on) {
                    AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                } else {
                    AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                }
                val device = audio.availableCommunicationDevices.firstOrNull { it.type == type }
                if (device != null) {
                    val accepted = audio.setCommunicationDevice(device)
                    Log.i(TAG, "setCommunicationDevice speaker=$on accepted=$accepted")
                }
            }
            @Suppress("DEPRECATION")
            runCatching { audio.isSpeakerphoneOn = on }
                .onFailure { Log.e(TAG, "isSpeakerphoneOn failed", it) }
        }

        private fun start(context: Context, intent: Intent) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                Log.e(TAG, "could not start call service", error)
            }
        }
    }

    private lateinit var manager: NotificationManager
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var connectivityManager: ConnectivityManager? = null

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            Log.i(TAG, "network available, ensuring SIP registration")
            PhoneRuntime.core?.ensureRegistered()
        }
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        Log.i(TAG, "audio focus changed: $change")
    }

    override fun onCreate() {
        super.onCreate()
        manager = getSystemService(NotificationManager::class.java)
        SimHubConnectionService.ensureRegistered(applicationContext)
        createChannels()
        connectivityManager = getSystemService(ConnectivityManager::class.java)
        runCatching {
            connectivityManager?.registerDefaultNetworkCallback(networkCallback)
        }.onFailure { err ->
            Log.w(TAG, "registerDefaultNetworkCallback failed: ${err.message}")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_CORE -> {
                showCurrentNotification()
                val existingCore = PhoneRuntime.core
                if (existingCore == null) {
                    val stored = PhoneAccountStore.loadAll(applicationContext)
                    if (stored.any { it.enabled }) {
                        val core = PjsipCore(PhoneRuntime::onCoreEvent)
                        PhoneRuntime.core = core
                        core.syncAccounts(stored, registerNow = true)
                    } else {
                        val config = PhoneRuntime.pendingConfig
                        if (config != null) {
                            val core = PjsipCore(PhoneRuntime::onCoreEvent)
                            core.initialize(config)
                            PhoneRuntime.core = core
                            core.registerAll()
                        }
                    }
                } else {
                    existingCore.ensureRegistered()
                }
            }
            ACTION_READY -> showCurrentNotification()
            ACTION_INCOMING -> {
                val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return START_NOT_STICKY
                val peer = intent.getStringExtra(EXTRA_PEER).orEmpty()
                val ownNumber = intent.getStringExtra(EXTRA_OWN_NUMBER).orEmpty()
                val transferSource = intent.getStringExtra(EXTRA_TRANSFER_SOURCE).orEmpty()
                val transferReason = intent.getStringExtra(EXTRA_TRANSFER_REASON).orEmpty()
                manager.cancel(NOTIFICATION_READY)
                manager.cancel(NOTIFICATION_ACTIVE)
                showForeground(
                    NOTIFICATION_INCOMING,
                    incomingNotification(callId, peer, ownNumber, transferSource, transferReason),
                )
            }
            ACTION_ACTIVE -> {
                val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return START_NOT_STICKY
                val peer = intent.getStringExtra(EXTRA_PEER).orEmpty()
                val ownNumber = intent.getStringExtra(EXTRA_OWN_NUMBER).orEmpty()
                startCallAudio()
                manager.cancel(NOTIFICATION_READY)
                manager.cancel(NOTIFICATION_INCOMING)
                showForeground(NOTIFICATION_ACTIVE, activeNotification(callId, peer, ownNumber))
            }
            ACTION_ANSWER -> {
                val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return START_NOT_STICKY
                PhoneRuntime.core?.answer(callId)
            }
            ACTION_HANGUP -> {
                val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return START_NOT_STICKY
                PhoneRuntime.core?.hangup(callId)
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        runCatching {
            connectivityManager?.unregisterNetworkCallback(networkCallback)
        }
        connectivityManager = null
        stopCallAudio()
        PhoneRuntime.core?.dispose()
        PhoneRuntime.core = null
        manager.cancel(NOTIFICATION_READY)
        manager.cancel(NOTIFICATION_INCOMING)
        manager.cancel(NOTIFICATION_ACTIVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun showCurrentNotification() {
        val call = PhoneRuntime.lastCall?.get("call") as? Map<*, *>
        if (call == null) {
            showReady()
            return
        }
        val callId = call["id"]?.toString()
        val peer = call["peer"]?.toString().orEmpty()
        val ownNumber = call["own_number"]?.toString().orEmpty()
        val transferSource = call["transfer_source"]?.toString().orEmpty()
        val transferReason = call["transfer_reason"]?.toString().orEmpty()
        when (call["phase"]?.toString()) {
            "incoming" -> if (callId != null) {
                manager.cancel(NOTIFICATION_READY)
                manager.cancel(NOTIFICATION_ACTIVE)
                showForeground(
                    NOTIFICATION_INCOMING,
                    incomingNotification(callId, peer, ownNumber, transferSource, transferReason),
                )
            } else {
                showReady()
            }
            "active" -> if (callId != null) {
                manager.cancel(NOTIFICATION_READY)
                manager.cancel(NOTIFICATION_INCOMING)
                showForeground(NOTIFICATION_ACTIVE, activeNotification(callId, peer, ownNumber))
            } else {
                showReady()
            }
            else -> showReady()
        }
    }

    private fun showReady() {
        stopCallAudio()
        manager.cancel(NOTIFICATION_INCOMING)
        manager.cancel(NOTIFICATION_ACTIVE)
        showForeground(NOTIFICATION_READY, readyNotification())
    }

    private fun startCallAudio() {
        if (audioManager != null) return
        val audio = getSystemService(AudioManager::class.java)
        audioManager = audio
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        val wantSpeaker = (PhoneRuntime.core?.isSpeakerOn() == true) ||
            (PhoneRuntime.telecomConnection?.isSystemSpeakerActive() == true) ||
            isHardwareSpeakerActive(applicationContext)
        if (wantSpeaker) {
            setSpeaker(applicationContext, true)
            PhoneRuntime.telecomConnection?.setSpeaker(true)
        }
        PhoneRuntime.core?.syncHardwareAudioRoute(if (wantSpeaker) "speaker" else "earpiece")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = request
            audio.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            )
        }
        val power = getSystemService(PowerManager::class.java)
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SimHubPhone:call").apply {
            setReferenceCounted(false)
            acquire(10 * 60 * 1000L)
        }
        val wifi = applicationContext.getSystemService(WifiManager::class.java)
        wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "SimHubPhone:call").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun stopCallAudio() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        audioManager?.let { audio ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                runCatching { audio.clearCommunicationDevice() }
            }
            @Suppress("DEPRECATION")
            runCatching { audio.isSpeakerphoneOn = false }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { audio.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audio.abandonAudioFocus(focusListener)
            }
            audio.mode = AudioManager.MODE_NORMAL
        }
        PhoneRuntime.core?.resetCallAudioState()
        focusRequest = null
        audioManager = null
    }

    private fun showForeground(id: Int, notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val needsMicrophone = id != NOTIFICATION_READY
            val type = if (needsMicrophone) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            }
            try {
                startForeground(id, notification, type)
                return
            } catch (error: Exception) {
                Log.e(TAG, "phoneCall foreground type failed", error)
            }
            try {
                startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                return
            } catch (error: Exception) {
                Log.e(TAG, "microphone foreground type failed", error)
            }
        }
        startForeground(id, notification)
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val incoming = NotificationChannel(
            CHANNEL_INCOMING,
            "来电",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "SIP 来电"
            enableVibration(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .build(),
            )
        }
        val active = NotificationChannel(
            CHANNEL_ACTIVE,
            "通话中",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "正在进行的 SIP 通话"
        }
        val ready = NotificationChannel(
            CHANNEL_READY,
            "SIP 在线",
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "保持 SIP 注册和后台接听"
            setShowBadge(false)
        }
        manager.createNotificationChannels(listOf(incoming, active, ready))
    }

    private fun builder(channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channel)
        } else {
            Notification.Builder(this)
        }

    private fun pendingIntentFlags(): Int =
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    private fun openIntent(): PendingIntent =
        PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            pendingIntentFlags(),
        )

    private fun actionIntent(action: String, requestCode: Int, callId: String): PendingIntent =
        PendingIntent.getService(
            this,
            requestCode,
            Intent(this, PhoneCallService::class.java)
                .setAction(action)
                .putExtra(EXTRA_CALL_ID, callId),
            pendingIntentFlags(),
        )

    private fun readyNotification(): Notification =
        builder(CHANNEL_READY)
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setContentTitle("SIP 在线")
            .setContentText("等待来电")
            .setContentIntent(openIntent())
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_MIN)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()

    private fun incomingNotification(
        callId: String,
        peer: String,
        ownNumber: String,
        transferSource: String,
        transferReason: String = "",
    ): Notification {
        val caller = peer.ifBlank { "未知号码" }
        val isAi = transferSource.equals("ai", ignoreCase = true) ||
            transferSource.startsWith("ai", ignoreCase = true)
        val title = if (isAi) {
            "AI 转人工来电 · $caller"
        } else {
            "来电 · $caller"
        }
        val textParts = mutableListOf<String>()
        if (ownNumber.isNotBlank()) textParts.add("打给本机号码：$ownNumber")
        if (isAi && transferReason.isNotBlank()) textParts.add("转接原因：$transferReason")
        val text = if (textParts.isNotEmpty()) textParts.joinToString(" · ") else "点击接听或拒接"
        val builder = builder(CHANNEL_INCOMING)
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openIntent())
            .setFullScreenIntent(openIntent(), true)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)
        builder.addAction(
            android.R.drawable.ic_menu_call,
            "接听",
            actionIntent(ACTION_ANSWER, 1, callId),
        )
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            "拒接",
            actionIntent(ACTION_HANGUP, 2, callId),
        )
        return builder.build()
    }

    private fun activeNotification(callId: String, peer: String, ownNumber: String): Notification {
        val caller = peer.ifBlank { "未知号码" }
        val title = "通话中 · $caller"
        val text = if (ownNumber.isNotBlank()) "本机号码：$ownNumber" else caller
        val builder = builder(CHANNEL_ACTIVE)
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openIntent())
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            "挂断",
            actionIntent(ACTION_HANGUP, 1, callId),
        )
        return builder.build()
    }
}

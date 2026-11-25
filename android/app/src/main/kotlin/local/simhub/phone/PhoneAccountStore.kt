package local.simhub.phone

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class StoredSipAccount(
    val accountKey: String,
    val username: String,
    val authUsername: String,
    val phoneNumber: String = "",
    val domain: String,
    val realm: String,
    val registrarUri: String,
    val transport: String,
    val srtp: String,
    val ha1: String,
    val password: String,
    val registrationExpiresSec: Int,
    val label: String,
    val group: String,
    val enabled: Boolean,
    val isDefault: Boolean,
    val allowSelfSignedTls: Boolean,
    val nullAudio: Boolean,
) {
    val displayNumber: String
        get() = phoneNumber.ifBlank { username }

    val hasCredential: Boolean
        get() = ha1.isNotBlank() || password.isNotBlank()

    fun configSignature(): String = listOf(
        username,
        authUsername,
        domain,
        realm,
        registrarUri,
        transport,
        srtp,
        ha1,
        password,
        registrationExpiresSec.toString(),
        allowSelfSignedTls.toString(),
    ).joinToString("|")

    fun toFlutterMap(registrationState: String, reason: String?): Map<String, Any?> = mapOf(
        "account_key" to accountKey,
        "username" to username,
        "auth_username" to authUsername,
        "phone_number" to phoneNumber,
        "domain" to domain,
        "realm" to realm,
        "registrar_uri" to registrarUri,
        "transport" to transport,
        "srtp" to srtp,
        "label" to label,
        "group" to group,
        "enabled" to enabled,
        "is_default" to isDefault,
        "has_credential" to hasCredential,
        "registration" to registrationState,
        "reason" to reason,
    )
}

/**
 * Persists SIP account metadata in private SharedPreferences while sealing HA1
 * and password secrets with an AndroidKeyStore AES-256-GCM key.
 */
internal object PhoneAccountStore {
    private const val TAG = "PhoneAccountStore"
    private const val PREFS_NAME = "simhub_phone_accounts"
    private const val KEY_ACCOUNTS = "accounts_v1"
    private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
    private const val KEY_ALIAS = "simhub_phone_cred_aes_v1"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val GCM_TAG_BITS = 128

    private val lock = Any()

    fun loadAll(context: Context): List<StoredSipAccount> = synchronized(lock) {
        loadLocked(context)
    }

    fun upsert(context: Context, rawList: List<Map<*, *>>): List<StoredSipAccount> =
        synchronized(lock) {
            val current = loadLocked(context).toMutableList()
            for (raw in rawList) {
                val parsed = parseIncomingAccount(raw) ?: continue
                val existingIdx = current.indexOfFirst { it.accountKey == parsed.accountKey }
                if (existingIdx >= 0) {
                    val existing = current[existingIdx]
                    val keepExistingSecret = !parsed.hasCredential && existing.hasCredential
                    current[existingIdx] = parsed.copy(
                        ha1 = if (keepExistingSecret) existing.ha1 else parsed.ha1,
                        password = if (keepExistingSecret) existing.password else parsed.password,
                        phoneNumber = parsed.phoneNumber.ifBlank { existing.phoneNumber },
                        label = parsed.label.ifBlank { existing.label },
                        isDefault = existing.isDefault,
                    )
                } else {
                    current.add(parsed.copy(isDefault = current.isEmpty()))
                }
            }
            val normalized = normalizeDefaults(current)
            saveLocked(context, normalized)
            normalized
        }

    fun updateMeta(
        context: Context,
        accountKey: String,
        label: String?,
        group: String?,
    ): List<StoredSipAccount> = synchronized(lock) {
        val updated = loadLocked(context).map { item ->
            if (item.accountKey != accountKey) {
                item
            } else {
                item.copy(
                    label = label?.trim() ?: item.label,
                    group = group?.trim()?.ifEmpty { "默认分组" } ?: item.group,
                )
            }
        }
        saveLocked(context, updated)
        updated
    }

    fun setEnabled(
        context: Context,
        accountKey: String,
        enabled: Boolean,
    ): List<StoredSipAccount> = synchronized(lock) {
        val updated = loadLocked(context).map { item ->
            if (item.accountKey == accountKey) item.copy(enabled = enabled) else item
        }
        saveLocked(context, updated)
        updated
    }

    fun selectDefault(context: Context, accountKey: String): List<StoredSipAccount> =
        synchronized(lock) {
            val current = loadLocked(context)
            if (current.none { it.accountKey == accountKey }) return@synchronized current
            val updated = current.map { it.copy(isDefault = it.accountKey == accountKey) }
            saveLocked(context, updated)
            updated
        }

    fun remove(context: Context, accountKey: String): List<StoredSipAccount> =
        synchronized(lock) {
            val current = loadLocked(context).filterNot { it.accountKey == accountKey }
            val normalized = normalizeDefaults(current)
            saveLocked(context, normalized)
            normalized
        }

    private fun parseIncomingAccount(raw: Map<*, *>): StoredSipAccount? {
        val username = raw["username"]?.toString()?.trim().orEmpty()
        val domain = raw["domain"]?.toString()?.trim().orEmpty()
        val registrar = raw["registrar_uri"]?.toString()?.trim().orEmpty()
        if (username.isBlank() || domain.isBlank() || registrar.isBlank()) return null

        val key = raw["account_key"]?.toString()?.trim()?.ifBlank { null }
            ?: "$username@$domain"
        val transport = raw["transport"]?.toString()?.trim()?.lowercase()
            ?.takeIf { it == "tls" || it == "tcp" || it == "udp" } ?: "tls"
        val srtp = raw["srtp"]?.toString()?.trim()?.lowercase()
            ?.takeIf { it == "mandatory" || it == "optional" || it == "disabled" }
            ?: "mandatory"
        val expires = (raw["registration_expires_sec"] as? Number)?.toInt()
            ?.takeIf { it > 0 } ?: 300

        return StoredSipAccount(
            accountKey = key,
            username = username,
            authUsername = raw["auth_username"]?.toString()?.trim().orEmpty(),
            phoneNumber = raw["phone_number"]?.toString()?.trim().orEmpty(),
            domain = domain,
            realm = raw["realm"]?.toString()?.trim().orEmpty(),
            registrarUri = registrar,
            transport = transport,
            srtp = srtp,
            ha1 = raw["ha1"]?.toString()?.trim()?.lowercase().orEmpty(),
            password = raw["password"]?.toString().orEmpty(),
            registrationExpiresSec = expires,
            label = raw["label"]?.toString()?.trim().orEmpty(),
            group = raw["group"]?.toString()?.trim()?.ifBlank { "默认分组" } ?: "默认分组",
            enabled = raw["enabled"] != false,
            isDefault = raw["is_default"] == true,
            allowSelfSignedTls = raw["allow_self_signed_tls"] == true,
            nullAudio = raw["null_audio"] == true,
        )
    }

    private fun normalizeDefaults(list: List<StoredSipAccount>): List<StoredSipAccount> {
        if (list.isEmpty()) return emptyList()
        val defaultIdx = list.indexOfFirst { it.isDefault }.let { if (it >= 0) it else 0 }
        return list.mapIndexed { index, acc -> acc.copy(isDefault = index == defaultIdx) }
    }

    private fun loadLocked(context: Context): List<StoredSipAccount> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_ACCOUNTS, null) ?: return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val out = mutableListOf<StoredSipAccount>()
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val username = obj.optString("username", "").trim()
            val domain = obj.optString("domain", "").trim()
            val registrar = obj.optString("registrar_uri", "").trim()
            if (username.isEmpty() || domain.isEmpty() || registrar.isEmpty()) continue
            val (ha1, password) = decryptSecret(obj.optString("secret", ""))
            out.add(
                StoredSipAccount(
                    accountKey = obj.optString("account_key", "$username@$domain"),
                    username = username,
                    authUsername = obj.optString("auth_username", ""),
                    phoneNumber = obj.optString("phone_number", "").trim(),
                    domain = domain,
                    realm = obj.optString("realm", ""),
                    registrarUri = registrar,
                    transport = obj.optString("transport", "tls"),
                    srtp = obj.optString("srtp", "mandatory"),
                    ha1 = ha1,
                    password = password,
                    registrationExpiresSec = obj.optInt("registration_expires_sec", 300),
                    label = obj.optString("label", ""),
                    group = obj.optString("group", "默认分组").ifBlank { "默认分组" },
                    enabled = obj.optBoolean("enabled", true),
                    isDefault = obj.optBoolean("is_default", false),
                    allowSelfSignedTls = obj.optBoolean("allow_self_signed_tls", false),
                    nullAudio = obj.optBoolean("null_audio", false),
                ),
            )
        }
        return normalizeDefaults(out)
    }

    private fun saveLocked(context: Context, list: List<StoredSipAccount>) {
        val array = JSONArray()
        for (acc in list) {
            val obj = JSONObject().apply {
                put("account_key", acc.accountKey)
                put("username", acc.username)
                put("auth_username", acc.authUsername)
                put("phone_number", acc.phoneNumber)
                put("domain", acc.domain)
                put("realm", acc.realm)
                put("registrar_uri", acc.registrarUri)
                put("transport", acc.transport)
                put("srtp", acc.srtp)
                put("registration_expires_sec", acc.registrationExpiresSec)
                put("label", acc.label)
                put("group", acc.group)
                put("enabled", acc.enabled)
                put("is_default", acc.isDefault)
                put("allow_self_signed_tls", acc.allowSelfSignedTls)
                put("null_audio", acc.nullAudio)
                put("secret", encryptSecret(acc.ha1, acc.password))
            }
            array.put(obj)
        }
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_ACCOUNTS, array.toString())
            .apply()
    }

    private fun encryptSecret(ha1: String, password: String): String {
        if (ha1.isEmpty() && password.isEmpty()) return ""
        return runCatching {
            val payload = JSONObject().apply {
                put("ha1", ha1)
                put("password", password)
            }.toString()
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
            val encrypted = cipher.doFinal(payload.toByteArray(Charsets.UTF_8))
            val ivB64 = Base64.encodeToString(cipher.iv, Base64.NO_WRAP)
            val dataB64 = Base64.encodeToString(encrypted, Base64.NO_WRAP)
            "$ivB64:$dataB64"
        }.onFailure { err ->
            Log.e(TAG, "encryptSecret failed", err)
        }.getOrDefault("")
    }

    private fun decryptSecret(encoded: String): Pair<String, String> {
        if (encoded.isBlank()) return "" to ""
        val parts = encoded.split(":", limit = 2)
        if (parts.size != 2) return "" to ""
        return runCatching {
            val iv = Base64.decode(parts[0], Base64.NO_WRAP)
            val data = Base64.decode(parts[1], Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateSecretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
            val plain = String(cipher.doFinal(data), Charsets.UTF_8)
            val obj = JSONObject(plain)
            obj.optString("ha1", "") to obj.optString("password", "")
        }.onFailure { err ->
            Log.e(TAG, "decryptSecret failed", err)
        }.getOrDefault("" to "")
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }
}

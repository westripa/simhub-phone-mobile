package local.simhub.phone

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val REQ_PERMISSIONS = 1001
        private const val REQ_SCAN_QR = 2001
        private const val REQ_SCAN_QR_BATCH = 2002
    }

    private var pendingScanResult: MethodChannel.Result? = null
    private var pendingScanBatch: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PhoneRuntime.context = applicationContext

        val missing = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            missing.add(Manifest.permission.RECORD_AUDIO)
        }
        if (checkSelfPermission(Manifest.permission.CALL_PHONE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            missing.add(Manifest.permission.CALL_PHONE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            missing.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (missing.isNotEmpty()) {
            requestPermissions(missing.toTypedArray(), REQ_PERMISSIONS)
        }
    }

    override fun onResume() {
        super.onResume()
        PhoneRuntime.core?.ensureRegistered()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PhoneRuntime.bridge = PhoneCoreBridge(flutterEngine) { batch, result ->
            launchQrScanner(batch, result)
        }
    }

    private fun launchQrScanner(batch: Boolean, result: MethodChannel.Result) {
        if (pendingScanResult != null) {
            result.success(if (batch) emptyList<String>() else null)
            return
        }
        pendingScanResult = result
        pendingScanBatch = batch
        try {
            val intent = Intent(this, QrScanActivity::class.java)
                .putExtra(QrScanActivity.EXTRA_BATCH_MODE, batch)
            @Suppress("DEPRECATION")
            startActivityForResult(intent, if (batch) REQ_SCAN_QR_BATCH else REQ_SCAN_QR)
        } catch (_: Exception) {
            pendingScanResult = null
            pendingScanBatch = false
            result.success(if (batch) emptyList<String>() else null)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_SCAN_QR) {
            val result = pendingScanResult
            pendingScanResult = null
            pendingScanBatch = false
            val scanned = if (resultCode == Activity.RESULT_OK) {
                data?.getStringExtra("SCAN_RESULT")?.trim()?.takeIf { it.isNotEmpty() }
            } else {
                null
            }
            result?.success(scanned)
            return
        }
        if (requestCode == REQ_SCAN_QR_BATCH) {
            val result = pendingScanResult
            pendingScanResult = null
            pendingScanBatch = false
            val scannedList = if (resultCode == Activity.RESULT_OK) {
                data?.getStringArrayListExtra(QrScanActivity.EXTRA_SCAN_RESULTS)
                    ?.map { it.trim() }
                    ?.filter { it.isNotEmpty() }
                    ?: emptyList()
            } else {
                emptyList()
            }
            result?.success(scannedList)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        pendingScanResult?.success(if (pendingScanBatch) emptyList<String>() else null)
        pendingScanResult = null
        pendingScanBatch = false
        if (isFinishing && PhoneRuntime.bridge != null) {
            PhoneRuntime.bridge = null
        }
        super.onDestroy()
    }
}

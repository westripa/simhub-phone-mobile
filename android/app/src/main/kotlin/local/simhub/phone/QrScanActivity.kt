package local.simhub.phone

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.graphics.drawable.GradientDrawable
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.util.Size
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Built-in Camera2 + ZXing QR scanner optimized for monitor and print QR codes.
 * Crops only the centered viewfinder ROI and debounces results via [decodedOnce].
 */
class QrScanActivity : Activity() {
    companion object {
        private const val TAG = "QrScanActivity"
        private const val REQ_CAMERA = 3001
        private const val DECODE_INTERVAL_MS = 40L
        private const val DUPLICATE_DEBOUNCE_MS = 1200L
        const val EXTRA_BATCH_MODE = "BATCH_MODE"
        const val EXTRA_SCAN_RESULTS = "SCAN_RESULTS"
    }

    private lateinit var textureView: TextureView
    private var batchMode: Boolean = false
    private val decodedOnce = AtomicBoolean(false)
    private val scanLock = Any()
    private val scannedItems = LinkedHashSet<String>()
    private var lastDuplicateText: String? = null
    private var lastDuplicateAtMs: Long = 0L

    private lateinit var frameBox: View
    private lateinit var titleView: TextView
    private lateinit var hintView: TextView
    private var undoButton: Button? = null
    private var doneButton: Button? = null
    private var batchBar: LinearLayout? = null

    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var previewSurface: Surface? = null
    @Volatile
    private var cameraClosingOrPaused: Boolean = false
    private var previewSize: Size = Size(1280, 720)
    private var zoomRange: Range<Float>? = null
    private var lastDecodeAtMs: Long = 0L
    private var frameCount: Long = 0L

    private val fastReader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
            ),
        )
    }

    private val hardReader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
            ),
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        batchMode = intent?.getBooleanExtra(EXTRA_BATCH_MODE, false) == true
        setContentView(buildContentView())
    }

    override fun onResume() {
        super.onResume()
        cameraClosingOrPaused = false
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
            return
        }
        startBackgroundThread()
        if (textureView.isAvailable) {
            openCamera(textureView.width, textureView.height)
        } else {
            textureView.surfaceTextureListener = surfaceListener
        }
    }

    override fun onPause() {
        cameraClosingOrPaused = true
        closeCamera()
        stopBackgroundThread()
        super.onPause()
    }

    override fun onDestroy() {
        cameraClosingOrPaused = true
        closeCamera()
        stopBackgroundThread()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CAMERA) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startBackgroundThread()
                if (textureView.isAvailable) {
                    openCamera(textureView.width, textureView.height)
                } else {
                    textureView.surfaceTextureListener = surfaceListener
                }
            } else {
                setResult(RESULT_CANCELED)
                finish()
            }
        }
    }

    private val surfaceListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
            openCamera(width, height)
        }

        override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
            configureTransform(width, height)
        }

        override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean = true

        override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
    }

    private fun startBackgroundThread() {
        if (cameraThread != null) return
        val thread = HandlerThread("SimHubQrCamera").apply { start() }
        cameraThread = thread
        cameraHandler = Handler(thread.looper)
    }

    private fun stopBackgroundThread() {
        cameraThread?.quitSafely()
        runCatching { cameraThread?.join(400) }
        cameraThread = null
        cameraHandler = null
    }

    @SuppressLint("MissingPermission")
    private fun openCamera(viewWidth: Int, viewHeight: Int) {
        if (cameraClosingOrPaused || isFinishing || isDestroyed) return
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            return
        }
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = selectCameraId(manager) ?: run {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val chars = manager.getCameraCharacteristics(cameraId)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val choices = map?.getOutputSizes(SurfaceTexture::class.java)?.toList().orEmpty()
        previewSize = choosePreviewSize(choices)
        zoomRange = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
        } else {
            null
        }
        configureTransform(viewWidth, viewHeight)

        imageReader?.close()
        val reader = ImageReader.newInstance(1920, 1080, ImageFormat.YUV_420_888, 2)
        reader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                tryDecodeImage(image)
            } finally {
                image.close()
            }
        }, cameraHandler)
        imageReader = reader

        runCatching {
            manager.openCamera(
                cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        if (cameraClosingOrPaused || isFinishing || isDestroyed) {
                            runCatching { camera.close() }
                            return
                        }
                        cameraDevice = camera
                        createPreviewSession(camera, reader.surface)
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        runCatching { camera.close() }
                        if (cameraDevice === camera) cameraDevice = null
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        runCatching { camera.close() }
                        if (cameraDevice === camera) cameraDevice = null
                        if (!isFinishing && !isDestroyed) {
                            finish()
                        }
                    }
                },
                cameraHandler,
            )
        }.onFailure {
            setResult(RESULT_CANCELED)
            finish()
        }
    }

    @Suppress("DEPRECATION")
    private fun createPreviewSession(camera: CameraDevice, readerSurface: Surface) {
        if (cameraClosingOrPaused || isFinishing || isDestroyed || !textureView.isAvailable || !readerSurface.isValid) {
            runCatching { camera.close() }
            if (cameraDevice === camera) cameraDevice = null
            return
        }
        val texture = textureView.surfaceTexture ?: return
        var localSurface: Surface? = null
        runCatching {
            texture.setDefaultBufferSize(previewSize.width, previewSize.height)
            localSurface = Surface(texture)
            val surface = localSurface ?: return
            if (!surface.isValid || cameraClosingOrPaused || isFinishing || isDestroyed) {
                surface.release()
                runCatching { camera.close() }
                if (cameraDevice === camera) cameraDevice = null
                return
            }
            previewSurface?.release()
            previewSurface = surface

            val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(surface)
                addTarget(readerSurface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    zoomRange?.let { range ->
                        val target = 1.5f.coerceIn(range.lower, range.upper)
                        set(CaptureRequest.CONTROL_ZOOM_RATIO, target)
                    }
                }
            }

            camera.createCaptureSession(
                listOf(surface, readerSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (cameraClosingOrPaused || cameraDevice == null || isFinishing || isDestroyed) {
                            runCatching { session.close() }
                            return
                        }
                        captureSession = session
                        runCatching {
                            session.setRepeatingRequest(builder.build(), null, cameraHandler)
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        runCatching { session.close() }
                        if (!isFinishing && !isDestroyed) {
                            setResult(RESULT_CANCELED)
                            finish()
                        }
                    }
                },
                cameraHandler,
            )
        }.onFailure { err ->
            Log.w(TAG, "createPreviewSession aborted: ${err.message}")
            runCatching { localSurface?.release() }
            if (previewSurface === localSurface) previewSurface = null
            runCatching { camera.close() }
            if (cameraDevice === camera) cameraDevice = null
        }
    }

    private fun closeCamera() {
        runCatching { captureSession?.close() }
        captureSession = null
        runCatching { cameraDevice?.close() }
        cameraDevice = null
        runCatching { imageReader?.close() }
        imageReader = null
        runCatching { previewSurface?.release() }
        previewSurface = null
    }

    private fun tryDecodeImage(image: Image) {
        if (decodedOnce.get()) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastDecodeAtMs < DECODE_INTERVAL_MS) return
        lastDecodeAtMs = now
        frameCount++

        val yPlane = image.planes[0]
        val width = image.width
        val height = image.height
        val cropSize = (minOf(width, height) * 0.65f).toInt().coerceAtLeast(160)
        val left = ((width - cropSize) / 2).coerceAtLeast(0)
        val top = ((height - cropSize) / 2).coerceAtLeast(0)
        val rowStride = yPlane.rowStride
        val pixelStride = yPlane.pixelStride
        val buffer = yPlane.buffer
        val data = ByteArray(cropSize * cropSize)

        if (pixelStride == 1) {
            for (row in 0 until cropSize) {
                buffer.position((top + row) * rowStride + left)
                buffer.get(data, row * cropSize, cropSize)
            }
        } else {
            val rowBuffer = ByteArray(rowStride)
            for (row in 0 until cropSize) {
                buffer.position((top + row) * rowStride)
                val remaining = minOf(rowStride, buffer.remaining())
                buffer.get(rowBuffer, 0, remaining)
                val dstOffset = row * cropSize
                for (col in 0 until cropSize) {
                    data[dstOffset + col] = rowBuffer[(left + col) * pixelStride]
                }
            }
        }

        val decodeStartMs = SystemClock.elapsedRealtime()
        val source = PlanarYUVLuminanceSource(
            data,
            cropSize,
            cropSize,
            0,
            0,
            cropSize,
            cropSize,
            false,
        )
        val text = decodeTwoTier(source) ?: return
        val clean = text.trim()
        if (clean.isEmpty()) return

        if (!batchMode) {
            if (!decodedOnce.compareAndSet(false, true)) return
            val costMs = SystemClock.elapsedRealtime() - decodeStartMs
            Log.i(TAG, "decoded QR in ${costMs}ms len=${clean.length}")

            runOnUiThread {
                textureView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                setResult(RESULT_OK, Intent().putExtra("SCAN_RESULT", clean))
                finish()
            }
            return
        }

        val nowMs = SystemClock.elapsedRealtime()
        var added = false
        var duplicate = false
        var total = 0
        synchronized(scanLock) {
            if (clean == lastDuplicateText && nowMs - lastDuplicateAtMs < DUPLICATE_DEBOUNCE_MS) {
                return
            }
            if (scannedItems.contains(clean)) {
                lastDuplicateText = clean
                lastDuplicateAtMs = nowMs
                duplicate = true
                total = scannedItems.size
            } else {
                scannedItems.add(clean)
                lastDuplicateText = clean
                lastDuplicateAtMs = nowMs
                added = true
                total = scannedItems.size
            }
        }

        val costMs = SystemClock.elapsedRealtime() - decodeStartMs
        if (added) {
            Log.i(TAG, "batch QR queued count=$total cost=${costMs}ms len=${clean.length}")
        }

        runOnUiThread {
            if (added) {
                textureView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                flashViewfinder(success = true)
                updateBatchUi(total, status = "已加入队列（共 $total 个），继续对准下一个或点击完成")
            } else if (duplicate) {
                flashViewfinder(success = false)
                updateBatchUi(total, status = "该二维码已扫描（共 $total 个），请换下一个")
            }
        }
    }

    private fun decodeTwoTier(source: PlanarYUVLuminanceSource): String? {
        decodeSafe(fastReader, BinaryBitmap(GlobalHistogramBinarizer(source)))?.let { return it }
        decodeSafe(hardReader, BinaryBitmap(HybridBinarizer(source)))?.let { return it }
        if (frameCount % 5L == 0L) {
            decodeSafe(fastReader, BinaryBitmap(GlobalHistogramBinarizer(source.invert())))
                ?.let { return it }
        }
        return null
    }

    private fun decodeSafe(reader: MultiFormatReader, bitmap: BinaryBitmap): String? {
        return try {
            reader.decodeWithState(bitmap).text
        } catch (_: NotFoundException) {
            null
        } finally {
            reader.reset()
        }
    }

    private fun selectCameraId(manager: CameraManager): String? {
        val ids = manager.cameraIdList
        for (id in ids) {
            val facing = manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_BACK) return id
        }
        return ids.firstOrNull()
    }

    private fun choosePreviewSize(choices: List<Size>): Size {
        if (choices.isEmpty()) return Size(1280, 720)
        return choices
            .filter { it.width <= 1920 && it.height <= 1080 }
            .maxByOrNull { it.width * it.height }
            ?: choices.first()
    }

    private fun configureTransform(viewWidth: Int, viewHeight: Int) {
        if (viewWidth <= 0 || viewHeight <= 0 || !::textureView.isInitialized) return
        val matrix = Matrix()
        val viewAspect = viewWidth.toFloat() / viewHeight.toFloat()
        // Camera sensor in portrait screen reports rotated dimensions (height x width).
        val bufferWidth = previewSize.height.toFloat()
        val bufferHeight = previewSize.width.toFloat()
        val bufferAspect = bufferWidth / bufferHeight

        var scaleX = 1f
        var scaleY = 1f
        if (viewAspect > bufferAspect) {
            scaleY = (viewWidth / bufferAspect) / viewHeight
        } else {
            scaleX = (viewHeight * bufferAspect) / viewWidth
        }
        matrix.setScale(scaleX, scaleY, viewWidth / 2f, viewHeight / 2f)
        textureView.setTransform(matrix)
    }

    private fun buildContentView(): View {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }
        textureView = TextureView(this)
        root.addView(
            textureView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(0x88000000.toInt())
            val padH = dp(16)
            val padTop = dp(42)
            val padBottom = dp(14)
            setPadding(padH, padTop, padH, padBottom)
        }
        val closeBtn = Button(this).apply {
            text = "✕ 关闭"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.TRANSPARENT)
            setOnClickListener {
                setResult(RESULT_CANCELED)
                finish()
            }
        }
        titleView = TextView(this).apply {
            text = if (batchMode) "连续批量扫码 (0)" else "扫码绑定号码"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            gravity = Gravity.CENTER
        }
        topBar.addView(closeBtn)
        topBar.addView(
            titleView,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        root.addView(
            topBar,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            ),
        )

        frameBox = View(this).apply {
            background = viewfinderDrawable(0xFF2FE096.toInt())
        }
        val boxSize = dp(250)
        root.addView(
            frameBox,
            FrameLayout.LayoutParams(boxSize, boxSize, Gravity.CENTER),
        )

        val bottomContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }

        hintView = TextView(this).apply {
            text = if (batchMode) {
                "依次将多个配网二维码放入框内，全部扫完后点击完成导入"
            } else {
                "将配网二维码放入框内，自动识别绑定"
            }
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            gravity = Gravity.CENTER
            setBackgroundColor(0x88000000.toInt())
            val pH = dp(20)
            val pV = dp(12)
            setPadding(pH, pV, pH, pV)
        }
        bottomContainer.addView(
            hintView,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )

        if (batchMode) {
            val actionsRow = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                setPadding(dp(16), dp(12), dp(16), 0)
            }
            val undo = Button(this).apply {
                text = "撤销上一个"
                isEnabled = false
                setTextColor(Color.WHITE)
                background = GradientDrawable().apply {
                    cornerRadius = dp(24).toFloat()
                    setColor(0xAA333333.toInt())
                }
                val pH = dp(16)
                val pV = dp(8)
                setPadding(pH, pV, pH, pV)
                setOnClickListener {
                    var remaining = 0
                    synchronized(scanLock) {
                        val last = scannedItems.lastOrNull()
                        if (last != null) {
                            scannedItems.remove(last)
                        }
                        remaining = scannedItems.size
                    }
                    updateBatchUi(
                        remaining,
                        status = if (remaining > 0) {
                            "已撤销上一个，当前已扫 $remaining 个"
                        } else {
                            "已清空队列，请对准二维码开始扫描"
                        },
                    )
                }
            }
            val done = Button(this).apply {
                text = "完成导入 (0)"
                isEnabled = false
                setTextColor(Color.BLACK)
                background = GradientDrawable().apply {
                    cornerRadius = dp(24).toFloat()
                    setColor(0xFF2FE096.toInt())
                }
                val pH = dp(20)
                val pV = dp(8)
                setPadding(pH, pV, pH, pV)
                setOnClickListener {
                    val items = synchronized(scanLock) { ArrayList(scannedItems) }
                    if (items.isEmpty()) {
                        setResult(RESULT_CANCELED)
                    } else {
                        setResult(
                            RESULT_OK,
                            Intent().putStringArrayListExtra(EXTRA_SCAN_RESULTS, items),
                        )
                    }
                    finish()
                }
            }
            undoButton = undo
            doneButton = done
            batchBar = actionsRow
            actionsRow.addView(
                undo,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { rightMargin = dp(12) },
            )
            actionsRow.addView(
                done,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
            bottomContainer.addView(
                actionsRow,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
        }

        val hintParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
        ).apply {
            bottomMargin = dp(40)
            leftMargin = dp(16)
            rightMargin = dp(16)
        }
        root.addView(bottomContainer, hintParams)
        return root
    }

    private fun viewfinderDrawable(strokeColor: Int): GradientDrawable =
        GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(20).toFloat()
            setColor(0x1400E699)
            setStroke(dp(3), strokeColor)
        }

    private fun flashViewfinder(success: Boolean) {
        if (!::frameBox.isInitialized) return
        frameBox.background = viewfinderDrawable(
            if (success) 0xFF7CFAC2.toInt() else 0xFFFFB74D.toInt(),
        )
        frameBox.postDelayed({
            if (!isFinishing && !isDestroyed) {
                frameBox.background = viewfinderDrawable(0xFF2FE096.toInt())
            }
        }, 260L)
    }

    private fun updateBatchUi(count: Int, status: String) {
        if (::titleView.isInitialized) {
            titleView.text = "连续批量扫码 ($count)"
        }
        if (::hintView.isInitialized) {
            hintView.text = status
        }
        undoButton?.isEnabled = count > 0
        doneButton?.apply {
            text = "完成导入 ($count)"
            isEnabled = count > 0
        }
    }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics,
        ).toInt()
}

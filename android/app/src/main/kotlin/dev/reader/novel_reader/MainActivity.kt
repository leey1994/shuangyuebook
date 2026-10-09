package dev.reader.novel_reader

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 爽阅原生桥。
 *
 * 两条独立通道（同一通道上多次 setMethodCallHandler 会互相覆盖，必须分开）：
 *  - `dev.reader.novel_reader/native`：存储权限 / 常亮 / 目录 / 电量 / 装 APK / 打开链接 / TTS 设置
 *  - `dev.reader.novel_reader/open`  ：「用爽阅打开」文件关联（VIEW intent）
 */
class MainActivity : FlutterActivity() {

    private var nativeChannel: MethodChannel? = null
    private var openChannel: MethodChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    /** 冷启动时 Dart 尚未就绪，先把文件路径存下来等 Dart 来取。 */
    private var pendingOpenPath: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingOpenPath = resolveOpenIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // 热启动：App 已在运行，用户又用「打开方式」选了文件
        val path = resolveOpenIntent(intent)
        if (path != null) {
            pendingOpenPath = path
            notifyFileOpened(path)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        nativeChannel = MethodChannel(messenger, "dev.reader.novel_reader/native").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasStoragePermission" -> result.success(hasStoragePermission())
                    "requestStoragePermission" -> {
                        requestStoragePermission()
                        result.success(null)
                    }
                    "setKeepScreenOn" -> {
                        if (call.argument<Boolean>("value") == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "getStorageRoot" -> result.success(storageRoot())
                    "getDirs" -> result.success(
                        hashMapOf<String, String>(
                            "files" to filesDir.absolutePath,
                            "cache" to cacheDir.absolutePath
                        )
                    )
                    "getBattery" -> result.success(batteryStatus())
                    "openUrl" -> result.success(openUrl(call.argument<String>("url") ?: ""))
                    "openTtsSettings" -> result.success(openTtsSettings())
                    "installApk" -> result.success(installApk(call.argument<String>("path") ?: ""))
                    "canInstallApk" -> result.success(canInstallApk())
                    "openInstallPermission" -> {
                        openInstallPermission()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        openChannel = MethodChannel(messenger, "dev.reader.novel_reader/open").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart 就绪后来取冷启动文件（取后清除）
                    "getLaunchFile" -> {
                        val p = pendingOpenPath
                        pendingOpenPath = null
                        result.success(p)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // 热启动文件推送用独立 EventChannel：Dart 侧订阅后才开始收，
        // 避免冷启动时 Dart 还没挂上监听就丢事件。
        EventChannel(messenger, "dev.reader.novel_reader/open_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                    // 订阅瞬间补发一次：覆盖「Dart 已就绪但事件还没来」的窗口
                    pendingOpenPath?.let {
                        sink?.success(it)
                        pendingOpenPath = null
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    // ==================== 基础能力 ====================

    private fun storageRoot(): String =
        Environment.getExternalStorageDirectory()?.absolutePath ?: "/storage/emulated/0"

    private fun batteryStatus(): Map<String, Any> {
        val intent = registerReceiver(
            null as android.content.BroadcastReceiver?,
            android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED)
        )
        var level = -1
        var charging = false
        if (intent != null) {
            val l = intent.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1)
            val s = intent.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, -1)
            if (l >= 0 && s > 0) level = l * 100 / s
            val st = intent.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1)
            charging = st == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
                st == android.os.BatteryManager.BATTERY_STATUS_FULL
        }
        return hashMapOf("level" to level, "charging" to charging)
    }

    private fun openUrl(url: String): Boolean {
        if (url.isEmpty()) return false
        return try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun openTtsSettings(): Boolean = try {
        startActivity(
            Intent("android.settings.TTS_SETTINGS")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        true
    } catch (e: Exception) {
        false
    }

    // ==================== 自动更新：安装 APK ====================

    /**
     * 调起系统安装器安装指定路径的 APK。
     *
     * 必须走 FileProvider：Android 7.0+ 用 `file://` 分享安装包会抛
     * FileUriExposedException；统一用 `content://` + 临时读权限交给安装器。
     */
    private fun installApk(path: String): Boolean {
        if (path.isEmpty()) return false
        val file = File(path)
        if (!file.exists() || file.length() <= 0L) {
            android.util.Log.w("ShuangYue", "installApk: file missing or empty")
            return false
        }
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            android.util.Log.w("ShuangYue", "installApk failed", e)
            false
        }
    }

    /** Android 8.0+ 需要单独授权「安装未知来源应用」。 */
    private fun canInstallApk(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun openInstallPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            )
        } catch (e: Exception) {
            // 厂商 ROM 可能屏蔽该页，忽略即可（安装时会再次失败并提示）
        }
    }

    // ==================== 存储权限 ====================

    private fun hasStoragePermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    private fun requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+ 必须走「所有文件访问」授权页，没有运行时弹窗
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:$packageName")
                    )
                )
            } catch (e: Exception) {
                try {
                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                } catch (e2: Exception) {
                }
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            requestPermissions(
                arrayOf(
                    android.Manifest.permission.READ_EXTERNAL_STORAGE,
                    android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                ),
                1001
            )
        }
    }

    // ==================== 「用爽阅打开」文件关联 ====================

    /**
     * 解析 VIEW intent，返回可读路径：
     *  - `file://`   → 直接用该路径；
     *  - `content://`→ 复制到 App 缓存目录（缓存目录无需权限即可读）再返回。
     */
    private fun resolveOpenIntent(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        return try {
            val path = when (data.scheme) {
                "file" -> data.path
                "content" -> copyContentToCache(data)
                else -> null
            }
            if (!path.isNullOrEmpty()) {
                android.util.Log.i("ShuangYue", "open file: $path")
                path
            } else {
                null
            }
        } catch (e: Exception) {
            android.util.Log.w("ShuangYue", "open file failed", e)
            null
        }
    }

    private fun copyContentToCache(uri: Uri): String? {
        val name = queryDisplayName(uri) ?: "opened_file"
        val safe = name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        val target = File(cacheDir, "open/$safe")
        target.parentFile?.mkdirs()
        if (target.exists()) target.delete()
        contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        } ?: return null
        return target.absolutePath
    }

    private fun queryDisplayName(uri: Uri): String? = try {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
        }
    } catch (e: Exception) {
        null
    }

    private fun notifyFileOpened(path: String) {
        runOnUiThread {
            try {
                eventSink?.success(path)
            } catch (e: Exception) {
            }
        }
    }
}

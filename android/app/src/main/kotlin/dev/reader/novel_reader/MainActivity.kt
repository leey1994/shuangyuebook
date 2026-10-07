package dev.reader.novel_reader

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.reader.novel_reader/update"
        ).setMethodCallHandler { call, result ->
            if (call.method == "installApk") {
                // 自动更新：把下载好的 APK 交给系统安装器（FileProvider 授权读取）
                val path = call.argument<String>("path")
                try {
                    val f = File(path!!)
                    if (!f.exists() || f.length() == 0L) {
                        result.error("install", "APK 文件不存在或为空", null)
                        return@setMethodCallHandler
                    }
                    val uri = FileProvider.getUriForFile(
                        this, "$packageName.fileprovider", f
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("install", e.message, null)
                }
            } else if (call.method == "openTtsSettings") {
                // 方案 B：跳系统「文字转语音」设置页，引导安装台湾语音包
                try {
                    startActivity(
                        Intent("android.settings.TTS_SETTINGS")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.error("tts", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}

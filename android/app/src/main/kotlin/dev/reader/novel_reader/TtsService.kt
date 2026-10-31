package dev.reader.novel_reader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 听书前台服务：锁屏 / 通知栏显示「正在朗读」并提供 上一段 / 暂停 / 下一段 / 停止。
 *
 * 服务本身不合成音频（播放由 Flutter 侧负责），只负责两件事：
 *  - 前台保活：锁屏后进程不被系统回收（这是「锁屏听书」能继续的前提）；
 *  - 动作按钮 → 回调 Flutter（进程内静态回调，App 进程不存在时动作自然失效）。
 *
 * 完全本地运行：不做任何网络行为，退出听书即结束服务。
 */
class TtsService : Service() {

    companion object {
        /** 动作回调：MainActivity 在引擎就绪时注册。null = 无界面（忽略动作）。 */
        @Volatile
        var actionHandler: ((String) -> Unit)? = null

        const val ACTION_PREV = "dev.reader.novel_reader.tts.PREV"
        const val ACTION_TOGGLE = "dev.reader.novel_reader.tts.TOGGLE"
        const val ACTION_NEXT = "dev.reader.novel_reader.tts.NEXT"
        const val ACTION_STOP = "dev.reader.novel_reader.tts.STOP"

        private const val SHOW = "dev.reader.novel_reader.tts.SHOW"
        private const val CHANNEL_ID = "shuangyue_tts"
        private const val NOTIFICATION_ID = 106

        /** 开始 / 更新通知（同一条通知原地更新，不闪不响）。 */
        fun show(context: Context, title: String, text: String, playing: Boolean) {
            val i = Intent(context, TtsService::class.java).apply {
                action = SHOW
                putExtra("title", title)
                putExtra("text", text)
                putExtra("playing", playing)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TtsService::class.java))
        }
    }

    private var lastTitle = "爽阅"
    private var lastText = "正在朗读"
    private var lastPlaying = true

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PREV -> {
                actionHandler?.invoke("prev")
                return START_NOT_STICKY
            }
            ACTION_TOGGLE -> {
                actionHandler?.invoke("toggle")
                return START_NOT_STICKY
            }
            ACTION_NEXT -> {
                actionHandler?.invoke("next")
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                actionHandler?.invoke("stop")
                return START_NOT_STICKY
            }
            else -> {
                lastTitle = intent?.getStringExtra("title") ?: lastTitle
                lastText = intent?.getStringExtra("text") ?: lastText
                lastPlaying = intent?.getBooleanExtra("playing", true) ?: true
                ensureChannel()
                val n = buildNotification()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        n,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                    )
                } else {
                    startForeground(NOTIFICATION_ID, n)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "听书",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "听书播放控制（锁屏 / 通知栏）"
                setShowBadge(false)
            }
            nm.createNotificationChannel(ch)
        }
    }

    private fun buildNotification(): Notification {
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val contentPi = PendingIntent.getActivity(this, 0, launch, pendingFlags())

        fun action(action: String, icon: Int, label: String, code: Int):
            NotificationCompat.Action {
            val i = Intent(this, TtsService::class.java).setAction(action)
            val pi = PendingIntent.getService(this, code, i, pendingFlags())
            return NotificationCompat.Action(icon, label, pi)
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(lastTitle)
            .setContentText(lastText)
            .setContentIntent(contentPi)
            .setOngoing(lastPlaying)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(
                action(ACTION_PREV, android.R.drawable.ic_media_previous, "上一句", 1)
            )
            .addAction(
                action(
                    ACTION_TOGGLE,
                    if (lastPlaying) android.R.drawable.ic_media_pause
                    else android.R.drawable.ic_media_play,
                    if (lastPlaying) "暂停" else "继续",
                    2
                )
            )
            .addAction(
                action(ACTION_NEXT, android.R.drawable.ic_media_next, "下一句", 3)
            )
            .addAction(
                action(ACTION_STOP, android.R.drawable.ic_menu_close_clear_cancel, "停止", 4)
            )
            .build()
    }

    private fun pendingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

    @Suppress("DEPRECATION")
    override fun onDestroy() {
        try {
            stopForeground(true)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}

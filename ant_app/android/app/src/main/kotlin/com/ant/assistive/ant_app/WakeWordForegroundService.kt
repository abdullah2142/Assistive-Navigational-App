package com.ant.assistive.ant_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Does nothing on its own — no audio code lives here. Its only job is to be
 * a foreground [Service] with an ongoing notification, which is what stops
 * Android from freezing or killing this app's process once the user
 * backgrounds the app or locks the screen. As long as the process stays
 * alive, the Flutter engine (and the Dart isolate already running
 * `WakeWordService`'s continuous mic stream + TFLite inference inside it)
 * keeps running right where it was — this service doesn't touch it.
 *
 * Started/stopped from Dart via [MainActivity]'s method channel, tied to
 * app lifecycle (background) and `UserProfile.wakeWordEnabled` — see
 * `BackgroundListeningService` on the Dart side.
 *
 * A partial wake lock is held alongside the foreground notification: the
 * notification alone keeps the *process* from being killed, but the CPU can
 * still be suspended once the screen turns off, which would stall the mic
 * stream mid-utterance — the wake lock is what keeps the CPU itself awake.
 */
class WakeWordForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        if (wakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ant:wakeword").apply {
                setReferenceCounted(false)
            }
        }
        // Renewed on every (re-)start rather than held open-endedly — a
        // capped duration is a safety net against a wake lock silently
        // surviving a crash/leak and draining the battery for good, not a
        // real limit on how long background listening can run (the app
        // re-issues `start` from Dart well within this window whenever
        // wake-word stays enabled).
        wakeLock?.let { if (!it.isHeld) it.acquire(6 * 60 * 60 * 1000L) }
        return START_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun buildNotification(): android.app.Notification {
        ensureChannel()
        return NotificationCompat.Builder(this, CHANNEL_ID).apply {
            setContentTitle(NOTIFICATION_TITLE)
            setContentText(NOTIFICATION_BODY)
            setSmallIcon(android.R.drawable.ic_btn_speak_now)
            setOngoing(true)
            setPriority(NotificationCompat.PRIORITY_LOW)
            setCategory(NotificationCompat.CATEGORY_SERVICE)
        }.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "ANT wake-word listening", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Keeps \"Hey ANT\" listening active while the app is in the background"
            }
        )
    }

    companion object {
        const val NOTIFICATION_ID = 4201
        const val CHANNEL_ID = "ant_wakeword_channel"
        const val NOTIFICATION_TITLE = "ANT is listening"
        const val NOTIFICATION_BODY = "Say \"Hey ANT\" anytime, even with the app in the background"
    }
}

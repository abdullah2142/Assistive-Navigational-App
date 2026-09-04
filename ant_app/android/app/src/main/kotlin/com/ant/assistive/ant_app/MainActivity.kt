package com.ant.assistive.ant_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Registers [CHANNEL] so the Dart side (`BackgroundListeningService`) can
 * start/stop [WakeWordForegroundService] — see that service's doc comment
 * for what it actually does and why (it holds no audio code of its own; the
 * point is purely keeping this process alive while backgrounded so the
 * Dart-side wake-word listener already running keeps running).
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.ant.assistive.ant_app/background_listening"
        private const val NOTIFICATION_PERMISSION_REQUEST = 4201
    }

    /**
     * Android 13+ (API 33) made POST_NOTIFICATIONS a runtime permission.
     * It was declared in the manifest but never actually requested, so on
     * any modern device the foreground service's ongoing notification
     * silently never appeared — and an invisible foreground service is
     * precisely what aggressive OEM battery managers (MIUI especially, the
     * device this is being tested on) kill first. Requested when background
     * listening is about to start rather than at launch, so the prompt
     * arrives with a reason the user can connect it to instead of cold on
     * first open.
     */
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ensureNotificationPermission()
                    val intent = Intent(this, WakeWordForegroundService::class.java)
                    ContextCompat.startForegroundService(this, intent)
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, WakeWordForegroundService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}

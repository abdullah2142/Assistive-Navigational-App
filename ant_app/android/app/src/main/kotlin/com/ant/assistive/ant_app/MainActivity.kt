package com.ant.assistive.ant_app

import android.content.Intent
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
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
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

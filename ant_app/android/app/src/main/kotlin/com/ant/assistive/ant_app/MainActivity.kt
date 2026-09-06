package com.ant.assistive.ant_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
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

        /**
         * How long Volume Down must be held to be a Magic Button press.
         *
         * Three seconds, from the module plan. Long enough that turning the
         * volume down never triggers it; short enough to hold while
         * frightened.
         */
        private const val SOS_HOLD_MS = 3000L
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

    private var emergencyChannel: MethodChannel? = null
    private val holdHandler = Handler(Looper.getMainLooper())
    private var holdArmed = false

    /**
     * Volume Down held for [SOS_HOLD_MS] triggers the Magic Button.
     *
     * A screen button is useless to someone who cannot see it and is
     * panicking, so the primary trigger is physical.
     *
     * The event is **observed, not consumed**. An earlier version swallowed
     * it so that asking for help would not also turn the volume down — which
     * sounded considerate and was in fact a regression for every user of the
     * app, not just this feature: holding Volume Down is how people lower
     * the volume, and consuming it meant the volume no longer moved while
     * held and then fired an SOS. Volume behaves exactly as Android intends
     * it to; the hold is timed alongside.
     *
     * One limit worth knowing rather than discovering: Android only delivers
     * key events to the **foregrounded** activity, so this works while the
     * app is open — which, mid-navigation, it is — and not with the screen
     * off. The voice trigger covers that case.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN && event.repeatCount == 0 && !holdArmed) {
            // repeatCount == 0 is the initial press; the auto-repeats that
            // follow are what Android uses to keep lowering the volume, and
            // they must reach it.
            holdArmed = true
            holdHandler.postDelayed({
                if (holdArmed) {
                    holdArmed = false
                    emergencyChannel?.invokeMethod("sosHeld", null)
                }
            }, SOS_HOLD_MS)
        }
        // Always falls through: the volume is the system's to change.
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            holdArmed = false
            holdHandler.removeCallbacksAndMessages(null)
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun onDestroy() {
        holdHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val emergency = EmergencyBridge(this)
        emergencyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EmergencyBridge.CHANNEL,
        ).apply { setMethodCallHandler { call, result -> emergency.handle(call, result) } }
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

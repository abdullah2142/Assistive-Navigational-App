package com.ant.assistive.ant_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.HapticFeedbackConstants
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

        /**
         * How long after the last auto-repeat the key is still assumed down.
         *
         * Android's volume repeat interval is tens of milliseconds, so this is
         * generous by an order of magnitude — it is here to tolerate a slow or
         * briefly stalled repeat stream, not to time anything.
         */
        private const val REPEAT_GRACE_MS = 700L

        /** Module 6's channel — the Snapshot Vision sweep trigger. */
        private const val VISION_CHANNEL = "com.ant.assistive.ant_app/vision"

        /**
         * How long Volume **Up** must be held to start a Stationary Sweep.
         *
         * Two seconds, and the number is chosen the same way [SOS_HOLD_MS]
         * is: long enough that using the key for its actual purpose never
         * triggers it. Holding Volume Up saturates at maximum volume inside
         * about a second on every Android device, after which continuing to
         * hold does nothing a user would keep doing — so a two-second hold
         * is a gesture nobody performs by accident while adjusting volume.
         *
         * Volume Down was not available: Module 9 owns it, and the Magic
         * Button must not have a competing meaning.
         *
         * A hold rather than a press or a double-press is deliberate. Single
         * and repeated presses are exactly how volume is normally changed —
         * somebody raising the volume three steps taps three times in under
         * a second — so any press-count gesture would fire constantly.
         *
         * The two seconds cost is real and is spent on the right trigger:
         * this fires the *sweep*, which is not racing anything. "What bus is
         * this", which is, stays on the voice and chip paths where it starts
         * capturing immediately.
         */
        private const val SWEEP_HOLD_MS = 2000L
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
    private var visionChannel: MethodChannel? = null
    private val holdHandler = Handler(Looper.getMainLooper())
    private var holdArmed = false

    /** Volume Up hold state — the same three fields, for the sweep trigger. */
    private val sweepHandler = Handler(Looper.getMainLooper())
    private var sweepArmed = false
    private var sweepSawRepeat = false
    private var sweepLastKeyDownAt = 0L

    /// Whether this device delivered any auto-repeat during the current hold,
    /// and when the last one arrived. See [fireIfStillHeld].
    private var sawRepeat = false
    private var lastKeyDownAt = 0L

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
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (event.repeatCount == 0 && !holdArmed) {
                holdArmed = true
                sawRepeat = false
                lastKeyDownAt = SystemClock.elapsedRealtime()
                // Say that the press landed, immediately.
                //
                // There was no feedback at all until the SOS fired three
                // seconds later, so a user holding the key had no way to tell
                // it from a key that had not registered — and the natural
                // response to that is to keep holding and then report that it
                // "takes more than 3 seconds". A tick at the start costs
                // nothing and answers the only question they have.
                window?.decorView?.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                holdHandler.postDelayed({ fireIfStillHeld() }, SOS_HOLD_MS)
            } else if (holdArmed) {
                // Auto-repeats while the key stays down. These are the
                // liveness signal — see [fireIfStillHeld].
                sawRepeat = true
                lastKeyDownAt = SystemClock.elapsedRealtime()
            }
        } else if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (event.repeatCount == 0 && !sweepArmed) {
                sweepArmed = true
                sweepSawRepeat = false
                sweepLastKeyDownAt = SystemClock.elapsedRealtime()
                window?.decorView?.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                sweepHandler.postDelayed({ fireSweepIfStillHeld() }, SWEEP_HOLD_MS)
            } else if (sweepArmed) {
                sweepSawRepeat = true
                sweepLastKeyDownAt = SystemClock.elapsedRealtime()
            }
        }
        // Always falls through: the volume is the system's to change.
        return super.onKeyDown(keyCode, event)
    }

    /**
     * The Volume Up twin of [fireIfStillHeld], and it uses the identical
     * repeat-liveness rule for the identical reason: the volume panel takes
     * focus on some ROMs (MIUI among them, which is what this is tested on),
     * so judging liveness from window focus cancels the hold with the very UI
     * the hold summons. See [fireIfStillHeld] for the full account.
     */
    private fun fireSweepIfStillHeld() {
        if (!sweepArmed) return
        val quiet = SystemClock.elapsedRealtime() - sweepLastKeyDownAt
        if (sweepSawRepeat && quiet > REPEAT_GRACE_MS) {
            sweepArmed = false
            return
        }
        sweepArmed = false
        visionChannel?.invokeMethod("sweepHeld", null)
    }

    /**
     * Fires the SOS only if the key still appears to be down.
     *
     * Liveness is judged from the key's own auto-repeats rather than from
     * window focus, and that is the fix. The previous version disarmed on any
     * focus loss, which is correct for an incoming call and wrong for the
     * thing that happens every single time: holding Volume Down raises the
     * system volume panel, and on some ROMs — MIUI among them, which is what
     * this is tested on — that panel takes focus. The hold was being cancelled
     * by the very UI the hold summons, so the SOS never fired and the user
     * kept holding.
     *
     * Repeats survive that, because Android keeps delivering them to the
     * activity while the key is physically down.
     *
     * The fallback matters as much as the rule: if no repeat ever arrived,
     * this device does not auto-repeat volume keys, and demanding one would
     * mean the Magic Button never works there at all. In that case fall back
     * to the older test — armed, and no key-up seen.
     */
    private fun fireIfStillHeld() {
        if (!holdArmed) return
        val quiet = SystemClock.elapsedRealtime() - lastKeyDownAt
        if (sawRepeat && quiet > REPEAT_GRACE_MS) {
            // Repeats stopped well before the window closed: the key went up
            // somewhere this activity could not hear it.
            holdArmed = false
            return
        }
        holdArmed = false
        emergencyChannel?.invokeMethod("sosHeld", null)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) disarmHold()
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) disarmSweep()
        return super.onKeyUp(keyCode, event)
    }

    private fun disarmHold() {
        holdArmed = false
        sawRepeat = false
        holdHandler.removeCallbacksAndMessages(null)
    }

    private fun disarmSweep() {
        sweepArmed = false
        sweepSawRepeat = false
        sweepHandler.removeCallbacksAndMessages(null)
    }

    /**
     * Deliberately no longer disarms on focus loss.
     *
     * That is what the volume panel trips. A press abandoned against a call
     * screen is caught by [fireIfStillHeld] instead, which notices the
     * repeats stopping — and `onPause` below still covers a real
     * backgrounding.
     */
    override fun onPause() {
        disarmHold()
        super.onPause()
    }

    override fun onDestroy() {
        disarmHold()
        emergencyChannel = null
        visionChannel = null
        sweepHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val emergency = EmergencyBridge(this)
        emergencyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EmergencyBridge.CHANNEL,
        ).apply { setMethodCallHandler { call, result -> emergency.handle(call, result) } }

        // Outbound only — Dart never calls into this one, it only listens for
        // `sweepHeld`. No handler is registered for that reason.
        visionChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VISION_CHANNEL)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ensureNotificationPermission()
                    val intent = Intent(this, WakeWordForegroundService::class.java)
                    // Reported as an error rather than thrown past Flutter.
                    //
                    // Android 12 (API 31) forbids starting a foreground service
                    // from the background, and this is called from Dart on
                    // `AppLifecycleState.paused` — the moment the screen locks,
                    // which is exactly the boundary that restriction polices. If
                    // it is refused, the process is never kept alive, the
                    // wake-word recorder is frozen with it, and nothing says so:
                    // `BackgroundListeningService.start()` swallowed the failure
                    // into a debugPrint. "Screen off doesn't work, eyes closed
                    // works" and "no vibration either" are both what that looks
                    // like from the outside (open_bugs item 31).
                    //
                    // Naming the exception is the point. It turns a silent
                    // nothing into one line of logcat that says which of the
                    // candidate causes it actually is.
                    try {
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error(
                            "foreground_service_start_failed",
                            "${e.javaClass.simpleName}: ${e.message}",
                            null,
                        )
                    }
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

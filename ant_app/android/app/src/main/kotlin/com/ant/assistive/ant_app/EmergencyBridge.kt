package com.ant.assistive.ant_app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The parts of the Magic Button that Flutter cannot do.
 *
 * Sending an SMS without opening the messaging app, placing a call without
 * opening the dialler, and reading the battery level all need platform
 * APIs. Everything about *what* to send lives in Dart
 * (`emergency_payload.dart`) where it is testable; this file is kept as
 * thin as it can be, because nothing here can be covered by a widget test.
 *
 * ## Why silent dispatch
 *
 * An `sms:` intent would need no permission at all, and is what most apps
 * do. It also opens the messaging app pre-filled and waits for someone to
 * find and press send. A blind user who has just held the volume key for
 * three seconds because something is wrong cannot do that, and if they
 * could, they would not have needed a Magic Button. The permission cost is
 * real and is discussed in the manifest; the alternative is a feature that
 * does not work for the person it exists for.
 */
class EmergencyBridge(private val activity: Activity) {

    companion object {
        const val CHANNEL = "com.ant.assistive.ant_app/emergency"
        const val PERMISSION_REQUEST = 4202

        private val REQUIRED = arrayOf(
            Manifest.permission.SEND_SMS,
            Manifest.permission.CALL_PHONE,
        )
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermissions" -> result.success(hasPermissions())
            "requestPermissions" -> {
                // Fire-and-forget: the Dart side re-checks `hasPermissions`
                // rather than waiting on a callback, because the emergency
                // path must never block on a dialog that may never be
                // answered.
                ActivityCompat.requestPermissions(activity, REQUIRED, PERMISSION_REQUEST)
                result.success(null)
            }
            "batteryPercent" -> result.success(batteryPercent())
            "sendSms" -> sendSms(call, result)
            "placeCall" -> placeCall(call, result)
            else -> result.notImplemented()
        }
    }

    private fun hasPermissions(): Boolean = REQUIRED.all {
        ContextCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED
    }

    /** Battery percentage, or null when the platform will not say. */
    private fun batteryPercent(): Int? {
        return try {
            val manager = activity.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            val level = manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            // The API returns Integer.MIN_VALUE rather than throwing when it
            // has no reading. Reporting that as a percentage would put
            // "battery -2147483648%" in an emergency SMS.
            if (level in 0..100) level else null
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Sends one message to each recipient.
     *
     * Reports per-recipient success rather than a single boolean: a contact
     * whose number was mistyped during onboarding must not make the app
     * report a total failure when three other people were reached, and the
     * Dart side needs to know which of those two happened in order to say
     * something true out loud.
     */
    private fun sendSms(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermissions()) {
            result.error("permission_denied", "SEND_SMS has not been granted", null)
            return
        }
        val recipients = call.argument<List<String>>("recipients").orEmpty()
        val messages = call.argument<List<String>>("messages").orEmpty()
        if (recipients.isEmpty() || messages.isEmpty()) {
            result.error("invalid_arguments", "recipients and messages are both required", null)
            return
        }

        val manager: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }

        val delivered = mutableListOf<String>()
        val failed = mutableMapOf<String, String>()
        for (number in recipients) {
            try {
                for (body in messages) {
                    // divideMessage + sendMultipartTextMessage rather than
                    // sendTextMessage: the Dart side works hard to keep each
                    // message inside one part, but a name or a locale we did
                    // not anticipate must degrade into a split message rather
                    // than into a silently truncated one.
                    val parts = manager.divideMessage(body)
                    if (parts.size == 1) {
                        manager.sendTextMessage(number, null, body, null, null)
                    } else {
                        manager.sendMultipartTextMessage(number, null, parts, null, null)
                    }
                }
                delivered.add(number)
            } catch (e: Exception) {
                failed[number] = e.message ?: e.javaClass.simpleName
            }
        }
        result.success(mapOf("delivered" to delivered, "failed" to failed))
    }

    /**
     * Places a call to the primary contact.
     *
     * `ACTION_CALL`, not `ACTION_DIAL`: dial merely opens the dialler with
     * the number filled in and waits to be pressed, which is the same
     * problem as the SMS intent. Speakerphone is not forced here — Android
     * gives an app no supported way to do that for a normal cellular call,
     * and the plan's expectation of it is not achievable without a
     * privileged permission.
     */
    private fun placeCall(call: MethodCall, result: MethodChannel.Result) {
        val number = call.argument<String>("number")
        if (number.isNullOrBlank()) {
            result.error("invalid_arguments", "number is required", null)
            return
        }
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CALL_PHONE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            result.error("permission_denied", "CALL_PHONE has not been granted", null)
            return
        }
        return try {
            val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$number")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("call_failed", e.message, null)
        }
    }
}

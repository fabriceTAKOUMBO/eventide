package be.cinaf.eventide

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Re-arms the next scheduled start after a reboot, a clock or time zone change, an app update, or a change of the exact-alarm permission. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED,
            -> {
                Notifications.ensureChannels(context.applicationContext)
                ScheduleStore.arm(context.applicationContext)
            }
        }
    }
}

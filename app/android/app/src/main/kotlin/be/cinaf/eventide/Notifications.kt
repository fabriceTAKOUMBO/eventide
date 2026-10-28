package be.cinaf.eventide

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Reminder notifications posted by native code (no Flutter engine needed):
 * the fallback « Lancer » notification when Android refuses to start the audio service from the
 * background, and « Pas de connexion » for a free user without network at the scheduled time.
 * The media notification itself is owned by audio_service.
 */
object Notifications {
    const val CHANNEL_REMINDERS = "eventide_reminders"
    const val CHANNEL_INFO = "eventide_info"

    const val ID_SCHEDULE_FALLBACK = 2101
    const val ID_NO_CONNECTION = 2102

    const val ACTION_LAUNCH_SCHEDULE = "be.cinaf.eventide.action.LAUNCH_SCHEDULE"
    const val EXTRA_SCHEDULE_ID = "schedule_id"

    private const val REQUEST_LAUNCH = 4301
    private const val REQUEST_OPEN = 4302

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_REMINDERS) == null) {
            // Visible but silent: nothing should ring in the evening (dossier, principle 5).
            val reminders = NotificationChannel(
                CHANNEL_REMINDERS,
                context.getString(R.string.channel_reminders_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            )
            reminders.description = context.getString(R.string.channel_reminders_description)
            reminders.setSound(null, null)
            reminders.enableVibration(false)
            manager.createNotificationChannel(reminders)
        }
        if (manager.getNotificationChannel(CHANNEL_INFO) == null) {
            val info = NotificationChannel(
                CHANNEL_INFO,
                context.getString(R.string.channel_info_name),
                NotificationManager.IMPORTANCE_LOW,
            )
            info.description = context.getString(R.string.channel_info_description)
            manager.createNotificationChannel(info)
        }
    }

    private fun canPost(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    private fun openAppIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            REQUEST_OPEN,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** « C’est l’heure d’aller dormir » with a « Lancer » action that opens the app and starts the schedule. */
    @SuppressLint("MissingPermission") // checked in canPost()
    fun showScheduleFallback(context: Context, schedule: StoredSchedule): Boolean {
        ensureChannels(context)
        if (!canPost(context)) return false
        val launch = Intent(context, MainActivity::class.java)
            .setAction(ACTION_LAUNCH_SCHEDULE)
            .putExtra(EXTRA_SCHEDULE_ID, schedule.id)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val launchPending = PendingIntent.getActivity(
            context,
            REQUEST_LAUNCH,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = context.getString(
            if (schedule.reminder == "detente") R.string.reminder_relax_title else R.string.reminder_sleep_title,
        )
        val text = if (schedule.landscapeName.isNotEmpty()) {
            context.getString(R.string.reminder_text_with_landscape, schedule.landscapeName)
        } else {
            context.getString(R.string.reminder_text)
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_REMINDERS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setSilent(true)
            .setAutoCancel(true)
            .setContentIntent(launchPending)
            .addAction(0, context.getString(R.string.reminder_action_launch), launchPending)
            .build()
        return try {
            NotificationManagerCompat.from(context).notify(ID_SCHEDULE_FALLBACK, notification)
            true
        } catch (e: SecurityException) {
            false
        }
    }

    /** « Pas de connexion »: free user without network at the scheduled time. */
    @SuppressLint("MissingPermission") // checked in canPost()
    fun showNoConnection(context: Context): Boolean {
        ensureChannels(context)
        if (!canPost(context)) return false
        val notification = NotificationCompat.Builder(context, CHANNEL_REMINDERS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.no_connection_title))
            .setContentText(context.getString(R.string.no_connection_text))
            .setStyle(NotificationCompat.BigTextStyle().bigText(context.getString(R.string.no_connection_text)))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setSilent(true)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(context))
            .build()
        return try {
            NotificationManagerCompat.from(context).notify(ID_NO_CONNECTION, notification)
            true
        } catch (e: SecurityException) {
            false
        }
    }

    fun cancelFallback(context: Context) {
        NotificationManagerCompat.from(context).cancel(ID_SCHEDULE_FALLBACK)
    }
}

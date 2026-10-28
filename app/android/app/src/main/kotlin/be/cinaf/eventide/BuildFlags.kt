package be.cinaf.eventide

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build

/**
 * Build-time flags written into the manifest by app/build.gradle.kts.
 *
 * DEMO_BUILD is true only in the « Eventide Démo » package (Gradle property eventide.demo=true,
 * application id be.cinaf.eventide.demo). Dart turns demo mode on only when this flag AND its
 * own DEMO_MODE dart-define agree (lib/app/demo_mode.dart).
 */
object BuildFlags {
    private const val META_DEMO_BUILD = "be.cinaf.eventide.DEMO_BUILD"

    fun isDemoBuild(context: Context): Boolean {
        try {
            val metaData = applicationInfo(context).metaData ?: return false
            @Suppress("DEPRECATION")
            val value: Any? = metaData.get(META_DEMO_BUILD)
            // aapt2 stores android:value="true" as a boolean; accept a string too.
            return value == true || value == "true"
        } catch (e: Exception) {
            return false
        }
    }

    private fun applicationInfo(context: Context): ApplicationInfo {
        val pm = context.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getApplicationInfo(
                context.packageName,
                PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            pm.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
        }
    }
}

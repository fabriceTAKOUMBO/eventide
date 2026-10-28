package be.cinaf.eventide

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/** Coarse network state. Dart still confirms "online" with a real request (dossier, screen 13). */
object NetworkStatus {
    fun isConnected(context: Context): Boolean = capabilities(context)
        ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true

    fun isUnmetered(context: Context): Boolean {
        val caps = capabilities(context) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }

    private fun capabilities(context: Context): NetworkCapabilities? {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val network = cm.activeNetwork ?: return null
        return cm.getNetworkCapabilities(network)
    }
}

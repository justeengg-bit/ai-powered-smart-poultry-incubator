package com.eggcandling.application_v2

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.eggcandling.egg_candling_app/platform_bridge"
    private val TAG = "EggCandlingNative"
    private val incubatorSsid = "AI_CANDLING"
    private val incubatorPassword = "thesis123"
    private val mainHandler = Handler(Looper.getMainLooper())

    private var platformChannel: MethodChannel? = null
    private var incubatorNetwork: Network? = null
    private var incubatorNetworkBound = false
    private var incubatorConcurrentInternetSupported = false
    private var incubatorNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var pendingConnectionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        platformChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        platformChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "connectIncubatorHub" -> {
                    requestIncubatorNetwork(result)
                }
                "releaseIncubatorHub" -> {
                    releaseIncubatorNetwork()
                    result.success(incubatorConnectionPayload("released", false))
                }
                "getIncubatorHubStatus" -> {
                    val connected = incubatorNetwork != null && incubatorNetworkBound
                    result.success(
                        incubatorConnectionPayload(
                            if (connected) "connected" else "disconnected",
                            incubatorNetworkBound,
                            concurrentSupported = incubatorConcurrentInternetSupported,
                        )
                    )
                }
                "openWifiSettings" -> {
                    openWifiSettings()
                    result.success(null)
                }
                "savePdfToDocuments" -> {
                    val fileName = call.argument<String>("fileName") ?: "Candling_report.pdf"
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("INVALID_ARGS", "bytes required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val savedPath = savePdfToDocuments(fileName, bytes)
                        result.success(savedPath)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to save PDF", e)
                        result.error("SAVE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        releaseIncubatorNetwork()
        platformChannel?.setMethodCallHandler(null)
        platformChannel = null
        super.onDestroy()
    }

    private fun openWifiSettings() {
        val intent = Intent(Settings.ACTION_WIFI_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun savePdfToDocuments(fileName: String, bytes: ByteArray): String {
        val safeName = fileName
            .replace(Regex("[\\\\/:*?\"<>|]"), "_")
            .ifBlank { "Candling_report.pdf" }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOCUMENTS + "/Candling"
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = applicationContext.contentResolver
            val uri = resolver.insert(MediaStore.Files.getContentUri("external"), values)
                ?: throw IllegalStateException("Could not create PDF file")

            resolver.openOutputStream(uri)?.use { stream ->
                stream.write(bytes)
            } ?: throw IllegalStateException("Could not open PDF output stream")

            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Saved to Documents/Candling/$safeName"
        }

        val dir = java.io.File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
            "Candling"
        )
        if (!dir.exists()) dir.mkdirs()
        val file = java.io.File(dir, safeName)
        file.writeBytes(bytes)
        return "Saved to ${file.absolutePath}"
    }

    private fun requestIncubatorNetwork(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            openWifiSettings()
            result.success(
                incubatorConnectionPayload(
                    "settings_required",
                    false,
                    "Android 9 or earlier requires a manual Wi-Fi connection.",
                )
            )
            return
        }

        if (!hasWifiRequestPermission()) {
            result.error(
                "WIFI_PERMISSION_REQUIRED",
                "Nearby Wi-Fi and location permission are required.",
                null,
            )
            return
        }

        incubatorNetwork?.let { network ->
            val connectivity = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val bound = connectivity.bindProcessToNetwork(network)
            incubatorNetworkBound = bound
            result.success(
                incubatorConnectionPayload(
                    if (bound) "connected" else "unavailable",
                    bound,
                    if (bound) null else "Android could not route the app to $incubatorSsid.",
                    incubatorConcurrentInternetSupported,
                )
            )
            return
        }

        if (pendingConnectionResult != null) {
            result.success(
                incubatorConnectionPayload(
                    "requesting",
                    false,
                    "Android is already searching for $incubatorSsid.",
                )
            )
            return
        }

        val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        val connectivity = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val concurrentSupported =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                wifi.isStaConcurrencyForLocalOnlyConnectionsSupported
        incubatorConcurrentInternetSupported = concurrentSupported

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(incubatorSsid)
            .setWpa2Passphrase(incubatorPassword)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        pendingConnectionResult = result
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                incubatorNetwork = network
                val bound = connectivity.bindProcessToNetwork(network)
                incubatorNetworkBound = bound
                Log.i(
                    TAG,
                    "$incubatorSsid local-only network available; bound=$bound concurrent=$concurrentSupported",
                )
                completePendingConnection(
                    incubatorConnectionPayload(
                        if (bound) "connected" else "unavailable",
                        bound,
                        if (!bound) {
                            "Android connected, but could not route the app to $incubatorSsid."
                        } else if (concurrentSupported) {
                            "Incubator link held while the phone keeps its internet network."
                        } else {
                            "Incubator link held; mobile data may provide internet while connected."
                        },
                        concurrentSupported,
                    )
                )
                notifyIncubatorNetworkState(
                    if (bound) "connected" else "unavailable",
                    bound,
                    concurrentSupported,
                )
            }

            override fun onLost(network: Network) {
                if (incubatorNetwork != network) return
                incubatorNetwork = null
                incubatorNetworkBound = false
                connectivity.bindProcessToNetwork(null)
                Log.w(TAG, "$incubatorSsid local-only network lost")
                notifyIncubatorNetworkState("disconnected", false, concurrentSupported)
            }

            override fun onUnavailable() {
                Log.w(TAG, "$incubatorSsid local-only request unavailable")
                incubatorNetwork = null
                incubatorNetworkBound = false
                incubatorNetworkCallback = null
                connectivity.bindProcessToNetwork(null)
                completePendingConnection(
                    incubatorConnectionPayload(
                        "unavailable",
                        false,
                        "Could not find $incubatorSsid. Move closer and try again.",
                        concurrentSupported,
                    )
                )
                notifyIncubatorNetworkState("unavailable", false, concurrentSupported)
            }
        }

        incubatorNetworkCallback = callback
        try {
            connectivity.requestNetwork(request, callback, 45_000)
            Log.i(TAG, "Requested local-only network $incubatorSsid")
        } catch (e: Exception) {
            incubatorNetworkCallback = null
            pendingConnectionResult = null
            Log.e(TAG, "Failed to request $incubatorSsid", e)
            result.error("WIFI_REQUEST_FAILED", e.message, null)
        }
    }

    private fun hasWifiRequestPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun completePendingConnection(payload: Map<String, Any>) {
        mainHandler.post {
            pendingConnectionResult?.success(payload)
            pendingConnectionResult = null
        }
    }

    private fun notifyIncubatorNetworkState(
        status: String,
        bound: Boolean,
        concurrentSupported: Boolean,
    ) {
        mainHandler.post {
            platformChannel?.invokeMethod(
                "incubatorNetworkState",
                incubatorConnectionPayload(status, bound, null, concurrentSupported),
            )
        }
    }

    private fun incubatorConnectionPayload(
        status: String,
        bound: Boolean,
        message: String? = null,
        concurrentSupported: Boolean = false,
    ): Map<String, Any> = buildMap {
        put("status", status)
        put("ssid", incubatorSsid)
        put("bound", bound)
        put("concurrentInternetSupported", concurrentSupported)
        put("sdk", Build.VERSION.SDK_INT)
        if (message != null) put("message", message)
    }

    private fun releaseIncubatorNetwork() {
        val connectivity = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        incubatorNetworkCallback?.let { callback ->
            try {
                connectivity.unregisterNetworkCallback(callback)
            } catch (_: Exception) {
                // The callback may already have timed out or been released.
            }
        }
        incubatorNetworkCallback = null
        incubatorNetwork = null
        incubatorNetworkBound = false
        incubatorConcurrentInternetSupported = false
        pendingConnectionResult = null
        connectivity.bindProcessToNetwork(null)
        Log.i(TAG, "Released local-only incubator network request")
    }
}

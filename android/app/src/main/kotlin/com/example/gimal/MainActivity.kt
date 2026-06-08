package com.example.gimal

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val homeChannel = "com.example.gimal/home"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, homeChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "goHome") {
                    goHome()
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun goHome() {
        val intent = android.content.Intent(android.content.Intent.ACTION_MAIN).apply {
            addCategory(android.content.Intent.CATEGORY_HOME)
            flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK
        }

        startActivity(intent)
        moveTaskToBack(true)
    }
}

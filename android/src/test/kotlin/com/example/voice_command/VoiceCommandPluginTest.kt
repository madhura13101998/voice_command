package com.example.voice_command

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

internal class VoiceCommandPluginTest {
    @Test
    fun onMethodCall_isListening_returnsFalseInitially() {
        val plugin = VoiceCommandPlugin()
        val call = MethodCall("isListening", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)
        Mockito.verify(mockResult).success(false)
    }

    @Test
    fun onMethodCall_stopListening_succeedsWhenNotListening() {
        val plugin = VoiceCommandPlugin()
        val call = MethodCall("stopListening", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)
        Mockito.verify(mockResult).success(null)
    }

    @Test
    fun onMethodCall_pauseListening_succeedsWhenNotListening() {
        val plugin = VoiceCommandPlugin()
        val call = MethodCall("pauseListening", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)
        Mockito.verify(mockResult).success(null)
    }
}

package com.neuron.server

import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

object NetInfo {
    /** Alamat IPv4 LAN pertama yang aktif (bukan loopback). null jika tidak ada jaringan. */
    fun localIpv4(): String? = try {
        val ifaces = NetworkInterface.getNetworkInterfaces()?.let { Collections.list(it) } ?: emptyList()
        ifaces.filter { it.isUp && !it.isLoopback }
            .flatMap { Collections.list(it.inetAddresses) }
            .firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
            ?.hostAddress
    } catch (e: Exception) {
        null
    }
}

package com.neuron.engine

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Process
import java.io.File
import java.util.zip.ZipFile

class NativeReport(val problems: List<String>) {
    val ok: Boolean get() = problems.isEmpty()
    fun message(): String = problems.joinToString("\n")
}

/**
 * Validasi libneuron_llama.so sebelum model dimuat: apakah APK memuatnya, untuk ABI apa, apakah cocok dengan perangkat dan
 * proses ini, apakah hasil ekstraksinya ada dan berheader ELF yang benar, dan apakah System.loadLibrary berhasil.
 * Hasil di-cache per proses karena APK tidak berubah selama aplikasi berjalan.
 */
object NativeCheck {
    const val LIB = "libneuron_llama.so"
    @Volatile private var cached: NativeReport? = null

    fun inspect(ctx: Context): NativeReport {
        cached?.let { return it }
        val report = NativeReport(collectProblems(ctx.applicationContext))
        cached = report
        return report
    }

    private fun collectProblems(ctx: Context): List<String> {
        val problems = mutableListOf<String>()
        val info = ctx.applicationInfo
        val deviceAbis = Build.SUPPORTED_ABIS.toList()
        val apkAbis = apkAbis(info)

        if (apkAbis.isEmpty()) {
            problems += "APK ini tidak memuat $LIB. APK dibuild tanpa -PwithNative atau submodule llama.cpp kosong; bangun ulang dengan -PwithNative."
        } else if (deviceAbis.none { it in apkAbis }) {
            problems += "APK memuat native hanya untuk ${apkAbis.sorted()}, sedangkan perangkat ini mendukung $deviceAbis. Pakai perangkat arm64-v8a atau bangun native untuk ABI perangkat ini."
        }

        val lib = File(info.nativeLibraryDir ?: "", LIB)
        if (apkAbis.isNotEmpty()) {
            if (!lib.isFile) {
                problems += "$LIB ada di APK tetapi tidak terekstrak ke ${info.nativeLibraryDir}. Periksa packaging.jniLibs.useLegacyPackaging dan ruang penyimpanan."
            } else {
                val head = readHead(lib)
                val elf = head?.let { ElfInfo.parse(it) }
                if (elf == null) {
                    problems += "$LIB rusak (bukan berkas ELF yang valid, ${lib.length()} byte). Pasang ulang APK."
                } else {
                    val libAbi = elf.abi
                    if (libAbi == null || libAbi !in deviceAbis) {
                        problems += "$LIB berarsitektur ${libAbi ?: "tak dikenal (e_machine=${elf.machine})"}, tidak cocok dengan ABI perangkat $deviceAbis."
                    } else if (elf.is64Bit && !Process.is64Bit()) {
                        problems += "$LIB 64-bit, tetapi aplikasi berjalan sebagai proses 32-bit di perangkat ini."
                    }
                }
            }
        }

        if (!LlamaCppEngine.available) {
            problems += "System.loadLibrary(\"neuron_llama\") gagal: ${LlamaCppEngine.loadError ?: "penyebab tidak diketahui"}."
        }
        return problems
    }

    private fun readHead(f: File): ByteArray? = runCatching {
        f.inputStream().use { s ->
            val b = ByteArray(20)
            if (s.read(b) == 20) b else null
        }
    }.getOrNull()

    private fun apkAbis(info: ApplicationInfo): Set<String> {
        val paths = listOfNotNull(info.sourceDir) + (info.splitSourceDirs?.toList() ?: emptyList())
        val out = HashSet<String>()
        for (p in paths) {
            runCatching {
                ZipFile(p).use { zip ->
                    val entries = zip.entries()
                    while (entries.hasMoreElements()) {
                        val name = entries.nextElement().name
                        if (name.startsWith("lib/") && name.endsWith("/$LIB")) {
                            out += name.removePrefix("lib/").removeSuffix("/$LIB")
                        }
                    }
                }
            }
        }
        return out
    }
}

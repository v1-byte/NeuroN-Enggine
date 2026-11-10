package com.neuron.rag

/**
 * Penyimpanan vektor di RAM. Tidak ditulis ke disk, jadi indeks hilang saat aplikasi ditutup
 * dan dibangun ulang lewat tombol Indeks. Cocok untuk korpus kecil.
 */
class MemoryVectorStore : VectorStore {
    private class Entry(val hash: String, val items: List<Pair<String, FloatArray>>)

    private val bySource = LinkedHashMap<String, Entry>()
    private val metaMap = HashMap<String, String>()

    @Synchronized override fun replaceSource(source: String, hash: String, items: List<Pair<String, FloatArray>>) {
        bySource[source] = Entry(hash, items)
    }

    @Synchronized override fun search(q: FloatArray, k: Int): List<Hit> {
        val scored = ArrayList<Hit>()
        for ((source, entry) in bySource) {
            for ((text, vec) in entry.items) {
                if (vec.size != q.size) continue          // indeks dari model embedding lain
                scored += Hit(source, text, cosine(q, vec))
            }
        }
        return scored.sortedByDescending { it.score }.take(k)
    }

    @Synchronized override fun sourceHash(source: String): String? = bySource[source]?.hash
    @Synchronized override fun sources(): List<String> = bySource.keys.toList()
    @Synchronized override fun deleteSource(source: String) { bySource.remove(source) }
    @Synchronized override fun clear() { bySource.clear() }
    @Synchronized override fun count(): Int = bySource.values.sumOf { it.items.size }
    @Synchronized override fun meta(key: String): String? = metaMap[key]
    @Synchronized override fun setMeta(key: String, value: String) { metaMap[key] = value }
}

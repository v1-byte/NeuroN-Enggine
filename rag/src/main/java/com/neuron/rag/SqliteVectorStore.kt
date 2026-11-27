package com.neuron.rag

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.PriorityQueue

data class Hit(val source: String, val text: String, val score: Float)

interface VectorStore {
    /** Ganti seluruh isi `source` secara atomik. */
    fun replaceSource(source: String, hash: String, items: List<Pair<String, FloatArray>>)
    fun search(q: FloatArray, k: Int): List<Hit>
    fun sourceHash(source: String): String?
    fun sources(): List<String>
    fun deleteSource(source: String)
    fun clear()
    fun count(): Int
    fun meta(key: String): String?
    fun setMeta(key: String, value: String)
}

/** SQLite BLOB + cosine brute-force. Cukup untuk puluhan ribu chunk. TODO: HNSW / sqlite-vec. */
class SqliteVectorStore(ctx: Context, file: File) :
    SQLiteOpenHelper(ctx.applicationContext, file.also { it.parentFile?.mkdirs() }.absolutePath, null, 1), VectorStore {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE chunks(id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, idx INTEGER NOT NULL, text TEXT NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL)")
        db.execSQL("CREATE INDEX chunks_source ON chunks(source)")
        db.execSQL("CREATE TABLE sources(source TEXT PRIMARY KEY, hash TEXT NOT NULL, chunks INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL)")
    }
    override fun onUpgrade(db: SQLiteDatabase, o: Int, n: Int) {}

    private fun toBlob(v: FloatArray): ByteArray =
        ByteBuffer.allocate(v.size * 4).order(ByteOrder.LITTLE_ENDIAN).also { it.asFloatBuffer().put(v) }.array()
    private fun fromBlob(b: ByteArray, dim: Int): FloatArray =
        FloatArray(dim).also { ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(it) }

    @Synchronized override fun replaceSource(source: String, hash: String, items: List<Pair<String, FloatArray>>) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.delete("chunks", "source=?", arrayOf(source))
            items.forEachIndexed { i, (text, vec) ->
                db.insertOrThrow("chunks", null, ContentValues().apply {
                    put("source", source); put("idx", i); put("text", text); put("dim", vec.size); put("vec", toBlob(vec))
                })
            }
            db.insertWithOnConflict("sources", null, ContentValues().apply {
                put("source", source); put("hash", hash); put("chunks", items.size)
            }, SQLiteDatabase.CONFLICT_REPLACE)
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    /** Dua tahap: skor dihitung streaming (hanya id+vektor), teks hanya diambil untuk k teratas. */
    @Synchronized override fun search(q: FloatArray, k: Int): List<Hit> {
        val heap = PriorityQueue<Pair<Long, Float>>(k + 1, compareBy<Pair<Long, Float>> { it.second })   // min-heap
        readableDatabase.rawQuery("SELECT id, dim, vec FROM chunks", null).use { c ->
            while (c.moveToNext()) {
                val dim = c.getInt(1)
                if (dim != q.size) continue                       // indeks dari model embedding lain
                val s = cosine(q, fromBlob(c.getBlob(2), dim))
                if (heap.size < k) heap.add(c.getLong(0) to s)
                else if (s > heap.peek()!!.second) { heap.poll(); heap.add(c.getLong(0) to s) }
            }
        }
        return heap.sortedByDescending { it.second }.mapNotNull { (id, s) ->
            readableDatabase.rawQuery("SELECT source, text FROM chunks WHERE id=?", arrayOf(id.toString())).use {
                if (it.moveToFirst()) Hit(it.getString(0), it.getString(1), s) else null
            }
        }
    }

    @Synchronized override fun sourceHash(source: String): String? =
        readableDatabase.rawQuery("SELECT hash FROM sources WHERE source=?", arrayOf(source)).use { if (it.moveToFirst()) it.getString(0) else null }

    @Synchronized override fun sources(): List<String> =
        readableDatabase.rawQuery("SELECT source FROM sources", null).use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }

    @Synchronized override fun deleteSource(source: String) {
        val db = writableDatabase
        db.beginTransaction()
        try { db.delete("chunks", "source=?", arrayOf(source)); db.delete("sources", "source=?", arrayOf(source)); db.setTransactionSuccessful() }
        finally { db.endTransaction() }
    }

    @Synchronized override fun clear() {
        val db = writableDatabase
        db.beginTransaction()
        try { db.delete("chunks", null, null); db.delete("sources", null, null); db.setTransactionSuccessful() }
        finally { db.endTransaction() }
    }

    @Synchronized override fun count(): Int =
        readableDatabase.rawQuery("SELECT COUNT(*) FROM chunks", null).use { it.moveToFirst(); it.getInt(0) }

    @Synchronized override fun meta(key: String): String? =
        readableDatabase.rawQuery("SELECT v FROM meta WHERE k=?", arrayOf(key)).use { if (it.moveToFirst()) it.getString(0) else null }

    @Synchronized override fun setMeta(key: String, value: String) {
        writableDatabase.insertWithOnConflict("meta", null, ContentValues().apply { put("k", key); put("v", value) }, SQLiteDatabase.CONFLICT_REPLACE)
    }
}

package com.tokkah.kin.net

import java.util.concurrent.Semaphore

/**
 * Port of mac/Sources/tk/DecodeQueue.swift — get the video decoder off the
 * thread that receives audio.
 *
 * The phone had the same defect the Mac had, in the same place:
 * `onVideoFrame?.invoke(payload, cap)` ran inside the receive loop, so every
 * completed H.264 frame stopped audio from being received for as long as
 * MediaCodec took. Head-of-line blocking, and on the Mac it cost real latency on
 * every video call — measured, rotated arms, 120 s each:
 *
 *   video on   m2e p50 12.00 / 11.55   jit 6   arrival p99 1.64 max 7.99  late 14
 *   video off  m2e p50  9.89 /  9.98   jit 3   arrival p99 0.85 max 1.43  late 0
 *
 * The cadence instrument attributed it exactly: the SENDER's emission gaps were
 * identical in both arms, so nothing was delaying capture — audio was arriving
 * late, and the jitter buffer was right to grow. The buffer was treating a
 * symptom; this is the cause. On a phone the decode is a hardware handoff rather
 * than a software decode, so the stall is shorter and the same shape.
 *
 * PREALLOCATED SLOTS, no allocation on the receive thread. And when a frame does
 * not fit or the queue is full it decodes INLINE rather than dropping: the worst
 * case becomes exactly the old behaviour, never worse, so turning this on cannot
 * lose a frame.
 */
class DecodeQueue(
    private val slots: Int = 6,
    private val decode: (ByteArray, Int, Long) -> Unit,
) {
    /**
     * 128 KiB per slot. A 720p keyframe is tens of KiB; a fragmented frame could
     * in theory reach far more, which is what the inline fallback is for.
     */
    private val bufs = Array(slots) { ByteArray(SLOT) }
    private val lens = IntArray(slots)
    private val hosts = LongArray(slots)
    private var head = 0
    private var tail = 0
    private var count = 0
    private val lock = Any()
    private val items = Semaphore(0)

    /**
     * Frames that took the inline path anyway, and why. Reported, because a
     * queue that quietly falls back to the thing it was built to avoid is a
     * queue that looks like it is working.
     */
    @Volatile var inlineTooBig = 0; private set
    @Volatile var inlineFull = 0; private set
    @Volatile var queued = 0; private set
    @Volatile var maxDepth = 0; private set

    @Volatile private var running = true

    init {
        Thread({
            // Above normal, below the audio threads. The picture should not wait
            // behind ordinary work, and it must never compete with the sound.
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_DISPLAY)
            while (running) {
                items.acquire()
                if (!running) break
                var i: Int
                var n: Int
                var h: Long
                synchronized(lock) {
                    i = head
                    n = lens[i]; h = hosts[i]
                    head = (head + 1) % slots
                    count -= 1
                }
                try { decode(bufs[i], n, h) } catch (t: Throwable) {
                    // A decode that throws must not take the queue with it: the
                    // picture stopping is a bad frame, the queue stopping is the
                    // rest of the call.
                    android.util.Log.e("kin", "decodeq: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }, "kin-decode").apply { isDaemon = true }.start()
    }

    /**
     * Called from the receive thread. COPIES and returns; the decode happens
     * elsewhere. A copy of tens of kilobytes is nothing against a decode, and
     * the assembler reuses its buffer the moment this returns, so holding the
     * caller's array was never an option.
     */
    fun submit(p: ByteArray, n: Int, host: Long) {
        if (n > SLOT) {
            inlineTooBig++
            decode(p, n, host)
            return
        }
        val i: Int
        synchronized(lock) {
            if (count >= slots) {
                // Full means the decoder is behind. Decoding here applies the
                // backpressure to the right place instead of throwing the frame
                // away.
                inlineFull++
                decode(p, n, host)
                return
            }
            i = tail
        }
        // Fill the slot BEFORE publishing it. Single producer, so `tail` cannot
        // move underneath this; publishing first would let the consumer read a
        // slot that is still being written.
        System.arraycopy(p, 0, bufs[i], 0, n)
        lens[i] = n
        hosts[i] = host
        synchronized(lock) {
            tail = (tail + 1) % slots
            count += 1
            if (count > maxDepth) maxDepth = count
        }
        queued++
        items.release()
    }

    fun stop() {
        running = false
        items.release()
    }

    companion object { private const val SLOT = 128 * 1024 }
}

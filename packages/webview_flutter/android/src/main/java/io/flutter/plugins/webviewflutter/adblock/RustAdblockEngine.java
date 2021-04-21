package io.flutter.plugins.webviewflutter.adblock;


import android.net.Uri;

import com.xayn.adblockeraar.Adblock;
import com.xayn.adblockeraar.AdblockEngine;
import com.xayn.adblockeraar.AdblockResult;

import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

import androidx.annotation.WorkerThread;
import androidx.arch.core.util.Function;
import io.flutter.Log;
import io.flutter.plugins.webviewflutter.content_type.ContentType;


class RustAdblockeEngine implements ContentBlockEngine {

    final String pathToDatFile;
    final String TAG;
    private final AdblockEngine engine;
    private final AtomicBoolean ready = new AtomicBoolean(false);

    public RustAdblockeEngine(final String pathToDatFile, String logName, @WorkerThread final Function<RustAdblockeEngine, Void> onEngineInit) {
        this.pathToDatFile = pathToDatFile;
        this.TAG = "RustAdblockeEngine:"+ logName;

        this.engine = Adblock.INSTANCE.createEngine();

        Executor executor = Executors.newSingleThreadExecutor();
        executor.execute(new Runnable() {
            @Override
            public void run() {
                final long start = System.currentTimeMillis();
                Log.d(TAG, "Start init of Engine file : " + pathToDatFile);
                boolean success = engine.deserialize(pathToDatFile);
                Log.d(TAG, "Finished init " + success + " after : " + (System.currentTimeMillis() - start) / 1000f + ", sec");
                ready.set(success);
                onEngineInit.apply(success ? RustAdblockeEngine.this : null);
            }
        });
    }


    @Override
    public BlockResult shouldBlock(Uri hostedUrl, Uri requestedUrl, ContentType type) {
        if (isReady()) {
            final long start = System.currentTimeMillis();
            if (Thread.holdsLock(ready)) {
                Log.d(TAG, "should block HIT.");
            }
            synchronized (ready) {
                AdblockResult result = engine.match(requestedUrl.toString(), hostedUrl.toString(), type.rawName);
                Log.d(TAG, "shouldBlock(" +Thread.currentThread().getName()+ "): matched "+ result.isMatched() + " in "+ (System.currentTimeMillis() - start) + ", msec");
                return result.isMatched() ? BlockResult.BLOCK : BlockResult.OK;
            }
        }

        return BlockResult.ENGINE_NOT_READY;
    }

    public boolean isReady() {
        return ready.get();
    }
}
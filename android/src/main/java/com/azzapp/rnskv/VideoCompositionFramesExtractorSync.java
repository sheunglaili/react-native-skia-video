package com.sheunglaili.rnskv;

import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.Handler;
import android.os.HandlerThread;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CompletableFuture;

import javax.microedition.khronos.egl.EGLContext;

public class VideoCompositionFramesExtractorSync {
  private final VideoComposition composition;

  private final VideoCompositionDecoder decoder;

  private boolean decoding = false;
  private long decodingTimeUs;

  private final Map<VideoComposition.Item, Long> itemsTimes = new HashMap<>();

  private final Set<VideoComposition.Item> itemsEnded = new HashSet<>();

  private final Map<String, Long> renderedTimes = new HashMap<>();

  private HandlerThread exportThread = null;

  private Handler handler;

  private CompletableFuture<Map<String, VideoFrame>> future;

  private final Map<String, MediaExtractor> audioExtractors = new HashMap<>();
  private final Map<String, MediaCodec> audioDecoders = new HashMap<>();
  private final Map<String, MediaFormat> audioFormats = new HashMap<>();
  private final Map<String, Long> lastAudioTimes = new HashMap<>();

  public VideoCompositionFramesExtractorSync(VideoComposition composition) {
    this.composition = composition;
    this.decoder = new VideoCompositionDecoder(composition);
  }

  public void start() throws Exception {
    exportThread = new HandlerThread("ReactNativeSkiaVideo-ExportThread");
    exportThread.start();
    handler = new Handler(exportThread.getLooper());
    CompletableFuture<Void> future = new CompletableFuture<>();
    EGLContext sharedContext = EGLUtils.getCurrentContextOrThrows();
    handler.post(() -> {
      try {
        decoder.prepare(sharedContext);
        decoder.setOnErrorListener(this::handleError);
        decoder.setOnFrameAvailableListener(this::onFrameAvailable);
        decoder.setOnItemEndReachedListener(this::onItemEndReached);
        decoder.setOnItemImageAvailableListener(this::onItemImageAvailable);
        decoder.start();
        // Initialize audio extractors
        initAudioExtractors();
      } catch (Exception e) {
        future.completeExceptionally(e);
        return;
      }
      future.complete(null);
    });

    future.get();
  }

  /**
   * Decode the next frame of each composition item according to the current position of the player.
   *
   * @return a map of item id to video frame
   */
  public Map<String, VideoFrame> decodeCompositionFrames(double time) throws Exception {
    decodingTimeUs = TimeHelpers.secToUs(time);
    future = new CompletableFuture<>();
    handler.post(() -> {
      decoding = true;
      renderedTimes.clear();
      checkIfFrameDecoded();
    });
    return future.get();
  }

  /**
   * Decode audio samples for each composition item at the current time.
   *
   * @param time The current time in seconds
   * @return a map of item id to audio sample
   */
  public Map<String, AudioSample> decodeCompositionAudio(double time) {
    Map<String, AudioSample> audioSamples = new HashMap<>();
    long timeUs = TimeHelpers.secToUs(time);

    for (VideoComposition.Item item : composition.getItems()) {
      if (item.isMuted()) {
        continue;
      }

      String itemId = item.getId();
      MediaExtractor extractor = audioExtractors.get(itemId);
      MediaFormat format = audioFormats.get(itemId);

      if (extractor == null || format == null) {
        continue;
      }

      // Calculate target time for this item
      long itemStartTimeUs = TimeHelpers.secToUs(item.getStartTime());
      long compositionStartTimeUs = TimeHelpers.secToUs(item.getCompositionStartTime());
      long targetTimeUs = itemStartTimeUs + (timeUs - compositionStartTimeUs);

      // Seek if needed
      Long lastTimeUs = lastAudioTimes.get(itemId);
      if (lastTimeUs == null || Math.abs(targetTimeUs - lastTimeUs) > 100000) { // 100ms threshold
        extractor.seekTo(targetTimeUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
      }

      // Read audio sample
      int bufferSize = format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE);
      ByteBuffer buffer = ByteBuffer.allocateDirect(bufferSize);
      int sampleSize = extractor.readSampleData(buffer, 0);

      if (sampleSize > 0) {
        long sampleTimeUs = extractor.getSampleTime();
        buffer.limit(sampleSize);

        int sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE);
        int channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
        long durationUs = (long)((sampleSize / (2.0 * channels)) / sampleRate * 1000000);

        AudioSample audioSample = new AudioSample(
          buffer,
          sampleTimeUs,
          durationUs,
          sampleRate,
          channels
        );
        audioSamples.put(itemId, audioSample);
        lastAudioTimes.put(itemId, sampleTimeUs);

        extractor.advance();
      }
    }

    return audioSamples;
  }

  public void release() {
    decoder.release();
    // Release audio extractors
    for (MediaExtractor extractor : audioExtractors.values()) {
      extractor.release();
    }
    audioExtractors.clear();
    audioFormats.clear();
    lastAudioTimes.clear();

    if (exportThread != null) {
      exportThread.quit();
    }
    if (future != null) {
      future.cancel(true);
    }
  }

  private void initAudioExtractors() throws IOException {
    for (VideoComposition.Item item : composition.getItems()) {
      if (item.isMuted()) {
        continue;
      }

      MediaExtractor extractor = new MediaExtractor();
      extractor.setDataSource(item.getPath());

      // Find audio track
      int audioTrackIndex = -1;
      for (int i = 0; i < extractor.getTrackCount(); i++) {
        MediaFormat format = extractor.getTrackFormat(i);
        String mime = format.getString(MediaFormat.KEY_MIME);
        if (mime != null && mime.startsWith("audio/")) {
          audioTrackIndex = i;
          break;
        }
      }

      if (audioTrackIndex != -1) {
        MediaFormat format = extractor.getTrackFormat(audioTrackIndex);
        extractor.selectTrack(audioTrackIndex);
        audioExtractors.put(item.getId(), extractor);
        audioFormats.put(item.getId(), format);

        // Seek to start time
        if (item.getStartTime() != 0) {
          extractor.seekTo(
            TimeHelpers.secToUs(item.getStartTime()),
            MediaExtractor.SEEK_TO_PREVIOUS_SYNC
          );
        }
      } else {
        extractor.release();
      }
    }
  }

  private void onFrameAvailable(VideoComposition.Item item, long presentationTimeUs) {
    itemsTimes.put(item, presentationTimeUs);
    if (decoding) {
      checkIfFrameDecoded();
    }
  }

  private void onItemEndReached(VideoComposition.Item item) {
    itemsEnded.add(item);
    if (decoding) {
      checkIfFrameDecoded();
    }
  }

  private void checkIfFrameDecoded() {
    boolean allItemsReady = true;
    for (VideoComposition.Item item : composition.getItems()) {
      if (!itemsTimes.containsKey(item)) {
        allItemsReady = false;
        continue;
      }
      if (itemsEnded.contains(item)) {
        continue;
      }
      Long itemTime = itemsTimes.get(item);
      if (itemTime == null) {
        allItemsReady = false;
        continue;
      }
      long itemCurrentTimeUs = itemTime;
      long startTimeUs = TimeHelpers.secToUs(item.getStartTime());
      long compositionStartTimeUs = TimeHelpers.secToUs(item.getCompositionStartTime());
      if (itemCurrentTimeUs - startTimeUs < decodingTimeUs - compositionStartTimeUs) {
        allItemsReady = false;
      }
    }
    Map<String, Long> renderedTimes = decoder.render(decodingTimeUs);
    renderedTimes.forEach((itemId, time) -> {
      if (time != null) {
        this.renderedTimes.put(itemId, time);
      }
    });
    if (allItemsReady) {
      decoding = false;
      resolveIfReady();
    }
  }

  private void onItemImageAvailable(VideoComposition.Item item) {
    if (!decoding) {
      resolveIfReady();
    }
  }

  private void handleError(Exception e) {
    future.completeExceptionally(e);
  }

  private void resolveIfReady() {
    Map<String, VideoFrame> videoFrames = decoder.updateVideosFrames();
    for (VideoComposition.Item item : composition.getItems()) {
      VideoFrame videoFrame = videoFrames.getOrDefault(item.getId(), null);
      if (videoFrame == null) {
        return;
      }
      Long itemFrameTime = renderedTimes.getOrDefault(item.getId(), null);
      if (itemFrameTime == null) {
        continue;
      }
      long videoFrameTime = TimeHelpers.nsecToUs(videoFrame.getTimestampNs());
      if (Math.abs(itemFrameTime - videoFrameTime) > 1000) {
        return;
      }
    }
    future.complete(videoFrames);
  }
}

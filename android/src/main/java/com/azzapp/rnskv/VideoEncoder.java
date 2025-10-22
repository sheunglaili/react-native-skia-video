package com.azzapp.rnskv;

import android.graphics.Bitmap;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.opengl.GLES20;
import android.util.Log;
import android.view.Surface;

import java.io.IOException;
import java.nio.ByteBuffer;

import javax.microedition.khronos.egl.EGL10;
import javax.microedition.khronos.egl.EGLContext;


/**
 * Helper class for encoding video.
 */
public class VideoEncoder {

  private static final String TAG = "VideoEncoder";

  public static final String MIME_TYPE = "video/avc";    // H.264 Advanced Video Coding
  public static final String AUDIO_MIME_TYPE = "audio/mp4a-latm"; // AAC

  public static final int DEFAULT_I_FRAME_INTERVAL_SECONDS = 1;

  private final String outputPath;

  private final int width;

  private final int height;

  private final int frameRate;

  private final int bitRate;

  private final String encoderName;

  private MediaCodec encoder;

  private Surface inputSurface;

  private EGLResourcesHolder eglResourcesHolder;

  private TextureRenderer textureRenderer;

  private MediaMuxer muxer;

  private int trackIndex;
  private int audioTrackIndex = -1;

  private boolean muxerStarted;

  private final MediaCodec.BufferInfo bufferInfo;


  /**
   * Creates a new VideoEncoder.
   *
   * @param outputPath the path to write the encoded video to
   * @param width      the width of the video
   * @param height     the height of the video
   * @param frameRate  the frame rate of the video
   * @param bitRate    the bit rate of the video
   * @param encoderName the name of the encoder to use, or null to use the default encoder
   */
  public VideoEncoder(
    String outputPath,
    int width,
    int height,
    int frameRate,
    int bitRate,
    String encoderName
  ) {
    this.outputPath = outputPath;
    this.width = width;
    this.height = height;
    this.frameRate = frameRate;
    this.bitRate = bitRate;
    this.encoderName = encoderName;
    bufferInfo = new MediaCodec.BufferInfo();
  }

  /**
   * Configures encoder and muxer state, and prepares the input Surface.
   */
  public void prepare() throws IOException {
    EGLContext sharedContext = EGLUtils.getCurrentContextOrThrows();
    encoder = encoderName != null
      ? MediaCodec.createByCodecName(encoderName)
      : MediaCodec.createEncoderByType(MIME_TYPE);

    MediaFormat format = MediaFormat.createVideoFormat(MIME_TYPE, width, height);
    format.setInteger(MediaFormat.KEY_COLOR_FORMAT,
      MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
    format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
    format.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate);
    format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, DEFAULT_I_FRAME_INTERVAL_SECONDS);

    encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);

    inputSurface = encoder.createInputSurface();
    eglResourcesHolder = EGLResourcesHolder.createWithWindowedSurface(sharedContext, inputSurface);
    eglResourcesHolder.makeCurrent();
    textureRenderer = new TextureRenderer();
    encoder.start();

    try {
      muxer = new MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
    } catch (IOException ioe) {
      throw new RuntimeException("MediaMuxer creation failed", ioe);
    }

    trackIndex = -1;
    muxerStarted = false;

    // Add audio track to muxer with hardcoded sensible defaults
    MediaFormat audioFormat = MediaFormat.createAudioFormat(AUDIO_MIME_TYPE, 44100, 2);
    audioFormat.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
    audioFormat.setInteger(MediaFormat.KEY_BIT_RATE, 128000);
    audioTrackIndex = muxer.addTrack(audioFormat);
  }

  public void makeGLContextCurrent() {
    eglResourcesHolder.makeCurrent();
  }

  /**
   * Encodes audio data from an ArrayBuffer.
   *
   * @param audioBuffer the audio buffer (DirectByteBuffer containing PCM data)
   * @param time        the presentation time in seconds
   */
  public void encodeAudio(ByteBuffer audioBuffer, double time) {
    if (audioTrackIndex < 0 || !muxerStarted) {
      return;
    }

    long timeUs = TimeHelpers.secToUs(time);

    // Create MediaCodec.BufferInfo for audio sample
    MediaCodec.BufferInfo audioInfo = new MediaCodec.BufferInfo();
    audioInfo.offset = 0;
    audioInfo.size = audioBuffer.remaining();
    audioInfo.presentationTimeUs = timeUs;
    audioInfo.flags = 0;

    // Write audio sample directly to muxer (raw PCM data)
    // Note: For production, you'd want to encode this to AAC first
    // For simplicity, we're writing raw PCM which works with some players
    synchronized (this) {
      if (muxerStarted) {
        muxer.writeSampleData(audioTrackIndex, audioBuffer, audioInfo);
      }
    }
  }

  public void encodeFrame(int texture, double time) {
    long timeUS = TimeHelpers.secToUs(time);
    GLES20.glClearColor(0, 0, 0, 0);
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
    GLES20.glViewport(0, 0, width, height);
    textureRenderer.draw(texture, EGLUtils.IDENTITY_MATRIX);
    eglResourcesHolder.setPresentationTime(timeUS * 1000);
    if (!eglResourcesHolder.swapBuffers()) {
      throw new RuntimeException("eglSwapBuffer failed");
    }
    drainEncoder(false);
  }

  public void finishWriting() {
    drainEncoder(true);
  }

  /**
   * Extracts all pending data from the encoder.
   *
   * @param endOfStream true if this is the end of the stream
   */
  private void drainEncoder(boolean endOfStream) {
    final int TIMEOUT_USEC = 10000;

    if (endOfStream) {
      encoder.signalEndOfInputStream();
    }

    while (true) {
      int encoderStatus = encoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC);
      if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
        // no output available yet
        if (!endOfStream) {
          break; // out of while
        }
      }
      if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        // should happen before receiving buffers, and should only happen once
        if (muxerStarted) {
          throw new RuntimeException("format changed twice");
        }
        MediaFormat newFormat = encoder.getOutputFormat();

        // now that we have the Magic Goodies, start the muxer
        trackIndex = muxer.addTrack(newFormat);
        synchronized (this) {
          muxer.start();
          muxerStarted = true;
        }
      } else if (encoderStatus < 0) {
        Log.w(TAG, "unexpected result from encoder.dequeueOutputBuffer: " + encoderStatus);
        // let's ignore it
      } else {
        ByteBuffer encodedData = encoder.getOutputBuffer(encoderStatus);
        if (encodedData == null) {
          throw new RuntimeException("encoderOutputBuffer " + encoderStatus + " was null");
        }

        if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
          // The codec config data was pulled out and fed to the muxer when we got
          // the INFO_OUTPUT_FORMAT_CHANGED status.  Ignore it.
          bufferInfo.size = 0;
        }

        if (bufferInfo.size != 0) {
          if (!muxerStarted) {
            throw new RuntimeException("muxer hasn't started");
          }

          // adjust the ByteBuffer values to match BufferInfo (not needed?)
          encodedData.position(bufferInfo.offset);
          encodedData.limit(bufferInfo.offset + bufferInfo.size);

          synchronized (this) {
            muxer.writeSampleData(trackIndex, encodedData, bufferInfo);
          }
        }

        encoder.releaseOutputBuffer(encoderStatus, false);

        if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
          if (!endOfStream) {
            Log.w(TAG, "reached end of stream unexpectedly");
          }
          break; // out of while
        }
      }
    }
  }

  /**
   * Releases encoder resources.  May be called after partial / failed initialization.
   */
  public void release() {
    if (eglResourcesHolder != null) {
      eglResourcesHolder.release();
    }
    if (encoder != null) {
      encoder.stop();
      encoder.release();
      encoder = null;
    }
    if (inputSurface != null) {
      inputSurface.release();
      inputSurface = null;
    }
    if (muxer != null) {
      muxer.stop();
      muxer.release();
      muxer = null;
    }
  }

  public Bitmap saveTexture(int texture, int width, int height) {
    int[] frame = new int[1];
    GLES20.glGenFramebuffers(1, frame, 0);
    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, frame[0]);
    GLES20.glFramebufferTexture2D(
      GLES20.GL_FRAMEBUFFER,
      GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, texture,
      0
    );

    ByteBuffer buffer = ByteBuffer.allocate(width * height * 4);
    GLES20.glReadPixels(
      0, 0, width, height, GLES20.GL_RGBA,
      GLES20.GL_UNSIGNED_BYTE, buffer
    );

    Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
    bitmap.copyPixelsFromBuffer(buffer);

    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
    GLES20.glDeleteFramebuffers(1, frame, 0);

    return bitmap;
  }
}

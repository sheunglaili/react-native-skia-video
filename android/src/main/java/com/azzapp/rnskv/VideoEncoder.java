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
 * Helper class for encoding video and audio.
 * Uses MediaCodec pipeline for both video (H.264) and audio (AAC) encoding.
 */
public class VideoEncoder {

  private static final String TAG = "VideoEncoder";

  public static final String MIME_TYPE = "video/avc";    // H.264 Advanced Video Coding
  public static final String AUDIO_MIME_TYPE = "audio/mp4a-latm"; // AAC

  public static final int DEFAULT_I_FRAME_INTERVAL_SECONDS = 1;
  
  // Audio encoding constants
  private static final int AUDIO_SAMPLE_RATE = 44100;
  private static final int AUDIO_CHANNEL_COUNT = 2;
  private static final int AUDIO_BIT_RATE = 128000; // 128kbps

  private final String outputPath;

  private final int width;

  private final int height;

  private final int frameRate;

  private final int bitRate;

  private final String encoderName;

  private MediaCodec videoEncoder;

  private MediaCodec audioEncoder;

  private Surface videoInputSurface;

  private EGLResourcesHolder eglResourcesHolder;

  private TextureRenderer textureRenderer;

  private MediaMuxer muxer;

  private int videoTrackIndex = -1;
  private int audioTrackIndex = -1;

  private boolean muxerStarted;

  private final MediaCodec.BufferInfo videoBufferInfo;
  private final MediaCodec.BufferInfo audioBufferInfo;

  // Audio encoding state
  private boolean audioEncoderInitialized = false;
  private boolean audioFormatChangeHandled = false;


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
    videoBufferInfo = new MediaCodec.BufferInfo();
    audioBufferInfo = new MediaCodec.BufferInfo();
  }

  /**
   * Configures encoder and muxer state, and prepares the input Surface.
   */
  public void prepare() throws IOException {
    EGLContext sharedContext = EGLUtils.getCurrentContextOrThrows();
    videoEncoder = encoderName != null
      ? MediaCodec.createByCodecName(encoderName)
      : MediaCodec.createEncoderByType(MIME_TYPE);

    MediaFormat videoFormat = MediaFormat.createVideoFormat(MIME_TYPE, width, height);
    videoFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT,
      MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
    videoFormat.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
    videoFormat.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate);
    videoFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, DEFAULT_I_FRAME_INTERVAL_SECONDS);

    videoEncoder.configure(videoFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);

    videoInputSurface = videoEncoder.createInputSurface();
    eglResourcesHolder = EGLResourcesHolder.createWithWindowedSurface(sharedContext, videoInputSurface);
    eglResourcesHolder.makeCurrent();
    textureRenderer = new TextureRenderer();
    videoEncoder.start();

    try {
      muxer = new MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
    } catch (IOException ioe) {
      throw new RuntimeException("MediaMuxer creation failed", ioe);
    }

    videoTrackIndex = -1;
    audioTrackIndex = -1;
    muxerStarted = false;

    
    audioEncoder = MediaCodec.createEncoderByType(AUDIO_MIME_TYPE);
    
    MediaFormat audioFormat = MediaFormat.createAudioFormat(AUDIO_MIME_TYPE, AUDIO_SAMPLE_RATE, AUDIO_CHANNEL_COUNT);
    audioFormat.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
    audioFormat.setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE);
    
    audioEncoder.configure(audioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
    audioEncoder.start();
    audioEncoderInitialized = true;
    audioFormatChangeHandled = false;
  }

  public void makeGLContextCurrent() {
    eglResourcesHolder.makeCurrent();
  }

  /**
   * Encodes audio data from a ByteBuffer.
   * The audio data should be raw PCM data with sample rate 44100 and 2 channels.
   *
   * @param audioBuffer the audio buffer (DirectByteBuffer containing PCM data)
   * @param time        the presentation time in seconds
   */
  public void encodeAudio(ByteBuffer audioBuffer, double time) {
    if (!audioEncoderInitialized) {
      return;
    }

    long timeUs = TimeHelpers.secToUs(time);
    
    int inputBufferIndex = audioEncoder.dequeueInputBuffer(0);
    if (inputBufferIndex < 0) {
      return; // No input buffers available, try again later
    }

    ByteBuffer inputBuffer = audioEncoder.getInputBuffer(inputBufferIndex);
    if (inputBuffer == null) {
      return;
    }

    inputBuffer.clear();
    inputBuffer.put(audioBuffer);
    inputBuffer.flip();

    audioEncoder.queueInputBuffer(
      inputBufferIndex,
      0,
      audioBuffer.remaining(),
      timeUs,
      0
    );
    
    // Drain the audio encoder output
    drainAudioEncoder(false);
  }

  /**
   * Drains the audio encoder output and writes to muxer.
   *
   * @param endOfStream true if this is the end of the stream
   */
  private void drainAudioEncoder(boolean endOfStream) {
    if (!audioEncoderInitialized) {
      return;
    }

    final int TIMEOUT_USEC = 10000;

    if (endOfStream) {
      audioEncoder.signalEndOfInputStream();
    }

    while (true) {
      int encoderStatus = audioEncoder.dequeueOutputBuffer(audioBufferInfo, TIMEOUT_USEC);
      
      if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
        // no output available yet
        if (!endOfStream) {
          break; // out of while
        }
      } else if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        // Audio format changed - add audio track to muxer
        if (audioFormatChangeHandled) {
          throw new RuntimeException("audio format changed twice");
        }
        
        MediaFormat newFormat = audioEncoder.getOutputFormat();
        audioTrackIndex = muxer.addTrack(newFormat);
        audioFormatChangeHandled = true;
        
        // If both video and audio tracks are ready, start the muxer
        if (videoTrackIndex >= 0 && audioTrackIndex >= 0 && !muxerStarted) {
          synchronized (this) {
            if (!muxerStarted) {
              muxer.start();
              muxerStarted = true;
            }
          }
        }
      } else if (encoderStatus < 0) {
        Log.w(TAG, "unexpected result from audio encoder.dequeueOutputBuffer: " + encoderStatus);
        // let's ignore it
      } else {
        ByteBuffer encodedData = audioEncoder.getOutputBuffer(encoderStatus);
        if (encodedData == null) {
          throw new RuntimeException("audioEncoderOutputBuffer " + encoderStatus + " was null");
        }

        if ((audioBufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
          // The codec config data was pulled out and fed to the muxer when we got
          // the INFO_OUTPUT_FORMAT_CHANGED status. Ignore it.
          audioBufferInfo.size = 0;
        }

        if (audioBufferInfo.size != 0) {
          if (!muxerStarted) {
            // Don't write yet, wait for both tracks to be ready
            audioEncoder.releaseOutputBuffer(encoderStatus, false);
            break;
          }

          // adjust the ByteBuffer values to match BufferInfo
          encodedData.position(audioBufferInfo.offset);
          encodedData.limit(audioBufferInfo.offset + audioBufferInfo.size);

          synchronized (this) {
            if (muxerStarted) {
              muxer.writeSampleData(audioTrackIndex, encodedData, audioBufferInfo);
            }
          }
        }

        audioEncoder.releaseOutputBuffer(encoderStatus, false);

        if ((audioBufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
          if (!endOfStream) {
            Log.w(TAG, "reached end of audio stream unexpectedly");
          }
          break; // out of while
        }
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
    drainVideoEncoder(false);
  }

  public void finishWriting() {
    drainAudioEncoder(true);
    drainVideoEncoder(true);
  }

  /**
   * Extracts all pending data from the video encoder.
   *
   * @param endOfStream true if this is the end of the stream
   */
  private void drainVideoEncoder(boolean endOfStream) {
    final int TIMEOUT_USEC = 10000;

    if (endOfStream) {
      videoEncoder.signalEndOfInputStream();
    }

    while (true) {
      int encoderStatus = videoEncoder.dequeueOutputBuffer(videoBufferInfo, TIMEOUT_USEC);
      if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
        // no output available yet
        if (!endOfStream) {
          break; // out of while
        }
      }
      if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        // should happen before receiving buffers, and should only happen once
        if (videoTrackIndex >= 0) {
          throw new RuntimeException("video format changed twice");
        }
        MediaFormat newFormat = videoEncoder.getOutputFormat();

        // now that we have the Magic Goodies, add video track to muxer
        videoTrackIndex = muxer.addTrack(newFormat);
        
        // If both video and audio tracks are ready, start the muxer
        if (videoTrackIndex >= 0 && audioTrackIndex >= 0 && !muxerStarted) {
          synchronized (this) {
            if (!muxerStarted) {
              muxer.start();
              muxerStarted = true;
            }
          }
        }
      } else if (encoderStatus < 0) {
        Log.w(TAG, "unexpected result from video encoder.dequeueOutputBuffer: " + encoderStatus);
        // let's ignore it
      } else {
        ByteBuffer encodedData = videoEncoder.getOutputBuffer(encoderStatus);
        if (encodedData == null) {
          throw new RuntimeException("videoEncoderOutputBuffer " + encoderStatus + " was null");
        }

        if ((videoBufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
          // The codec config data was pulled out and fed to the muxer when we got
          // the INFO_OUTPUT_FORMAT_CHANGED status.  Ignore it.
          videoBufferInfo.size = 0;
        }

        if (videoBufferInfo.size != 0) {
          if (!muxerStarted) {
            // Don't write yet, wait for both tracks to be ready
            videoEncoder.releaseOutputBuffer(encoderStatus, false);
            break;
          }

          // adjust the ByteBuffer values to match BufferInfo (not needed?)
          encodedData.position(videoBufferInfo.offset);
          encodedData.limit(videoBufferInfo.offset + videoBufferInfo.size);

          synchronized (this) {
            if (muxerStarted) {
              muxer.writeSampleData(videoTrackIndex, encodedData, videoBufferInfo);
            }
          }
        }

        videoEncoder.releaseOutputBuffer(encoderStatus, false);

        if ((videoBufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
          if (!endOfStream) {
            Log.w(TAG, "reached end of video stream unexpectedly");
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
    if (videoEncoder != null) {
      videoEncoder.stop();
      videoEncoder.release();
      videoEncoder = null;
    }
    if (audioEncoder != null) {
      audioEncoder.stop();
      audioEncoder.release();
      audioEncoder = null;
    }
    if (videoInputSurface != null) {
      videoInputSurface.release();
      videoInputSurface = null;
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

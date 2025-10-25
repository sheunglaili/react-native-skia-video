package com.azzapp.rnskv;

import java.nio.ByteBuffer;

/**
 * Represents an audio sample with metadata.
 */
public class AudioSample {
  private final ByteBuffer buffer; // Must be DirectByteBuffer for zero-copy
  private final long presentationTimeUs;
  private final long durationUs;
  private final int sampleRate;
  private final int channels;

  public AudioSample(
    ByteBuffer buffer,
    long presentationTimeUs,
    long durationUs,
    int sampleRate,
    int channels
  ) {
    if (!buffer.isDirect()) {
      throw new IllegalArgumentException("AudioSample buffer must be a DirectByteBuffer");
    }
    this.buffer = buffer;
    this.presentationTimeUs = presentationTimeUs;
    this.durationUs = durationUs;
    this.sampleRate = sampleRate;
    this.channels = channels;
  }

  public ByteBuffer getBuffer() {
    return buffer;
  }

  public double getPresentationTime() {
    return presentationTimeUs / 1000000.0;
  }

  public double getDuration() {
    return durationUs / 1000000.0;
  }

  public int getSampleRate() {
    return sampleRate;
  }

  public int getChannels() {
    return channels;
  }
}



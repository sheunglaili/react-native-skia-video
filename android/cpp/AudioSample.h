//
//  AudioSample.h
//  azzapp-react-native-skia-video
//
//  Created by Audio Export Feature
//

#pragma once

#include <fbjni/fbjni.h>
#include <jsi/jsi.h>

namespace RNSkiaVideo {
using namespace facebook;

// JByteBuffer wrapper for fbjni
struct JByteBuffer : public jni::JavaClass<JByteBuffer> {
  static constexpr auto kJavaDescriptor = "Ljava/nio/ByteBuffer;";
  
  // Static method to allocate a direct ByteBuffer
  static jni::local_ref<JByteBuffer> allocateDirect(int capacity) {
    static auto allocateMethod = javaClassStatic()->getStaticMethod<JByteBuffer(jint)>("allocateDirect");
    return allocateMethod(javaClassStatic(), capacity);
  }
  
  // Get direct buffer address
  void* getDirectAddress() const {
    return jni::Environment::current()->GetDirectBufferAddress(self());
  }
  
  // Get direct buffer capacity
  jlong getDirectSize() const {
    return jni::Environment::current()->GetDirectBufferCapacity(self());
  }
};

/**
 * Zero-copy buffer implementation for AudioSample using JNI DirectByteBuffer.
 */
class AudioSampleBuffer : public jsi::MutableBuffer {
public:
  AudioSampleBuffer(jni::global_ref<JByteBuffer> javaBuffer);
  ~AudioSampleBuffer();
  size_t size() const override;
  uint8_t* data() override;

private:
  jni::global_ref<JByteBuffer> javaBuffer;
  uint8_t* dataPointer;
  size_t dataLength;
};

/**
 * JSI HostObject for AudioSample.
 */
class JSI_EXPORT AudioSample : public jsi::HostObject {
public:
  AudioSample(jni::alias_ref<jobject> javaAudioSample);
  ~AudioSample();
  jsi::Value get(jsi::Runtime&, const jsi::PropNameID& name) override;
  std::vector<jsi::PropNameID> getPropertyNames(jsi::Runtime& rt) override;
  jni::global_ref<jobject> getJavaObject();

private:
  jni::global_ref<jobject> javaAudioSample;
  double presentationTime;
  double duration;
  int sampleRate;
  int channels;
};

} // namespace RNSkiaVideo



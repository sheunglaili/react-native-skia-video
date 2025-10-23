//
//  AudioSample.cpp
//  azzapp-react-native-skia-video
//
//  Created by Audio Export Feature
//

#include "AudioSample.h"
#include "JNIHelpers.h"

namespace RNSkiaVideo {

// AudioSampleBuffer implementation - zero-copy buffer for ArrayBuffer
AudioSampleBuffer::AudioSampleBuffer(jni::global_ref<RNSkiaVideo::JByteBuffer> javaBuffer)
    : javaBuffer(std::move(javaBuffer)) {
  dataPointer = reinterpret_cast<uint8_t*>(this->javaBuffer->getDirectAddress());
  dataLength = this->javaBuffer->getDirectSize();
}

AudioSampleBuffer::~AudioSampleBuffer() {
  // javaBuffer will be automatically released by global_ref
}

size_t AudioSampleBuffer::size() const {
  return dataLength;
}

uint8_t* AudioSampleBuffer::data() {
  return dataPointer;
}

// AudioSample JSI HostObject implementation
AudioSample::AudioSample(jni::alias_ref<jobject> javaAudioSample)
    : javaAudioSample(jni::make_global(javaAudioSample)) {
  // Extract audio properties from Java object
  auto audioSampleClass = jni::findClassLocal("com/azzapp/rnskv/AudioSample");
  
  auto getPresentationTimeMethod = audioSampleClass->getMethod<jdouble()>("getPresentationTime");
  this->presentationTime = getPresentationTimeMethod(javaAudioSample);
  
  auto getDurationMethod = audioSampleClass->getMethod<jdouble()>("getDuration");
  this->duration = getDurationMethod(javaAudioSample);
  
  auto getSampleRateMethod = audioSampleClass->getMethod<jint()>("getSampleRate");
  this->sampleRate = getSampleRateMethod(javaAudioSample);
  
  auto getChannelsMethod = audioSampleClass->getMethod<jint()>("getChannels");
  this->channels = getChannelsMethod(javaAudioSample);
}

AudioSample::~AudioSample() {
  // javaAudioSample will be automatically released by global_ref
}

std::vector<jsi::PropNameID> AudioSample::getPropertyNames(jsi::Runtime& rt) {
  std::vector<jsi::PropNameID> result;
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("buffer")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("presentationTime")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("duration")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("sampleRate")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("channels")));
  return result;
}

jsi::Value AudioSample::get(jsi::Runtime& runtime, const jsi::PropNameID& propNameId) {
  auto propName = propNameId.utf8(runtime);
  
  if (propName == "buffer") {
    // Create zero-copy ArrayBuffer from Java DirectByteBuffer
    auto audioSampleClass = jni::findClassLocal("com/azzapp/rnskv/AudioSample");
    auto getBufferMethod = audioSampleClass->getMethod<jni::alias_ref<RNSkiaVideo::JByteBuffer>()>("getBuffer");
    auto javaBuffer = getBufferMethod(javaAudioSample);
    
    auto buffer = std::make_shared<AudioSampleBuffer>(jni::make_global(javaBuffer));
    return jsi::Value(runtime, jsi::ArrayBuffer(runtime, buffer));
  } else if (propName == "presentationTime") {
    return jsi::Value(presentationTime);
  } else if (propName == "duration") {
    return jsi::Value(duration);
  } else if (propName == "sampleRate") {
    return jsi::Value(sampleRate);
  } else if (propName == "channels") {
    return jsi::Value(channels);
  }

  return jsi::Value::undefined();
}

jni::global_ref<jobject> AudioSample::getJavaObject() {
  return javaAudioSample;
}

} // namespace RNSkiaVideo



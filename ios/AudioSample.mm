//
//  AudioSample.mm
//  azzapp-react-native-skia-video
//
//  Created by Audio Export Feature
//

#import "AudioSample.h"

namespace RNSkiaVideo {

// AudioSampleBuffer implementation - zero-copy buffer for ArrayBuffer
AudioSampleBuffer::AudioSampleBuffer(CMSampleBufferRef sampleBuffer) {
  this->sampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  CMBlockBufferGetDataPointer(blockBuffer, 0, &dataLength, NULL, &dataPointer);
}

AudioSampleBuffer::~AudioSampleBuffer() {
  if (sampleBuffer) {
    CFRelease(sampleBuffer);
  }
}

size_t AudioSampleBuffer::size() const {
  return dataLength;
}

uint8_t* AudioSampleBuffer::data() {
  return (uint8_t*)dataPointer;
}

// AudioSample implementation
AudioSample::AudioSample(CMSampleBufferRef sampleBuffer) {
  this->sampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
  
  // Extract audio properties
  CMTime durationTime = CMSampleBufferGetDuration(sampleBuffer);
  this->duration = CMTimeGetSeconds(durationTime);
  
  CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  this->presentationTime = CMTimeGetSeconds(presentationTimeStamp);
  
  // Get audio format description
  CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
  const AudioStreamBasicDescription* asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
  
  if (asbd) {
    this->sampleRate = (int)asbd->mSampleRate;
    this->channels = (int)asbd->mChannelsPerFrame;
  } else {
    this->sampleRate = 44100;
    this->channels = 2;
  }
}

AudioSample::~AudioSample() {
  if (sampleBuffer) {
    CFRelease(sampleBuffer);
  }
}

std::vector<jsi::PropNameID> AudioSample::getPropertyNames(jsi::Runtime& rt) {
  std::vector<jsi::PropNameID> result;
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("buffer")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("duration")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("sampleRate")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("channels")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("presentationTime")));
  return result;
}

jsi::Value AudioSample::get(jsi::Runtime& runtime,
                           const jsi::PropNameID& propNameId) {
  auto propName = propNameId.utf8(runtime);
  if (propName == "buffer") {
    // Create zero-copy ArrayBuffer
    auto buffer = std::make_shared<AudioSampleBuffer>(sampleBuffer);
    return jsi::Value(runtime, jsi::ArrayBuffer(runtime, buffer));
  } else if (propName == "duration") {
    return jsi::Value(duration);
  } else if (propName == "sampleRate") {
    return jsi::Value(sampleRate);
  } else if (propName == "channels") {
    return jsi::Value(channels);
  } else if (propName == "presentationTime") {
    return jsi::Value(presentationTime);
  }

  return jsi::Value::undefined();
}

CMSampleBufferRef AudioSample::getSampleBuffer() {
  return sampleBuffer;
}

} // namespace RNSkiaVideo



//
//  AudioSample.h
//  azzapp-react-native-skia-video
//
//  Created by Audio Export Feature
//

#pragma once
#import <AVFoundation/AVFoundation.h>
#import <jsi/jsi.h>

namespace RNSkiaVideo {
using namespace facebook;

class AudioSampleBuffer : public jsi::MutableBuffer {
public:
  AudioSampleBuffer(CMSampleBufferRef sampleBuffer);
  ~AudioSampleBuffer();
  size_t size() const override;
  uint8_t* data() override;

private:
  CMSampleBufferRef sampleBuffer;
  char* dataPointer;
  size_t dataLength;
};

class JSI_EXPORT AudioSample : public jsi::HostObject {
public:
  AudioSample(CMSampleBufferRef sampleBuffer);
  ~AudioSample();
  jsi::Value get(jsi::Runtime&, const jsi::PropNameID& name) override;
  std::vector<jsi::PropNameID> getPropertyNames(jsi::Runtime& rt) override;
  CMSampleBufferRef getSampleBuffer();

private:
  CMSampleBufferRef sampleBuffer;
  double duration;
  int sampleRate;
  int channels;
  double presentationTime;
};

} // namespace RNSkiaVideo



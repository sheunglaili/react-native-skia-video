#include "VideoCompositionFramesExtractorSyncHostObject.h"

#import "AVAssetTrackUtils.h"
#import "JSIUtils.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <future>

namespace RNSkiaVideo {

VideoCompositionFramesExtractorSyncHostObject::
    VideoCompositionFramesExtractorSyncHostObject(
        std::shared_ptr<VideoComposition> composition)
    : composition(composition) {}

VideoCompositionFramesExtractorSyncHostObject::
    ~VideoCompositionFramesExtractorSyncHostObject() {
  this->release();
}

std::vector<jsi::PropNameID>
VideoCompositionFramesExtractorSyncHostObject::getPropertyNames(
    jsi::Runtime& rt) {
  std::vector<jsi::PropNameID> result;
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("start")));
  result.push_back(
      jsi::PropNameID::forUtf8(rt, std::string("decodeCompositionFrames")));
  result.push_back(
      jsi::PropNameID::forUtf8(rt, std::string("decodeCompositionAudio")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("dispose")));
  return result;
}

jsi::Value VideoCompositionFramesExtractorSyncHostObject::get(
    jsi::Runtime& runtime, const jsi::PropNameID& propNameId) {
  auto propName = propNameId.utf8(runtime);
  if (propName == "start") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "start"), 1,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          try {
            for (const auto& item : composition->items) {
              itemDecoders[item->id] =
                  std::make_shared<VideoCompositionItemDecoder>(item, false);
            }
          } catch (NSError* error) {
            itemDecoders.clear();
            throw error;
          }
          return jsi::Value::undefined();
        });
  } else if (propName == "decodeCompositionFrames") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "decodeCompositionFrames"),
        1,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          auto currentTime =
              CMTimeMakeWithSeconds(arguments[0].asNumber(), NSEC_PER_SEC);
          auto frames = jsi::Object(runtime);
          for (const auto& entry : itemDecoders) {
            auto itemId = entry.first;
            auto decoder = entry.second;

            decoder->advanceDecoder(currentTime);

            auto previousFrame = currentFrames[itemId];
            auto frame =
                decoder->acquireFrameForTime(currentTime, !previousFrame);
            if (frame) {
              currentFrames[itemId] = frame;
            } else {
              frame = previousFrame;
            }
            if (frame) {
              frames.setProperty(
                  runtime, entry.first.c_str(),
                  jsi::Object::createFromHostObject(runtime, frame));
            }
          }
          return frames;
        });
  } else if (propName == "decodeCompositionAudio") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "decodeCompositionAudio"),
        1,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          auto currentTime =
              CMTimeMakeWithSeconds(arguments[0].asNumber(), NSEC_PER_SEC);
          auto audioSamples = jsi::Object(runtime);
          for (const auto& entry : itemDecoders) {
            auto itemId = entry.first;
            auto decoder = entry.second;

            if (!decoder->shouldExtractAudio()) {
              continue;
            }

            decoder->advanceAudioDecoder(currentTime);

            auto audioSample = decoder->getAudioSampleForTime(currentTime);
            if (audioSample) {
              auto audioSampleObj = std::make_shared<AudioSample>(audioSample);
              currentAudioSamples[itemId] = audioSampleObj;
              audioSamples.setProperty(
                  runtime, entry.first.c_str(),
                  jsi::Object::createFromHostObject(runtime, audioSampleObj));
              CFRelease(audioSample);
            }
          }
          return audioSamples;
        });
  } else if (propName == "dispose") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "dispose"), 0,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          this->release();
          return jsi::Value::undefined();
        });
  }
  return jsi::Value::undefined();
}

void VideoCompositionFramesExtractorSyncHostObject::release() {
  try {
    for (const auto& entry : itemDecoders) {
      auto decoder = entry.second;
      if (decoder) {
        entry.second->release();
      }
    }
  } catch (...) {
  }
  itemDecoders.clear();
  currentFrames.clear();
  currentAudioSamples.clear();
}

} // namespace RNSkiaVideo

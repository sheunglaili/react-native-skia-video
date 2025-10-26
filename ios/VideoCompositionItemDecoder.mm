#include "VideoCompositionItemDecoder.h"
#include "MTLTextureUtils.h"

#import "AVAssetTrackUtils.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

namespace RNSkiaVideo {

VideoCompositionItemDecoder::VideoCompositionItemDecoder(
    std::shared_ptr<VideoCompositionItem> item, bool realTime, int audioSampleRate,
    int audioChannelCount) {
  this->item = item;
  this->realTime = realTime;
  this->audioSampleRate = audioSampleRate;
  this->audioChannelCount = audioChannelCount;
  lock = [[NSObject alloc] init];
  NSString* path =
      [NSString stringWithCString:item->path.c_str()
                         encoding:[NSString defaultCStringEncoding]];
  asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  if (!videoTrack) {
    throw [NSError
        errorWithDomain:@"com.azzapp.rnskv"
                   code:0
               userInfo:@{
                 NSLocalizedDescriptionKey : [NSString
                     stringWithFormat:@"No video track for path: %@", path]
               }];
  }
  width = videoTrack.naturalSize.width;
  height = videoTrack.naturalSize.height;
  rotation = AVAssetTrackUtils::GetTrackRotationInDegree(videoTrack);
  currentFrame = nullptr;
  this->setupReader(kCMTimeZero);

  CGSize resolution = item->resolution;
  if (resolution.width <= 0 || resolution.height <= 0) {
    resolution.width = width;
    resolution.height = height;
  }
  mtlTexture = [MTLTextureUtils createMTLTextureForVideoOutput:resolution];
  if (!mtlTexture) {
    throw std::runtime_error("Failed to create persistent Metal texture!");
  }

  // Initialize audio track if not muted
  audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
  if (audioTrack && !item->muted) {
    this->setupAudioReader(kCMTimeZero);
  }
}

void VideoCompositionItemDecoder::setupReader(CMTime initialTime) {
  NSError* error = nil;
  assetReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
  if (error) {
    throw error;
  }

  auto startTime = CMTimeMakeWithSeconds(item->startTime, NSEC_PER_SEC);
  auto position = CMTimeMakeWithSeconds(
      MAX((CMTimeGetSeconds(initialTime) - item->compositionStartTime), 0),
      NSEC_PER_SEC);
  assetReader.timeRange = CMTimeRangeMake(
      CMTimeAdd(startTime, position),
      CMTimeSubtract(CMTimeMakeWithSeconds(item->duration, NSEC_PER_SEC),
                     position));

  NSDictionary* pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES
  };
  CGSize resolution = item->resolution;
  if (resolution.width > 0 && resolution.height > 0) {
    pixBuffAttributes =
        [NSMutableDictionary dictionaryWithDictionary:pixBuffAttributes];
    [pixBuffAttributes setValue:@(resolution.width)
                         forKey:(id)kCVPixelBufferWidthKey];
    [pixBuffAttributes setValue:@(resolution.height)
                         forKey:(id)kCVPixelBufferHeightKey];
    width = resolution.width;
    height = resolution.height;
  }

  AVAssetReaderOutput* assetReaderOutput =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack
                                       outputSettings:pixBuffAttributes];
  [assetReader addOutput:assetReaderOutput];
  [assetReader startReading];
}

#define DECODER_INPUT_TIME_ADVANCE 0.1

void VideoCompositionItemDecoder::advanceDecoder(CMTime currentTime) {
  @synchronized(lock) {
    CMTime startTime = CMTimeMakeWithSeconds(item->startTime, NSEC_PER_SEC);
    CMTime compositionStartTime =
        CMTimeMakeWithSeconds(item->compositionStartTime, NSEC_PER_SEC);
    CMTime position =
        CMTimeAdd(startTime, CMTimeSubtract(currentTime, compositionStartTime));
    CMTime inputPosition =
        realTime
            ? CMTimeAdd(position, CMTimeMakeWithSeconds(
                                      DECODER_INPUT_TIME_ADVANCE, NSEC_PER_SEC))
            : position;
    CMTime duration = CMTimeMakeWithSeconds(item->duration, NSEC_PER_SEC);
    CMTime endTime = CMTimeAdd(startTime, duration);

    if (realTime && CMTimeCompare(endTime, inputPosition) < 0 && !hasLooped) {
      setupReader(kCMTimeZero);
      hasLooped = true;
      // we will loop so we want to decode the first frames of the next loop
      inputPosition =
          CMTimeAdd(position, CMTimeMakeWithSeconds(DECODER_INPUT_TIME_ADVANCE,
                                                    NSEC_PER_SEC));
    }

    auto framesQueue = hasLooped ? &nextLoopFrames : &decodedFrames;
    CMTime latestSampleTime = kCMTimeInvalid;
    if (framesQueue->size() > 0) {
      latestSampleTime =
          CMTimeMakeWithSeconds(framesQueue->back().first, NSEC_PER_SEC);
    }

    while (!CMTIME_IS_VALID(latestSampleTime) ||
           (CMTimeCompare(latestSampleTime, inputPosition) < 0 &&
            CMTimeCompare(endTime, inputPosition) >= 0)) {
      if (assetReader.status != AVAssetReaderStatusReading) {
        break;
      }
      AVAssetReaderOutput* assetReaderOutput =
          [assetReader.outputs firstObject];
      CMSampleBufferRef sampleBuffer = [assetReaderOutput copyNextSampleBuffer];
      if (!sampleBuffer) {
        break;
      }
      if (CMSampleBufferGetNumSamples(sampleBuffer) == 0) {
        CFRelease(sampleBuffer);
        continue;
      }
      auto timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
      auto buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
      if (buffer) {
        framesQueue->push_back(
            std::make_pair(CMTimeGetSeconds(timeStamp), sampleBuffer));
      } else {
        CFRelease(sampleBuffer);
      }

      latestSampleTime = timeStamp;
    }
  }
}

std::shared_ptr<VideoFrame>
VideoCompositionItemDecoder::acquireFrameForTime(CMTime currentTime,
                                                 bool force) {
  if (hasLooped && CMTIME_IS_VALID(lastRequestedTime) &&
      CMTimeCompare(currentTime, lastRequestedTime) < 0) {
    hasLooped = false;
    for (const auto& frame : decodedFrames) {
      CFRelease(frame.second);
    }
    decodedFrames = nextLoopFrames;
    nextLoopFrames.clear();
  }
  lastRequestedTime = currentTime;

  CMTime position = CMTimeAdd(
      CMTimeMakeWithSeconds(item->startTime, NSEC_PER_SEC),
      CMTimeMakeWithSeconds(
          MAX((CMTimeGetSeconds(currentTime) - item->compositionStartTime), 0),
          NSEC_PER_SEC));

  CMSampleBufferRef nextFrame = nil;
  auto it = decodedFrames.begin();
  while (it != decodedFrames.end()) {
    auto timestamp = CMTimeMakeWithSeconds(it->first, NSEC_PER_SEC);
    if (CMTimeCompare(timestamp, position) <= 0 ||
        (force && nextFrame == nullptr)) {
      if (nextFrame != nullptr) {
        CFRelease(nextFrame);
      }
      nextFrame = it->second;
      it = decodedFrames.erase(it);
    } else {
      break;
    }
  }
  if (nextFrame) {
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(nextFrame);
    [MTLTextureUtils updateTexture:mtlTexture with:buffer];
    CFRelease(nextFrame);
    return std::make_shared<VideoFrame>(mtlTexture, width, height, rotation);
  }
  return nullptr;
}

void VideoCompositionItemDecoder::seekTo(CMTime currentTime) {
  @synchronized(lock) {
    release();
    setupReader(currentTime);
  }
}

void VideoCompositionItemDecoder::release() {
  @synchronized(lock) {
    if (assetReader) {
      [assetReader cancelReading];
      assetReader = nullptr;
    }
    for (const auto& frame : decodedFrames) {
      CFRelease(frame.second);
    }
    decodedFrames.clear();
    for (const auto& frame : nextLoopFrames) {
      CFRelease(frame.second);
    }
    nextLoopFrames.clear();
    hasLooped = false;
    lastRequestedTime = kCMTimeInvalid;
    [mtlTexture setPurgeableState:MTLPurgeableStateEmpty];
    currentFrame = nullptr;
    mtlTexture = nil;

    // Audio cleanup
    if (audioReader) {
      [audioReader cancelReading];
      audioReader = nullptr;
    }
    for (const auto& sample : decodedAudioSamples) {
      CFRelease(sample.second);
    }
    decodedAudioSamples.clear();
    for (const auto& sample : nextLoopAudioSamples) {
      CFRelease(sample.second);
    }
    nextLoopAudioSamples.clear();
    audioHasLooped = false;
    lastAudioRequestedTime = kCMTimeInvalid;
    audioTrack = nil;
  }
}

void VideoCompositionItemDecoder::setupAudioReader(CMTime initialTime) {
  if (!audioTrack) return;

  NSError* error = nil;
  audioReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
  if (error) {
    throw error;
  }

  auto startTime = CMTimeMakeWithSeconds(item->startTime, NSEC_PER_SEC);
  auto position = CMTimeMakeWithSeconds(
      MAX((CMTimeGetSeconds(initialTime) - item->compositionStartTime), 0),
      NSEC_PER_SEC);
  audioReader.timeRange = CMTimeRangeMake(
      CMTimeAdd(startTime, position),
      CMTimeSubtract(CMTimeMakeWithSeconds(item->duration, NSEC_PER_SEC),
                     position));

  // Audio output settings - Linear PCM for ArrayBuffer compatibility
  NSDictionary* audioSettings = @{
    AVFormatIDKey : @(kAudioFormatLinearPCM),
    AVSampleRateKey : @(audioSampleRate),
    AVNumberOfChannelsKey : @(audioChannelCount),
    AVLinearPCMBitDepthKey : @(16),
    AVLinearPCMIsFloatKey : @(NO),
    AVLinearPCMIsBigEndianKey : @(NO),
    AVLinearPCMIsNonInterleaved : @(NO)
  };

  AVAssetReaderOutput* audioReaderOutput =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack
                                       outputSettings:audioSettings];
  [audioReader addOutput:audioReaderOutput];
  [audioReader startReading];
}

void VideoCompositionItemDecoder::advanceAudioDecoder(CMTime currentTime) {
  if (!audioTrack || item->muted) return;

  @synchronized(lock) {
    CMTime startTime = CMTimeMakeWithSeconds(item->startTime, NSEC_PER_SEC);
    CMTime compositionStartTime =
        CMTimeMakeWithSeconds(item->compositionStartTime, NSEC_PER_SEC);
    CMTime position =
        CMTimeAdd(startTime, CMTimeSubtract(currentTime, compositionStartTime));
    CMTime inputPosition =
        realTime
            ? CMTimeAdd(position, CMTimeMakeWithSeconds(
                                      DECODER_INPUT_TIME_ADVANCE, NSEC_PER_SEC))
            : position;
    CMTime duration = CMTimeMakeWithSeconds(item->duration, NSEC_PER_SEC);
    CMTime endTime = CMTimeAdd(startTime, duration);

    if (realTime && CMTimeCompare(endTime, inputPosition) < 0 && !audioHasLooped) {
      setupAudioReader(kCMTimeZero);
      audioHasLooped = true;
      inputPosition =
          CMTimeAdd(position, CMTimeMakeWithSeconds(DECODER_INPUT_TIME_ADVANCE,
                                                    NSEC_PER_SEC));
    }

    auto audioQueue = audioHasLooped ? &nextLoopAudioSamples : &decodedAudioSamples;
    CMTime latestSampleTime = kCMTimeInvalid;
    if (audioQueue->size() > 0) {
      latestSampleTime =
          CMTimeMakeWithSeconds(audioQueue->back().first, NSEC_PER_SEC);
    }

    while (!CMTIME_IS_VALID(latestSampleTime) ||
           (CMTimeCompare(latestSampleTime, inputPosition) < 0 &&
            CMTimeCompare(endTime, inputPosition) >= 0)) {
      if (audioReader.status != AVAssetReaderStatusReading) {
        break;
      }
      AVAssetReaderOutput* audioReaderOutput =
          [audioReader.outputs firstObject];
      CMSampleBufferRef audioSampleBuffer = [audioReaderOutput copyNextSampleBuffer];
      if (!audioSampleBuffer) {
        break;
      }
      if (CMSampleBufferGetNumSamples(audioSampleBuffer) == 0) {
        CFRelease(audioSampleBuffer);
        continue;
      }
      auto timeStamp = CMSampleBufferGetPresentationTimeStamp(audioSampleBuffer);
      auto audioBuffer = CMSampleBufferGetDataBuffer(audioSampleBuffer);
      if (audioBuffer) {
        audioQueue->push_back(
            std::make_pair(CMTimeGetSeconds(timeStamp), audioSampleBuffer));
      } else {
        CFRelease(audioSampleBuffer);
      }

      latestSampleTime = timeStamp;
    }
  }
}

CMSampleBufferRef VideoCompositionItemDecoder::getAudioSampleForTime(CMTime currentTime) {
  if (!audioTrack || item->muted) return nil;

  if (audioHasLooped && CMTIME_IS_VALID(lastAudioRequestedTime) &&
      CMTimeCompare(currentTime, lastAudioRequestedTime) < 0) {
    audioHasLooped = false;
    for (const auto& sample : decodedAudioSamples) {
      CFRelease(sample.second);
    }
    decodedAudioSamples = nextLoopAudioSamples;
    nextLoopAudioSamples.clear();
  }
  lastAudioRequestedTime = currentTime;

  CMTime position = CMTimeAdd(
      CMTimeMakeWithSeconds(item->startTime, NSEC_PER_SEC),
      CMTimeMakeWithSeconds(
          MAX((CMTimeGetSeconds(currentTime) - item->compositionStartTime), 0),
          NSEC_PER_SEC));

  CMSampleBufferRef nextAudioSample = nil;
  auto it = decodedAudioSamples.begin();
  while (it != decodedAudioSamples.end()) {
    auto timestamp = CMTimeMakeWithSeconds(it->first, NSEC_PER_SEC);
    if (CMTimeCompare(timestamp, position) <= 0) {
      if (nextAudioSample != nullptr) {
        CFRelease(nextAudioSample);
      }
      nextAudioSample = it->second;
      it = decodedAudioSamples.erase(it);
    } else {
      break;
    }
  }

  return nextAudioSample;
}

bool VideoCompositionItemDecoder::shouldExtractAudio() {
  return !item->muted && audioTrack != nil;
}

} // namespace RNSkiaVideo

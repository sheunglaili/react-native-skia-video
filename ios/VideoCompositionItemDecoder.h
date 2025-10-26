#pragma once

#import "VideoComposition.h"
#import "VideoFrame.h"
#import <AVFoundation/AVFoundation.h>
#import <list>

using namespace facebook;

namespace RNSkiaVideo {

class VideoCompositionItemDecoder {
public:
  VideoCompositionItemDecoder(std::shared_ptr<VideoCompositionItem> item,
                              bool realTime, 
                              int audioSampleRate,
                              int audioChannelCount);
  void advanceDecoder(CMTime currentTime);
  void seekTo(CMTime currentTime);
  std::shared_ptr<VideoFrame> acquireFrameForTime(CMTime currentTime,
                                                  bool force);
  void advanceAudioDecoder(CMTime currentTime);
  CMSampleBufferRef getAudioSampleForTime(CMTime currentTime);
  bool shouldExtractAudio();
  void release();

private:
  NSObject* lock;
  bool realTime = false;
  bool hasLooped = false;
  std::shared_ptr<VideoCompositionItem> item;
  double width;
  double height;
  int rotation;
  int audioSampleRate;
  int audioChannelCount;
  AVURLAsset* asset;
  AVAssetTrack* videoTrack;
  AVAssetReader* assetReader;
  id<MTLTexture> mtlTexture;
  std::list<std::pair<double, CMSampleBufferRef>> decodedFrames;
  std::list<std::pair<double, CMSampleBufferRef>> nextLoopFrames;
  CMTime lastRequestedTime = kCMTimeInvalid;
  std::shared_ptr<VideoFrame> currentFrame;

  AVAssetTrack* audioTrack;
  AVAssetReader* audioReader;
  std::list<std::pair<double, CMSampleBufferRef>> decodedAudioSamples;
  std::list<std::pair<double, CMSampleBufferRef>> nextLoopAudioSamples;
  CMTime lastAudioRequestedTime = kCMTimeInvalid;
  bool audioHasLooped = false;

  void setupReader(CMTime initialTime);
  void setupAudioReader(CMTime initialTime);
};

} // namespace RNSkiaVideo

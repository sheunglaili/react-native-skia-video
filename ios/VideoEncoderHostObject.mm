#import "VideoEncoderHostObject.h"
#import "JsiUtils.h"
#import <Metal/Metal.h>
#import <future>

NS_INLINE NSError* createErrorWithMessage(NSString* message) {
  return [NSError errorWithDomain:@"com.azzapp.rnskv"
                             code:0
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

namespace RNSkiaVideo {

VideoEncoderHostObject::VideoEncoderHostObject(std::string outPath, int width,
                                               int height, int frameRate,
                                               int bitRate) {
  this->outPath = outPath;
  this->width = width;
  this->height = height;
  this->frameRate = frameRate;
  this->bitRate = bitRate;
}

std::vector<jsi::PropNameID>
VideoEncoderHostObject::getPropertyNames(jsi::Runtime& rt) {
  std::vector<jsi::PropNameID> result;
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("prepare")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("encodeFrame")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("encodeAudio")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("finishWriting")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("dispose")));
  return result;
}

jsi::Value VideoEncoderHostObject::get(jsi::Runtime& runtime,
                                       const jsi::PropNameID& propNameId) {
  auto propName = propNameId.utf8(runtime);
  if (propName == "prepare") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "prepare"), 0,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          prepare();
          return jsi::Value::undefined();
        });
  }
  if (propName == "encodeFrame") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "encodeFrame"), 2,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          auto serializedTexture =
              arguments[0].asObject(runtime).getProperty(runtime, "mtlTexture");
          void* texturePointer = reinterpret_cast<void*>(
              serializedTexture.asBigInt(runtime).asUint64(runtime));
          auto texture = (__bridge id<MTLTexture>)texturePointer;
          auto time =
              CMTimeMakeWithSeconds(arguments[1].asNumber(), NSEC_PER_SEC);

          encodeFrame(texture, time);
          return jsi::Value::undefined();
        });
  }
  if (propName == "encodeAudio") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "encodeAudio"), 2,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          if (count < 2 || !arguments[0].isObject()) {
            return jsi::Value::undefined();
          }
          
          auto arrayBuffer = arguments[0].asObject(runtime).getArrayBuffer(runtime);
          uint8_t* audioData = arrayBuffer.data(runtime);
          size_t audioDataSize = arrayBuffer.size(runtime);
          auto time = CMTimeMakeWithSeconds(arguments[1].asNumber(), NSEC_PER_SEC);
          
          encodeAudioBuffer(audioData, audioDataSize, time);
          return jsi::Value::undefined();
        });
  }
  if (propName == "finishWriting") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "finishWriting"), 0,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          finish();
          return jsi::Value::undefined();
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

void VideoEncoderHostObject::prepare() {
  NSError* error = nil;
  assetWriter = [AVAssetWriter
      assetWriterWithURL:
          [NSURL fileURLWithPath:
                     [NSString
                         stringWithCString:outPath.c_str()
                                  encoding:[NSString defaultCStringEncoding]]]
                fileType:AVFileTypeMPEG4
                   error:&error];
  if (error) {
    throw error;
  }

  auto videoSettings = @{
    AVVideoCodecKey : AVVideoCodecTypeH264,
    AVVideoWidthKey : @(width),
    AVVideoHeightKey : @(height),
    AVVideoCompressionPropertiesKey : @{
      AVVideoAverageBitRateKey : @(bitRate),
      AVVideoMaxKeyFrameIntervalKey : @(frameRate),
      AVVideoProfileLevelKey : AVVideoProfileLevelH264HighAutoLevel,
    }
  };

  assetWriterInput =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:videoSettings];
  assetWriterInput.expectsMediaDataInRealTime = NO;
  assetWriterInput.performsMultiPassEncodingIfSupported = YES;
  if ([assetWriter canAddInput:assetWriterInput]) {
    [assetWriter addInput:assetWriterInput];
  } else {
    throw assetWriter.error
        ?: createErrorWithMessage(@"could not add output to asset writter");
    return;
  }

  // Add audio writer input - AAC with hardcoded sensible defaults
  NSDictionary* audioSettings = @{
    AVFormatIDKey : @(kAudioFormatMPEG4AAC),
    AVSampleRateKey : @(44100),
    AVNumberOfChannelsKey : @(2),
    AVEncoderBitRateKey : @(128000)
  };
  
  audioWriterInput =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                         outputSettings:audioSettings];
  audioWriterInput.expectsMediaDataInRealTime = NO;
  if ([assetWriter canAddInput:audioWriterInput]) {
    [assetWriter addInput:audioWriterInput];
  }

  [assetWriter startWriting];
  [assetWriter startSessionAtSourceTime:kCMTimeZero];

  device = MTLCreateSystemDefaultDevice();
  commandQueue = [device newCommandQueue];

  NSDictionary* attributes = @{
    (NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (NSString*)kCVPixelBufferWidthKey : @(width),
    (NSString*)kCVPixelBufferHeightKey : @(height),
    (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  CVReturn status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      (__bridge CFDictionaryRef)attributes, &pixelBuffer);

  if (status != kCVReturnSuccess) {
    throw createErrorWithMessage(@"Could not extract pixels from frame");
    return;
  }

  MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:width
                                  height:height
                               mipmapped:NO];
  descriptor.storageMode = MTLStorageModeShared;
  descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
  cpuAccessibleTexture = [device newTextureWithDescriptor:descriptor];
}

void VideoEncoderHostObject::encodeFrame(id<MTLTexture> mlTexture,
                                         CMTime time) {
  id<MTLCommandBuffer> commandBuffer =
      [commandQueue commandBufferWithUnretainedReferences];
  id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
  [blitEncoder copyFromTexture:mlTexture
                   sourceSlice:0
                   sourceLevel:0
                  sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(mlTexture.width, mlTexture.height, 1)
                     toTexture:cpuAccessibleTexture
              destinationSlice:0
              destinationLevel:0
             destinationOrigin:MTLOriginMake(0, 0, 0)];

  [blitEncoder endEncoding];
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  void* pixelBufferBytes = CVPixelBufferGetBaseAddress(pixelBuffer);
  if (pixelBufferBytes == NULL) {
    throw createErrorWithMessage(@"Could not extract pixels from frame");
  }
  size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

  MTLRegion region = MTLRegionMake2D(0, 0, width, height);

  [cpuAccessibleTexture getBytes:pixelBufferBytes
                     bytesPerRow:bytesPerRow
                      fromRegion:region
                     mipmapLevel:0];
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

  int attempt = 0;
  while (!assetWriterInput.isReadyForMoreMediaData) {
    if (attempt > 100) {
      throw createErrorWithMessage(@"AVAssetWriter unavailable");
    }
    attempt++;
    usleep(5000);
  }

  CMSampleBufferRef sampleBuffer = NULL;
  CMVideoFormatDescriptionRef formatDescription = NULL;
  CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer,
                                               &formatDescription);
  CMSampleTimingInfo timingInfo = {.presentationTimeStamp = time,
                                   .decodeTimeStamp = kCMTimeInvalid};

  NSError* error;
  if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true,
                                         NULL, NULL, formatDescription,
                                         &timingInfo, &sampleBuffer) != 0) {
    error = createErrorWithMessage(@"Could not create image buffer from frame");
  }
  if (sampleBuffer) {
    if (![assetWriterInput appendSampleBuffer:sampleBuffer]) {
      if (assetWriter.status == AVAssetWriterStatusFailed) {
        error = assetWriter.error
                    ?: createErrorWithMessage(
                           @"Could not append frame data to AVAssetWriter");
      }
    }
    CFRelease(sampleBuffer);
  } else {
    error = createErrorWithMessage(@"Failed to create sampleBuffer");
  }
  if (formatDescription) {
    CFRelease(formatDescription);
  };
  if (error) {
    throw error;
  }
}

void VideoEncoderHostObject::encodeAudioBuffer(uint8_t* audioData, size_t audioDataSize, CMTime time) {
  if (!audioWriterInput || !audioWriterInput.isReadyForMoreMediaData) {
    return;
  }

  if (audioDataSize == 0 || audioData == nullptr) {
    return;
  }

  // Create CMBlockBuffer from ArrayBuffer data (copy required for async processing)
  CMBlockBufferRef blockBuffer = NULL;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault,
      NULL,  // Allocate new memory
      audioDataSize,
      kCFAllocatorDefault,
      NULL,
      0,
      audioDataSize,
      0,
      &blockBuffer);

  if (status != noErr || !blockBuffer) {
    return;
  }

  // Copy data from ArrayBuffer to CMBlockBuffer
  status = CMBlockBufferReplaceDataBytes(audioData, blockBuffer, 0, audioDataSize);
  if (status != noErr) {
    CFRelease(blockBuffer);
    return;
  }

  // Create audio format description for Linear PCM (matching our decoder output)
  AudioStreamBasicDescription asbd = {0};
  asbd.mSampleRate = 44100;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
  asbd.mBitsPerChannel = 16;
  asbd.mChannelsPerFrame = 2;
  asbd.mBytesPerFrame = asbd.mChannelsPerFrame * (asbd.mBitsPerChannel / 8);
  asbd.mFramesPerPacket = 1;
  asbd.mBytesPerPacket = asbd.mBytesPerFrame * asbd.mFramesPerPacket;

  CMFormatDescriptionRef formatDescription = NULL;
  status = CMAudioFormatDescriptionCreate(
      kCFAllocatorDefault,
      &asbd,
      0,
      NULL,
      0,
      NULL,
      NULL,
      &formatDescription);

  if (status != noErr || !formatDescription) {
    CFRelease(blockBuffer);
    return;
  }

  // Calculate number of samples
  size_t numSamples = audioDataSize / asbd.mBytesPerFrame;

  // Create CMSampleBuffer
  CMSampleBufferRef sampleBuffer = NULL;
  status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      kCFAllocatorDefault,
      blockBuffer,
      formatDescription,
      numSamples,
      time,
      NULL,
      &sampleBuffer);

  CFRelease(blockBuffer);
  CFRelease(formatDescription);

  if (status != noErr || !sampleBuffer) {
    return;
  }

  // Append to audio writer input
  if ([audioWriterInput isReadyForMoreMediaData]) {
    [audioWriterInput appendSampleBuffer:sampleBuffer];
  }

  CFRelease(sampleBuffer);
}

void VideoEncoderHostObject::finish() {

  __block std::promise<void> promise;
  std::future<void> future = promise.get_future();
  __block NSError* error = nil;
  [assetWriter finishWritingWithCompletionHandler:^{
    if (assetWriter.status == AVAssetWriterStatusFailed) {
      error = assetWriter.error ?: createErrorWithMessage(@"Failed to export");
      return;
    }
    promise.set_value();
  }];

  future.wait();
  if (error != nil) {
    throw error;
  }
}

void VideoEncoderHostObject::release() {
  if (assetWriter && assetWriter.status == AVAssetWriterStatusWriting) {
    [assetWriter cancelWriting];
  }
  assetWriter = nil;
  assetWriterInput = nil;
  audioWriterInput = nil;
  CVPixelBufferRelease(pixelBuffer);
  pixelBuffer = NULL;
  if (cpuAccessibleTexture) {
    [cpuAccessibleTexture setPurgeableState:MTLPurgeableStateEmpty];
  }
  cpuAccessibleTexture = nil;
  commandQueue = nil;
  device = nil;
}

} // namespace RNSkiaVideo

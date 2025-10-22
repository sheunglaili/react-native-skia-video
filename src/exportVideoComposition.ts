import { runOnJS } from 'react-native-reanimated';
import { Platform } from 'react-native';
import { Skia, BlendMode } from '@shopify/react-native-skia';
import type { SkSurface } from '@shopify/react-native-skia';
import type {
  AudioSample,
  ExportOptions,
  FrameDrawer,
  VideoComposition,
  VideoEncoder,
  VideoCompositionExtractorSync,
} from './types';
import RNSkiaVideoModule from './RNSkiaVideoModule';
import { runOnNewThread } from './utils/thread';

const Promise = global.Promise;

const OS = Platform.OS;

/**
 * Exports a video composition to a video file.
 *
 * @returns A promise that resolves when the export is complete.
 */
export const exportVideoComposition = async <T = undefined>({
  videoComposition,
  drawFrame,
  beforeDrawFrame,
  afterDrawFrame,
  onProgress,
  ...options
}: {
  /**
   * The video composition to export.
   */
  videoComposition: VideoComposition;
  /**
   * The function used to draw the video frames.
   */
  drawFrame: FrameDrawer<T>;
  /**
   * A function that is called before drawing each frame.
   * The return value will be passed to the drawFrame function as context.
   *
   * @returns The context that will be passed to the drawFrame function.
   */
  beforeDrawFrame?: () => T;
  /**
   * A function that is called after drawing each frame.
   * @param context The context returned by the beforeDrawFrame function.
   */
  afterDrawFrame?: (context: T) => void;
  /**
   * A callback that is called when a frame is drawn.
   * @returns
   */
  onProgress?: (progress: {
    framesCompleted: number;
    nbFrames: number;
  }) => void;
} & ExportOptions): Promise<void> =>
  new Promise<void>((resolve, reject) => {
    runOnNewThread(() => {
      'worklet';

      let surface: SkSurface | null = null;
      let frameExtractor: VideoCompositionExtractorSync | null = null;
      let encoder: VideoEncoder | null = null;
      const { width, height } = options;
      try {
        surface = Skia.Surface.MakeOffscreen(width, height);
        if (!surface) {
          throw new Error('Failed to create Skia surface');
        }

        encoder = RNSkiaVideoModule.createVideoEncoder(options);
        encoder.prepare();

        frameExtractor =
          RNSkiaVideoModule.createVideoCompositionExtractorSync(
            videoComposition
          );
        frameExtractor.start();

        const nbFrames = videoComposition.duration * options.frameRate;
        const canvas = surface.getCanvas();
        const clearColor = Skia.Color('#00000000');
        for (let i = 0; i < nbFrames; i++) {
          const currentTime = i / options.frameRate;
          const frames = frameExtractor.decodeCompositionFrames(currentTime);
          const audioSamples =
            frameExtractor.decodeCompositionAudio(currentTime);

          canvas.drawColor(clearColor, BlendMode.Clear);
          const context = beforeDrawFrame?.() as any;
          drawFrame({
            context,
            canvas,
            videoComposition,
            currentTime,
            frames,
            width: options.width,
            height: options.height,
          });
          surface.flush();

          // On iOS and macOS, the first flush is not synchronous,
          // so we need to wait for the next frame
          if (i === 0 && (OS === 'ios' || OS === 'macos')) {
            RNSkiaVideoModule.usleep?.(1000);
          }
          const texture = surface.getNativeTextureUnstable();
          encoder.encodeFrame(texture, currentTime);

          // Mix and encode audio
          const mixedAudioBuffer = mixAudioBuffers(audioSamples);
          if (mixedAudioBuffer) {
            encoder.encodeAudio(mixedAudioBuffer, currentTime);
          }

          afterDrawFrame?.(context);
          if (onProgress) {
            runOnJS(onProgress)({
              framesCompleted: i + 1,
              nbFrames,
            });
          }
        }
      } catch (e) {
        runOnJS(reject)(e);
        return;
      } finally {
        frameExtractor?.dispose();
        surface?.dispose();
      }

      try {
        encoder!.finishWriting();
      } catch (e) {
        runOnJS(reject)(e);
        return;
      } finally {
        encoder?.dispose();
      }
      runOnJS(resolve)();
    });
  });

/**
 * Mixes multiple audio samples into a single ArrayBuffer using additive mixing
 * with automatic volume scaling to prevent clipping.
 */
function mixAudioBuffers(
  audioSamples: Record<string, AudioSample>
): ArrayBuffer | null {
  'worklet';
  const samples = Object.values(audioSamples);
  if (samples.length === 0) return null;
  if (samples.length === 1) return samples[0]?.buffer || null;

  // Simple additive mixing with volume scaling
  const volumeScale = 1.0 / samples.length;
  const mixedBuffer = new ArrayBuffer(samples[0]!.buffer.byteLength);
  const mixedView = new Int16Array(mixedBuffer);

  samples.forEach((sample) => {
    const view = new Int16Array(sample.buffer);
    for (let i = 0; i < view.length; i++) {
      mixedView[i]! += view[i]! * volumeScale;
    }
  });

  return mixedBuffer;
}

import { runOnJS } from 'react-native-reanimated';
import { Platform } from 'react-native';
import { Skia, BlendMode } from '@shopify/react-native-skia';
import type { SkSurface } from '@shopify/react-native-skia';
import type {
  ExportOptions,
  FrameDrawer,
  VideoComposition,
  VideoEncoder,
  VideoCompositionExtractorSync,
  AudioMixer,
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
// Default audio encoding settings
const DEFAULT_AUDIO_SAMPLE_RATE = 44100;
const DEFAULT_AUDIO_BIT_RATE = 128000;
const DEFAULT_AUDIO_CHANNEL_COUNT = 2;

export const exportVideoComposition = async <T = undefined>({
  videoComposition,
  drawFrame,
  beforeDrawFrame,
  afterDrawFrame,
  mixAudio,
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
   * The function used to mixed the audios.
   */
  mixAudio?: AudioMixer;
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

      // Apply audio defaults
      const encoderOptions: ExportOptions = {
        ...options,
        audioSampleRate: options.audioSampleRate ?? DEFAULT_AUDIO_SAMPLE_RATE,
        audioBitRate: options.audioBitRate ?? DEFAULT_AUDIO_BIT_RATE,
        audioChannelCount:
          options.audioChannelCount ?? DEFAULT_AUDIO_CHANNEL_COUNT,
      };

      try {
        surface = Skia.Surface.MakeOffscreen(width, height);
        if (!surface) {
          throw new Error('Failed to create Skia surface');
        }

        encoder = RNSkiaVideoModule.createVideoEncoder(encoderOptions);
        encoder.prepare();

        frameExtractor = RNSkiaVideoModule.createVideoCompositionExtractorSync(
          videoComposition,
          encoderOptions.audioSampleRate,
          encoderOptions.audioChannelCount
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
          const mixedAudioBuffer = mixAudio?.({
            audioSamples,
            context,
            currentTime,
            videoComposition,
          });
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

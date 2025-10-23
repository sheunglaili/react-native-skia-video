# React Native Skia Video

Video encoding/decoding support for [React Native Skia](https://github.com/Shopify/react-native-skia)

> ⚠️ This library is still a beta in a very unstable state

## Installation

```sh
npm install @azzapp/react-native-skia-video
```

## Usage

### VideoPlayer

The `useVideoPlayer` is a custom React hook used in the context of a video player component. This hook encapsulates the logic for playing, pausing, and controlling video playback. It returns a [Reanimated](https://docs.swmansion.com/react-native-reanimated/) shared value that holds the current frame of the playing video.

```js
import { Canvas, Image, Skia } from '@shopify/react-native-skia';
import { useVideoPlayer } from '@azzapp/react-native-skia-video';

const MyVideoPlayer = ({ uri, width, height }) =>{

  const { currentFrame } = useVideoPlayer({ uri })

  const videoImage = useDerivedValue(() => {
    const frame = currentFrame.value;
    if (!frame) {
      return null;
    }
    return Skia.Image.MakeImageFromNativeTextureUnstable(
      frame.texture,
      frame.width,
      frame.height
    );
  });

  return (
    <Canvas style={{ width, height }}>
      <Image image={videoImage} width={width} height={height}  />
    </Canvas>
  );
}

```

### VideoComposition

This library offers a mechanism for previewing and exporting videos created by compositing frames from other videos, utilizing the React Native Skia imperative API.

To preview a composition, use the `useVideoCompositionPlayer` hook:

```js
import { Canvas, Picture, Skia } from '@shopify/react-native-skia';
import { useVideoCompositionPlayer } from '@azzapp/react-native-skia-video'

const videoComposition = {
  duration: 10,
  items: [{
    id: 'video1',
    path: '/local/path/to/video.mp4',
    compositionStartTime: 0,
    startTime: 0,
    duration: 5
  }, {
    id: 'video2',
    path: '/local/path/to/video2.mp4',
    compositionStartTime: 5,
    startTime: 5,
    duration: 5
  }]
}

const drawFrame: FrameDrawer = ({
  videoComposition,
  canvas,
  currentTime,
  frames,
  height,
  width,
}) => {
  'worklet';
  const frame = frames[currentTime < 5 ? 'video1' : 'video2'];
  const image = Skia.Image.MakeImageFromNativeTextureUnstable(
    frame.texture,
    width,
    height,
  );
  const paint = Skia.Paint();
  canvas.drawImage(image, 0, 0, paint)
}


const MyVideoCompositionPlayer = ({ width, height }) =>{
  const { currentFrame } = useVideoCompositionPlayer({
    composition: videoComposition,
    autoPlay: true,
    drawFrame,
    width,
    height,
  });

  return (
    <Canvas style={{ width, height }}>
      <Image image={currentFrame} x={0} y={0} width={width} height={height} />
    </Canvas>
  );
}
```

To export a composition, use the `exportVideoComposition` function:

```js
import { exportVideoComposition } from '@azzapp/react-native-skia-video'

exportVideoComposition({
  videoComposition,
  drawFrame,
  outPath: '/path/to/output',
  bitRate: 3500000,
  frameRate: 60,
  width: 1920,
  height: 1080,
}).then(() => {
  console.log('Video exported successfully!')
})
```

#### Audio Support

The Video Composition system supports audio encoding. You can provide a `mixAudio` callback to mix audio from multiple video sources:

```js
const mixAudio = ({ audioSamples, currentTime, videoComposition }) => {
  'worklet';
  // audioSamples is a Record<string, AudioSample> keyed by video item ID
  const video1Audio = audioSamples['video1'];
  const video2Audio = audioSamples['video2'];
  
  // Return the audio buffer you want to encode for this frame
  // You can mix, process, or select audio as needed
  if (currentTime < 5 && video1Audio) {
    return video1Audio.buffer;
  } else if (video2Audio) {
    return video2Audio.buffer;
  }
  return null; // No audio for this frame
};

exportVideoComposition({
  videoComposition,
  drawFrame,
  mixAudio, // Add the audio mixer
  outPath: '/path/to/output',
  bitRate: 3500000,
  frameRate: 60,
  width: 1920,
  height: 1080,
  // Optional audio encoding settings (defaults shown):
  audioSampleRate: 44100,    // Hz
  audioBitRate: 128000,      // bits per second (128 kbps)
  audioChannelCount: 2,      // stereo
})
```

**Audio Configuration Parameters:**
- `audioSampleRate` (optional): Sample rate in Hz (default: 44100)
- `audioBitRate` (optional): Bit rate in bits per second (default: 128000)
- `audioChannelCount` (optional): Number of channels - 1 for mono, 2 for stereo (default: 2)
- `mixAudio` (optional): Callback function to mix/process audio samples


### Video Capabilities (Android only)

On android you might needs to check the video capabilities of your device before exporting a video. This library provides 2 android specific functions for this purpose : 

#### getDecodingCapabilitiesFor(mimetype: string)

This function will returns the decoding capabilities of this device for the given mime type (most of the time you should check `video/avc`).

#### getValidEncoderConfigurations(width: number, height: number, frameRate: number, bitRate: number)

This function will returns a list of valid configuration in regards of your device encoding capabilities with the corresponding encoder.
If the provided parameters are not supported the returned configurations will be overridden with valid parameters (by decreasing, resolution, framerate or bitrate) while keeping the same aspect ratio.


## Contributing

See the [contributing guide](CONTRIBUTING.md) to learn how to contribute to the repository and the development workflow.

## License

MIT

---

Made with [create-react-native-library](https://github.com/callstack/react-native-builder-bob)

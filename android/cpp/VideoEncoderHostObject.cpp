#include "VideoEncoderHostObject.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES/gl.h>
#include <GLES/glext.h>
#include <android/hardware_buffer_jni.h>

namespace RNSkiaVideo {
using namespace facebook::jni;

local_ref<VideoEncoder>
VideoEncoder::create(std::string& outPath, int width, int height, int frameRate,
                     int bitRate, std::optional<std::string> encoderName) {
  return newInstance(outPath, width, height, frameRate, bitRate,
                     encoderName.has_value() ? encoderName.value() : nullptr);
}

void VideoEncoder::prepare() const {
  static const auto prepareMethod = getClass()->getMethod<void()>("prepare");
  prepareMethod(self());
}

void VideoEncoder::makeGLContextCurrent() const {
  static const auto makeGLContextCurrentMethod =
      getClass()->getMethod<void()>("makeGLContextCurrent");
  makeGLContextCurrentMethod(self());
}

void VideoEncoder::encodeFrame(jint texture, jdouble time) const {
  static const auto encodeFrameMethod =
      getClass()->getMethod<void(jint, jdouble)>("encodeFrame");
  encodeFrameMethod(self(), texture, time);
}

void VideoEncoder::encodeAudio(alias_ref<JByteBuffer> audioBuffer, jdouble time) const {
  static const auto encodeAudioMethod =
      getClass()->getMethod<void(alias_ref<JByteBuffer>, jdouble)>("encodeAudio");
  encodeAudioMethod(self(), audioBuffer, time);
}

void VideoEncoder::release() const {
  static const auto releaseMethod = getClass()->getMethod<void()>("release");
  releaseMethod(self());
}

void VideoEncoder::finishWriting() const {
  static const auto finishWritingMethod =
      getClass()->getMethod<void()>("finishWriting");
  finishWritingMethod(self());
}

VideoEncoderHostObject::VideoEncoderHostObject(
    std::string& outPath, int width, int height, int frameRate, int bitRate,
    std::optional<std::string> encoderName) {
  framesExtractor = make_global(VideoEncoder::create(
      outPath, width, height, frameRate, bitRate, encoderName));
}

VideoEncoderHostObject::~VideoEncoderHostObject() {
  this->release();
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
  if (propName == "encodeFrame") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "encodeFrame"), 2,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          framesExtractor->makeGLContextCurrent();
          auto texId = arguments[0]
                           .asObject(runtime)
                           .getProperty(runtime, "glID")
                           .asNumber();

          framesExtractor->encodeFrame((int)texId, arguments[1].asNumber());
          skiaContextHolder->makeCurrent();
          return jsi::Value::undefined();
        });
  } else if (propName == "encodeAudio") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "encodeAudio"), 2,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          if (count < 2 || !arguments[0].isObject()) {
            return jsi::Value::undefined();
          }

          auto arrayBuffer = arguments[0].asObject(runtime).getArrayBuffer(runtime);
          auto time = arguments[1].asNumber();

          // Get the underlying DirectByteBuffer from the ArrayBuffer
          // Assuming the ArrayBuffer is backed by a MutableBuffer with JNI ByteBuffer
          uint8_t* data = arrayBuffer.data(runtime);
          size_t size = arrayBuffer.size(runtime);

          // Create a JNI ByteBuffer from the ArrayBuffer data
          auto byteBuffer = JByteBuffer::allocateDirect(size);
          void* bufferData = byteBuffer->getDirectAddress();
          std::memcpy(bufferData, data, size);

          framesExtractor->encodeAudio(byteBuffer, time);
          return jsi::Value::undefined();
        });
  } else if (propName == "prepare") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "prepare"), 0,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          if (!released.test()) {
            skiaContextHolder = std::make_shared<SkiaContextHolder>();
            framesExtractor->prepare();
            skiaContextHolder->makeCurrent();
          }
          return jsi::Value::undefined();
        });
  } else if (propName == "finishWriting") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "finishWriting"), 0,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          if (!released.test()) {
            framesExtractor->finishWriting();
          }
          return jsi::Value::undefined();
        });
  }
  if (propName == "dispose") {
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

void VideoEncoderHostObject::release() {
  if (!released.test_and_set()) {
    framesExtractor->release();
    framesExtractor = nullptr;
  }
}

} // namespace RNSkiaVideo

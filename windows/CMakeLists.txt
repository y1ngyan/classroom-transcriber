cmake_minimum_required(VERSION 3.20)
project(classroom-transcriber-win LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(CT_WITH_WHISPER "拉取并链接 whisper.cpp（OFF 时只编核心库与单元测试，不需要网络）" ON)
option(CT_BUILD_TESTS "构建不依赖 whisper / 模型的单元测试" ON)

# 告警只加在**我们自己的**目标上：whisper.cpp 是 FetchContent 拉进来的第三方代码，
# 拿它的告警淹掉自己的输出没有意义
if(MSVC)
  # /utf-8 不是可选项：源码里的中文字面量与注释是 UTF-8，MSVC 默认按本地代码页读，
  # 会给出 C4819 并让程序输出变成乱码
  set(CT_COMPILE_OPTIONS /utf-8 /W4)
else()
  set(CT_COMPILE_OPTIONS -Wall -Wextra -Wpedantic)
endif()

# 纯 C++ 核心：WAV 解析 / 重采样 / 门控 / 取窗 / 合并。
# **不链接 whisper**，所以单元测试可以完全脱离模型与网络跑
add_library(ct-core STATIC
  src/audio.cpp
  src/speech_gate.cpp
  src/window_plan.cpp
  src/merge.cpp
)
target_include_directories(ct-core PUBLIC src)
target_compile_options(ct-core PRIVATE ${CT_COMPILE_OPTIONS})

if(CT_WITH_WHISPER)
  # whisper.cpp 是唯一能直接跨平台复用的推理层（macOS 版也用它）
  include(FetchContent)
  FetchContent_Declare(
    whisper
    GIT_REPOSITORY https://github.com/ggml-org/whisper.cpp.git
    GIT_TAG        v1.7.4
    GIT_SHALLOW    TRUE
  )
  set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
  set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(whisper)

  add_executable(ct-win src/main.cpp)
  target_link_libraries(ct-win PRIVATE ct-core whisper)
  target_compile_options(ct-win PRIVATE ${CT_COMPILE_OPTIONS})
endif()

if(CT_BUILD_TESTS)
  enable_testing()
  add_executable(ct-win-tests tests/test_main.cpp)
  target_link_libraries(ct-win-tests PRIVATE ct-core)
  target_compile_options(ct-win-tests PRIVATE ${CT_COMPILE_OPTIONS})
  add_test(NAME ct-win-tests COMMAND ct-win-tests)
endif()

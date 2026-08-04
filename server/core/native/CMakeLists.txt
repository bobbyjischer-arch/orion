cmake_minimum_required(VERSION 3.15)
project(orion_crypto LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Разделяемая библиотека для ctypes (грузится из core/crypto.py).
add_library(orion_crypto SHARED orion_crypto.cpp)
set_target_properties(orion_crypto PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  POSITION_INDEPENDENT_CODE ON)

# Копируем .so/.dll/.dylib рядом с исходником, где его ищет crypto.py.
add_custom_command(TARGET orion_crypto POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:orion_crypto>
          ${CMAKE_CURRENT_SOURCE_DIR}/$<TARGET_FILE_NAME:orion_crypto>)

# Автономный self-test: проверяет known-answer вектор.
add_executable(orion_crypto_test orion_crypto.cpp)
target_compile_definitions(orion_crypto_test PRIVATE ORION_CRYPTO_MAIN)

enable_testing()
add_test(NAME kat COMMAND orion_crypto_test)

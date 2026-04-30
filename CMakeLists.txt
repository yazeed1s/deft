cmake_minimum_required(VERSION 3.12 FATAL_ERROR)
project(Deft)

# Transport backend selection
option(USE_CXL "Build with simulated CXL backend instead of RDMA" OFF)

# disable boost warning
add_definitions(-DBOOST_COROUTINES_NO_DEPRECATION_WARNING)

# Compiler/toolchain guards for C++20 features (e.g., <=>).
if(CMAKE_VERSION VERSION_LESS 3.12)
    message(FATAL_ERROR "CMake >= 3.12 is required for C++20 (found ${CMAKE_VERSION}). Run script/cloudlab_setup.sh to bootstrap newer CMake.")
endif()
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 10)
    message(FATAL_ERROR "GCC >= 10 is required for C++20 (found ${CMAKE_CXX_COMPILER_VERSION}). Run script/cloudlab_setup.sh to bootstrap gcc-10.")
endif()

#Compiler options
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
add_compile_options(-Wall -Wno-deprecated-declarations -Wsign-compare)

# Link Options — transport-dependent
if(USE_CXL)
  add_definitions(-DUSE_CXL)
  set(LINKS_FLAGS "-lcityhash -lboost_coroutine -lpthread -lmemcached -lgflags -lrt")
else()
  add_definitions(-DUSE_RDMA)
  set(LINKS_FLAGS "-lcityhash -lboost_coroutine -lpthread -libverbs -lmemcached -lgflags")
endif()

set(INCLUDE_BASE ${PROJECT_SOURCE_DIR}/include)
include_directories(${INCLUDE_BASE})

#Source file define
set(COMMON_SRC ${PROJECT_SOURCE_DIR}/src)

#Used by both server and clients
file(GLOB_RECURSE COMMON_FILE ${COMMON_SRC}/*.cpp)

# Exclude transport-specific sources that don't apply
if(USE_CXL)
  list(FILTER COMMON_FILE EXCLUDE REGEX ".*/rdma/.*\\.cpp$")
else()
  list(FILTER COMMON_FILE EXCLUDE REGEX ".*/cxl/.*\\.cpp$")
endif()

add_library(deft STATIC ${COMMON_FILE})
link_libraries(deft)

file(GLOB TEST_SRC ${PROJECT_SOURCE_DIR}/test/*.cpp)
foreach (TEST ${TEST_SRC})
    get_filename_component(TEST_NAME ${TEST} NAME_WE)
    add_executable(${TEST_NAME} ${TEST})
    target_link_libraries(${TEST_NAME} ${LINKS_FLAGS})
endforeach()

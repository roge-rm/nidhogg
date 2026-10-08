# Builds Chompi firmwares as Linux programs. Each firmware's vendored source is
# copied into the build tree and the patches in patches/<fw>/ applied there;
# third_party/ itself is never edited.
cmake_minimum_required(VERSION 3.16)
project(nidhogg_host C CXX)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# norns runs 32-bit ARM on a Pi 3 (Cortex-A53) or Pi 4 (Cortex-A72), both ARMv8.
# DaisySP's fmax/fmin use the ARMv8 vmaxnm/vminnm instructions on ARM.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^arm")
    add_compile_options(-mcpu=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard)
endif()

set(CHOMPI_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/chompi)
find_package(Threads REQUIRED)
# The real-time runner needs JACK and liblo; without them only the offline
# harness is built.
find_path(JACK_INC jack/jack.h)
find_library(JACK_LIB jack)
find_path(LO_INC lo/lo.h)
find_library(LO_LIB lo)
# The SuperCollider plugin needs SC's plugin headers.
find_path(SC_INC SC_PlugIn.h PATH_SUFFIXES SuperCollider/plugin_interface)

# Chompi builds at -O3, gnu++14 and gnu11, without exceptions or RTTI.
# The STM32 HAL names hardware.h uses come in through the HAL shim.
set(FW_CXX_FLAGS -O3 -g -std=gnu++14 -fno-exceptions -fno-rtti -w
    -include ${CMAKE_CURRENT_SOURCE_DIR}/shim/include/stm32h7xx_hal.h)
set(FW_C_FLAGS -O3 -g -std=gnu11 -w)

function(nidhogg_firmware fw)
    cmake_parse_arguments(A "" "UGEN;OSC_PORT" "SOURCES;LIBDAISY" ${ARGN})
    set(V ${CHOMPI_DIR}/${fw})
    set(B ${CMAKE_CURRENT_BINARY_DIR}/fw/${fw})

    file(REMOVE_RECURSE ${B})
    file(COPY ${V}/src/ DESTINATION ${B}/src)
    file(GLOB patches ${CMAKE_CURRENT_SOURCE_DIR}/patches/${fw}/*.patch)
    list(SORT patches)
    foreach(p ${patches})
        execute_process(COMMAND patch -s -p1 -d ${B}/src -i ${p} RESULT_VARIABLE r)
        if(r)
            message(FATAL_ERROR "patch failed: ${p}")
        endif()
    endforeach()
    execute_process(COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/cmake/case_links.py ${B}/src)
    file(GLOB_RECURSE vendored ${V}/src/*)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${patches} ${vendored})

    set(fw_src)
    foreach(s ${A_SOURCES})
        list(APPEND fw_src ${B}/src/${s})
    endforeach()
    file(GLOB_RECURSE daisysp_src ${V}/libs/DaisySP/Source/*.cpp)
    file(GLOB daisysp_dirs LIST_DIRECTORIES true ${V}/libs/DaisySP/Source/*)
    list(FILTER daisysp_dirs EXCLUDE REGEX "\\.h$")
    set(libdaisy_src)
    foreach(s ${A_LIBDAISY})
        list(APPEND libdaisy_src ${V}/libs/libDaisy/src/${s})
    endforeach()

    set(lib nidhogg-${fw}-fw)
    add_library(${lib} STATIC
        ${fw_src}
        ${daisysp_src}
        ${libdaisy_src}
        ${V}/libs/coreJSON/source/core_json.c
        ${CMAKE_CURRENT_SOURCE_DIR}/shim/vhw.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/shim/daisy_impl.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/shim/ff_posix.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/shim/posix_dir.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/src/board_${fw}.cpp)
    target_include_directories(${lib} PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/shim/include
        ${V}/libs/libDaisy/src
        ${V}/libs/libDaisy/src/sys
        ${V}/libs/libDaisy/fatfs
        ${V}/libs/DaisySP/Source
        ${daisysp_dirs}
        ${V}/libs/coreJSON/source/include
        ${CMAKE_CURRENT_SOURCE_DIR}/shim
        ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_compile_definitions(${lib} PUBLIC NIDHOGG_HOST)
    # The firmware's own main() runs in a thread the host starts.
    set_source_files_properties(${B}/src/chompi_main.cpp PROPERTIES
        COMPILE_DEFINITIONS main=chompi_firmware_main)
    target_compile_options(${lib} PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:${FW_CXX_FLAGS}>
        $<$<COMPILE_LANGUAGE:C>:${FW_C_FLAGS}>)
    # The host's own files use a normal C++ setup.
    set_source_files_properties(
        ${CMAKE_CURRENT_SOURCE_DIR}/shim/vhw.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/shim/ff_posix.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/shim/posix_dir.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/src/board_${fw}.cpp
        PROPERTIES COMPILE_OPTIONS "-std=gnu++17;-frtti;-fexceptions;-Wall")
    target_link_libraries(${lib} PUBLIC Threads::Threads)
    # Also linked into a SuperCollider plugin.
    set_property(TARGET ${lib} PROPERTY POSITION_INDEPENDENT_CODE ON)

    add_executable(nidhogg-${fw}-render src/render.cpp)
    target_compile_options(nidhogg-${fw}-render PRIVATE -O2 -Wall)
    target_link_libraries(nidhogg-${fw}-render ${lib})

    if(JACK_INC AND JACK_LIB AND LO_INC AND LO_LIB)
        add_executable(nidhogg-${fw} src/run.cpp src/bridge.cpp)
        target_compile_options(nidhogg-${fw} PRIVATE -O2 -Wall)
        target_include_directories(nidhogg-${fw} PRIVATE ${JACK_INC} ${LO_INC})
        target_link_libraries(nidhogg-${fw} ${lib} ${JACK_LIB} ${LO_LIB})
    endif()

    if(SC_INC AND LO_INC AND LO_LIB)
        # scsynth loads every plugin at once, and each firmware carries its own
        # libDaisy, so nothing but the plugin entry points may be visible.
        add_library(${A_UGEN} MODULE src/ugen.cpp src/bridge.cpp)
        set_target_properties(${A_UGEN} PROPERTIES PREFIX "" CXX_VISIBILITY_PRESET hidden)
        target_compile_definitions(${A_UGEN} PRIVATE NIDHOGG_UGEN=${A_UGEN}
                                   NIDHOGG_OSC_PORT=${A_OSC_PORT})
        target_compile_options(${A_UGEN} PRIVATE -O2 -Wall)
        target_include_directories(${A_UGEN} PRIVATE ${SC_INC} ${SC_INC}/../common ${LO_INC})
        target_link_libraries(${A_UGEN} ${lib} ${LO_LIB})
        target_link_options(${A_UGEN} PRIVATE -Wl,--exclude-libs,ALL -Wl,-Bsymbolic)
    endif()
endfunction()

nidhogg_firmware(tape UGEN NidhoggTape OSC_PORT 57140
    SOURCES chompi_main.cpp encoder.cpp FileStreamingManager.cpp
    LIBDAISY ui/UI.cpp hid/switch.cpp hid/midi.cpp hid/midi_parser.cpp util/color.cpp)

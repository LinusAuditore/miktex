## SignAppBundle.cmake
##
## Copyright (C) 2026 Christian Schenk
##
## This file is free software; the copyright holder gives
## unlimited permission to copy and/or distribute it, with or
## without modifications, as long as this notice is preserved.

# fixup_bundle rewrites load commands and thereby invalidates code
# signatures; on arm64, every image must carry a valid signature.
# Re-sign inside out: dylibs (incl. plugins), frameworks, then the
# outer application bundle.  No --deep.

set(app_dir "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/MiKTeX Console.app")

function(sign_item what item)
  execute_process(COMMAND codesign --force --sign - "${item}" RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "codesign failed (${what}): ${item}")
  endif()
endfunction()

file(GLOB_RECURSE dylibs "${app_dir}/*.dylib")
foreach(f ${dylibs})
  sign_item("dylib" "${f}")
endforeach()

file(GLOB frameworks "${app_dir}/Contents/Frameworks/*.framework")
foreach(f ${frameworks})
  sign_item("framework" "${f}")
endforeach()

sign_item("application bundle" "${app_dir}")

execute_process(COMMAND codesign --verify --strict "${app_dir}" RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "codesign --verify --strict failed: ${app_dir}")
endif()
message(STATUS "signed and verified: ${app_dir}")

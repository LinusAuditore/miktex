## FixupTeXworksBundle.cmake
##
## Copyright (C) 2026 Christian Schenk
##
## This file is free software; the copyright holder gives
## unlimited permission to copy and/or distribute it, with or
## without modifications, as long as this notice is preserved.

# The nested TeXworks bundle ships without frameworks and libraries
# of its own; retarget its @executable_path references (which resolve
# inside its own bundle) to the enclosing MiKTeX Console bundle and
# point Qt at the shared plugins.

set(app_dir "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/MiKTeX Console.app")
set(tw_app "${app_dir}/Contents/bin/miktex-texworks.app")
set(tw_exe "${tw_app}/Contents/MacOS/miktex-texworks")

if(EXISTS "${tw_exe}")
  execute_process(COMMAND otool -L "${tw_exe}" OUTPUT_VARIABLE otool_out)
  string(REPLACE "\n" ";" lines "${otool_out}")
  foreach(line ${lines})
    string(STRIP "${line}" line)
    if(line MATCHES "^@executable_path/\\.\\./")
      string(REGEX REPLACE " *\\(.*\\)" "" dep "${line}")
      string(REGEX REPLACE "^@executable_path/\\.\\./" "@executable_path/../../../../" new "${dep}")
      execute_process(COMMAND install_name_tool -change "${dep}" "${new}" "${tw_exe}")
    endif()
  endforeach()
  file(WRITE "${tw_app}/Contents/Resources/qt.conf" "[Paths]
Plugins = ../../../../PlugIns
")
  message(STATUS "retargeted nested TeXworks bundle")
endif()

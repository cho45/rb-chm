#!/usr/bin/env ruby


require "mkmf"

system(*%W(swig -ruby chmlib.i))

dir_config("chm")
if have_header("chm_lib.h") && have_library("chm", "chm_open")
	create_makefile("chmlib")
end


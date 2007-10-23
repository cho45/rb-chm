#!/usr/bin/env ruby -Ku
#


require "chmlib"
require "nkf"

class Chmlib::Chm
	class ChmError < StandardError; end
	class ResolvError < ChmError; end
	class RetrieveError < ChmError; end

	attr_reader :home, :title

	def initialize(filename)
		@h = Chmlib.chm_open(filename)
		raise ChmError, "Not exists?" unless @h
		get_archive_info()
	end

	def close
		Chmlib.chm_close(@h)
	end

	def index
		return nil unless @index
		return @index_cache if @index_cache

		text = retrieve_object(@index)
		#<OBJECT type="text/sitemap">
		#<param name="Name" value="pushd(path = nil, &amp;block) (c/m Shell) (ruby-src:doc/shell.rd)">
		#<param name="Name" value="pushd(path = nil, ? (c/m Shell) (ruby-src:doc/shell.rd)">
		#<param name="Local" value="refm570.html#L011275">
		#</OBJECT>

		index = {}
		text.scan(/<OBJECT type="text\/sitemap">(.+?)<\/OBJECT>/m) do |m|
			local = m[0][/<param name="Local" value="([^"]+)">/, 1]
			m[0].scan(/<param name="Name" value="([^"]+)">/) do |n|
				n = n[0]
				next unless n
				next if n.empty? or n.match(/^\s+$/)
				n.gsub!(/&amp;/, "&")
				n.gsub!(/&lt;/, "<")
				n.gsub!(/&gt;/, ">")
				n = NKF.nkf("-w", n)
				(index[n] ||= []) << local
			end
		end
		@index_cache = index.to_a
	end

	def get_archive_info
		ui = resolve_object("/#SYSTEM")
		text = Chmlib.chm_retrieve_object(@h, ui, 0, ui.length)
		if ui.length.zero?
			raise "retrieve failed."
		end

		buff = text.unpack("C*")

		index = 0
		size  = ui.length
		while index < size
			cursor = buff[index] + (buff[index+1] * 256)
			case cursor
			when 0
				index += 2
				cursor = buff[index] + (buff[index+1] * 256)
				index += 2
				@topics = '/' + text[index...index+cursor-1]
			when 1
				index += 2
				cursor = buff[index] + (buff[index+1] * 256)
				index += 2
				@index = '/' + text[index...index+cursor-1]
			when 2
				index += 2
				cursor = buff[index] + (buff[index+1] * 256)
				index += 2
				@home = '/' + text[index...index+cursor-1]
			when 3
				index += 2
				cursor = buff[index] + (buff[index+1] * 256)
				index += 2
				@title = text[index...index+cursor-1]
			when 4
				index += 2
				cursor = buff[index] + (buff[index+1] * 256)
				index += 2
				@lcid = buff[index] + (buff[index+1] * 256)
			when 6
				index += 2
				cursor = buff[index] + (buff[index+1] * 256)
				index += 2
				tmp = text[index...index+cursor-1]
				unless @topics
					tmp1 = '/' + tmp + '.hhc'
					tmp2 = '/' + tmp + '.hhk'
					ui1  = Chmlib::ChmUnitInfo.new
					ui2  = Chmlib::ChmUnitInfo.new
					res1 = Chmlib.chm_resolve_object(@h, tmp1, ui1)
					res2 = Chmlib.chm_resolve_object(@h, tmp2, ui2)
					if (not @topics) && (res1 == Chmlib::CHM_RESOLVE_SUCCESS)
						@topics = '/' + tmp + '.hhc'
					end
					if (not @index) && (res2 == Chmlib::CHM_RESOLVE_SUCCESS):
						@index = '/' + tmp + '.hhk'
					end
				end
			when 16
				index += 2
				cursor = buff[index] + (buff[index+1] * 256)
				index += 2
				@encoding = text[index...index+cursor-1]
			else
				index += 2
				cursor = buff[index] + (buff[index+1] * 256)
				index += 2
			end
			index += cursor
		end
		get_windows_info
	end

	def get_windows_info
		text = retrieve_object("/#WINDOWS")
		num_entries, entry_size = text.unpack("VV")

		return if num_entries < 1

		text = retrieve_object("/#WINDOWS", 8, entry_size)
		return if text.length <  entry_size

		toc_index, idx_index, dft_index = text.unpack("V3")

		text = retrieve_object("/#STRINGS")

		unless @topics
			@topics = text[toc_index..-1].unpack("Z*")
			@topics = "/#{@topics}" unless @topics[0] == ?/
		end

		unless @index
			@index = text[tdx_index..-1].unpack("Z*")
			@index = "/#{@index}" unless @index[0] == ?/
		end

		unless dft_index == 0
			@home = text[dft_index..-1].unpack("Z*")
			@home = "/#{@home}" unless @home[0] == ?/
		end
	rescue ResolvError
	end

	def resolve_object(path)
		ui = Chmlib::ChmUnitInfo.new
		unless Chmlib.chm_resolve_object(@h, path, ui) == Chmlib::CHM_RESOLVE_SUCCESS
			raise ResolvError
		end
		ui
	end

	def retrieve_object(path, offset=0, length=nil)
		ui = resolve_object(path)
		length = ui.length unless length
		text = Chmlib.chm_retrieve_object(@h, ui, offset, length)
		if ui.length.zero?
			raise RetrieveError
		end
		text
	end
end

if $0 == __FILE__
	chm = Chmlib::Chm.new("/Users/cho45/htmlhelp/rubymanjp.chm")
	require "pp"
	chm.index #cache
	puts "ok"
	pp chm.index.select {|k,v| /split/i === k }
end

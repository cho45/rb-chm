#!/usr/bin/env ruby -Ku
#


require "chmlib"
require "strscan"
require "nkf"

class Chmlib::Chm
	class ChmError < StandardError; end
	class ResolvError < ChmError; end
	class RetrieveError < ChmError; end

	attr_reader :home

	def initialize(filename)
		@filename = filename
		@h = Chmlib.chm_open(filename)
		raise ChmError, "Not exists?" unless @h
		get_archive_info()
	end

	def close
		Chmlib.chm_close(@h)
	end

	def title
		NKF.nkf("-w", @title)
	end

	def home
		if File.basename(@filename, ".chm") == File.basename(@home)
			@home = self.topics.flatten.find {|i| i[:local] }[:local]
		else
			@home
		end
	end

	def unescape!(n)
		n.gsub!(/&lt;/, "<")
		n.gsub!(/&gt;/, ">")
		n.gsub!(/&quot;/, "\"")
		n.gsub!(/&amp;/, "&")
		n
	end

	# keyword index
	def index
		return nil unless @index
		return @index_cache if @index_cache

		text = NKF.nkf("-w", retrieve_object(@index))
		#<OBJECT type="text/sitemap">
		#<param name="Name" value="pushd(path = nil, &amp;block) (c/m Shell) (ruby-src:doc/shell.rd)">
		#<param name="Name" value="pushd(path = nil, ? (c/m Shell) (ruby-src:doc/shell.rd)">
		#<param name="Local" value="refm570.html#L011275">
		#</OBJECT>

		index = {}
		text.scan(/<OBJECT\s+type="text\/sitemap">(.+?)<\/OBJECT>/m) do |m|
			local = m[0][/<param\s+name="Local"\s+value="([^"]+)">/, 1]
			m[0].scan(/<param\s+name="Name"\s+value="([^"]+)">/) do |n|
				n = n[0]
				next unless n
				next if n.empty? or n.match(/^\s+$/)
				unescape!(n)
				(index[n] ||= []) << local
			end
		end
		@index_cache = index.to_a
	end

	# table of contents
	def topics
		return nil unless @topics
		return @topics_cache if @topics_cache

		text = NKF.nkf("-w", retrieve_object(@topics))
		result = []

		s = StringScanner.new(text)
		s.skip(/.*?<UL>\s*/m)

		current = result
		level   = []
		while s.scan(/<(LI|UL|\/UL)>\s*/)
			case s[1]
			when "LI"
				s.skip(%r{<OBJECT\s+type="text/sitemap">\s*})
				s.scan(%r{<param\s+name="Name"\s+value="([^"]+)">\s*(<param\s+name="Local"\s+value="([^"]+)">)?\s*})
				current << {
					:name   => unescape!(s[1]),
					:local  => s[3] || "",
					:children => []
				}
				s.skip(%r{.*?</OBJECT>\s*})
			when "UL"
				level << current
				current = current.last[:children]
			when "/UL"
				current = level.pop
			end
		end


		# result = [
		#     {name:"name",local:"",child:[]},
		#     ],
		#
		@topics_cache = result
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
		# logic from Chmox
		windowsData = retrieve_object("/#WINDOWS")
		stringsData = retrieve_object("/#STRINGS")

		if !windowsData.empty? && !stringsData.empty?
			entryCount, entrySize = windowsData.unpack("VV")
			#p "Entries: %d x %d bytes" % [entryCount, entrySize]

			entryIndex = 0
			while entryIndex < entryCount
				entryOffset = 8 + ( entryIndex * entrySize );

				#_title = readTrimmedString( stringsData, readLong( windowsData, entryOffset + 0x14 ) );
				toc_index, idx_index, dft_index = windowsData[entryOffset+0x60,12].unpack("V3")
				@topics = stringsData[toc_index..-1].unpack("Z*")[0] if @topics.nil? || @topics.empty?
				@index  = stringsData[idx_index..-1].unpack("Z*")[0] if @index.nil?  || @index.empty?
				@home   = stringsData[dft_index..-1].unpack("Z*")[0] if @home.nil?   || @home.empty?
				entryIndex += 1
			end
		end
		@topics = "/#{@topics}" unless @topics[0] == ?/
		@index  = "/#{@index}"  unless @index[0]  == ?/
		@home   = "/#{@home}"   unless @home[0]   == ?/
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
	require "pp"
	#chm = Chmlib::Chm.new("/Users/cho45/htmlhelp/rubymanjp.chm")
#	chm.index #cache
#	puts "ok"
#	pp chm.index.select {|k,v| /split/i === k }
	chm = Chmlib::Chm.new("/Users/cho45/htmlhelp/kr2doc.chm")
	pp chm.home
	#pp chm.topics
	chm = Chmlib::Chm.new("/Users/cho45/htmlhelp/gauche-refj-0.8.7.chm")
	pp chm.home
	pp chm.instance_eval { @index }
	pp chm.index
	#pp chm.topics
end

#!/usr/bin/env ruby -Ku -Iext
#


require "chmlib"
require "strscan"
require "nkf"

class Chmlib::Chm
	class ChmError < StandardError; end
	class ResolvError < ChmError; end
	class RetrieveError < ChmError; end

	FTS_HEADER_LEN   = 0x32
	TOPICS_ENTRY_LEN = 16
	COMMON_BUF_LEN   = 1025

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

	def searchable?
		resolve_object("/$FIftiMain")
		resolve_object("/#TOPICS")
		resolve_object("/#STRINGS")
		resolve_object("/#URLTBL")
		resolve_object("/#URLSTR")
		true
	rescue
		false
	end

	def search(text, opt={})
		return [] unless self.searchable?
		(Chmlib.chm_search(@h, text.to_s, 0, 0) || []).map {|url, title|
			[NKF.nkf("-w", title.to_s), url]
		}
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
		#puts text[0, 1000]

		index = {}
		text.scan(/<OBJECT\s+type="text\/sitemap">(.+?)<\/OBJECT>/im) do |m|
			local = m[0][/<param\s+name="Local"\s+value="([^"]+)">/i, 1]
			m[0].scan(/<param\s+name="Name"\s+value="([^"]+)">/i) do |n|
				n = n[0]
				next unless n
				next if n.empty? or n.match(/^\s+$/)
				unescape!(n)
				(index[n] ||= []) << local
			end
		end
		@index_cache = index.to_a
	rescue RetrieveError => e
		return nil
	end

	# table of contents
	def topics
		return nil unless @topics
		return @topics_cache if @topics_cache

		text = NKF.nkf("-w", retrieve_object(@topics))
		result = {:children => []}

		s = StringScanner.new(text)
		s.skip(/.*?(?=<UL>)/m)

		current = [result]
		level   = []
		while s.scan(/\s*<(LI|UL|\/UL)>\s*/)
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
		ui = (path.class == Chmlib::ChmUnitInfo) ? path : resolve_object(path)
		length = ui.length unless length
		text = Chmlib.chm_retrieve_object(@h, ui, offset, length)
		if ui.length.zero?
			raise RetrieveError, path
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
	#pp chm.instance_eval { @index }
	#pp chm.index
	#pp chm.searchable?
	#pp chm.search("list")
	chm = Chmlib::Chm.new("/Users/cho45/htmlhelp/Haskell.chm")
	pp chm.index
end

__END__
	def search(text, whole_words=false)
		ui           = resolve_object("/$FIftiMain")
		header       = retrieve_object(ui, 0, FTS_HEADER_LEN)
		topics       = retrieve_object("/#TOPICS")
		strings      = retrieve_object("/#STRINGS")
		urltbl       = retrieve_object("/#URLTBL")
		urlstr       = retrieve_object("/#URLSTR")

		doc_index_s  = header[0x1E];
		doc_index_r  = header[0x1F];
		code_count_s = header[0x20];
		code_count_r = header[0x21];
		loc_codes_s  = header[0x22];
		loc_codes_r  = header[0x23];
		raise ChmError, "Invalid" if doc_index_s != 2 || code_count_s != 2 || loc_codes_s != 2

		node_offset, tree_depth = header[0x14, 6].unpack("Vv")
		node_len, = header[0x2e, 4].unpack("V")
		p [node_offset, tree_depth, node_len]

		node_offset = get_leaf_node_offset(text, node_offset, node_len, tree_depth, ui)
		p node_offset

		begin
			buffer = retrieve_object(ui, node_offset, node_len)
			free_space, = buffer[6, 2].unpack("v")

			i = 8
			encsz = 0
			word = ""

			while i < node_len - free_space
				word_len = buffer[i]
				pos = buffer[i + 1]
				wrd_buf = buffer[i + 2, word_len - 1]

				if pos == 0
					word = wrd_buf
				else
					word[pos, wrd_buf.length] = wrd_buf
				end

				i += 2 + word_len
				title = buffer[i - 1]

				wlc_count, encsz = be_encint(buffer, i)
				#p [:wlc_count, wlc_count, encsz]
				i += encsz

				wlc_offset, = buffer[i, 4].unpack("V")
				i += 6
#				wlc_offset, encsz = be_encint(buffer, i)
#				i += encsz

				wlc_size, encsz = be_encint(buffer, i)
				i += encsz

				node_offset, = buffer.unpack("V")
				#p [:wlcs, wlc_count, wlc_offset, wlc_size]
				#p node_offset
				
				if whole_words
				else
					if text.casecmp(word) != 0
						process_wlc(wlc_count, wlc_size, wlc_offset, doc_index_r, code_count_r, loc_codes_r, ui)
					end
				end

#
#				if (!title && titles_only)
#					continue;
#
#				if (whole_words && !strcasecmp(text, word)) {
#					partial = pychm_process_wlc (chmfile, wlc_count, wlc_size, 
#							wlc_offset, doc_index_s, 
#							doc_index_r,code_count_s, 
#							code_count_r, loc_codes_s, 
#							loc_codes_r, &ui, &uiurltbl,
#							&uistrings, &uitopics,
#							&uiurlstr, dict);
#					FREE(word);
#					FREE(buffer);
#					return partial;
#				}
#
#				if (!whole_words) {
#					if (!strncasecmp (word, text, strlen(text))) {
#						partial = true;
#						pychm_process_wlc (chmfile, wlc_count, wlc_size, 
#								wlc_offset, doc_index_s, 
#								doc_index_r,code_count_s, 
#								code_count_r, loc_codes_s, 
#								loc_codes_r, &ui, &uiurltbl,
#								&uistrings, &uitopics,
#								&uiurlstr, dict);
#
#					} else if (strncasecmp (text, word, strlen(text)) < -1)
#						break;
#				}
#
			end
		end while (
			!whole_words &&
			word[0, text.length] != text &&
			node_offset.nonzero?
		)
	end

	def process_wlc(wlc_count, wlc_size, wlc_offset, doc_index_r, code_count_r, loc_codes_r, ui)
		buffer = retrieve_object(ui, wlc_offset, wlc_size)
		wlc_bit = 7
		(wlc_count - 1).times do

			if wlc_bit != 7
				off += 1
				wlc_bit = 7
			end

			index += sr_int(buffer + off, &wlc_bit, ds, dr, &length);
			off += length;

			if(chm_retrieve_object(chmfile, topics, entry, 
						index * 16, TOPICS_ENTRY_LEN) == 0) {
				FREE(topic);
				FREE(url);
				FREE(buffer);
				return false;
			}

			combuf[COMMON_BUF_LEN - 1] = 0;
			stroff = get_uint32 (entry + 4);

			FREE (topic);
			if (chm_retrieve_object (chmfile, uistrings, combuf, 
						stroff, COMMON_BUF_LEN - 1) == 0) {
				topic = strdup ("Untitled in index");

			} else {
				combuf[COMMON_BUF_LEN - 1] = 0;

				topic = strdup (combuf);
			}

			urloff = get_uint32 (entry + 8);

			if(chm_retrieve_object (chmfile, uitbl, combuf, 
						urloff, 12) == 0) {
				FREE(buffer);
				return false;
			}

			urloff = get_uint32 (combuf + 8);

			if (chm_retrieve_object (chmfile, urlstr, combuf, 
						urloff + 8, COMMON_BUF_LEN - 1) == 0) {
				FREE(topic);
				FREE(url);
				FREE(buffer);
				return false;
			}

			combuf[COMMON_BUF_LEN - 1] = 0;

			FREE (url);
			url = strdup (combuf);

			if (url && topic) {
	#ifdef __PYTHON__
				PyDict_SetItemString (dict, topic, 
						PyString_FromString (url));
	#else
				printf ("%s ==> %s\n", url, topic);
	#endif
			}

			count = sr_int (buffer + off, &wlc_bit, cs, cr, &length);
			off += length;

			for (j = 0; j < count; ++j) {
				sr_int (buffer + off, &wlc_bit, ls, lr, &length);
				off += length;
			}

		end
	end

	def be_encint(buffer, i)
		result = 0
		length = 0

		begin
			result = result << (length * 7) | (buffer[i] & 0b01111111)
			length += 1

			i += 1
		end while (buffer[i-1] & 0b10000000).nonzero?
		[result, length]
	end

	def get_leaf_node_offset(text, initial_offset, buff_size, tree_depth, ui)
		test_offset = 0
		word = ""
		i = 2
		(tree_depth-1).times do
			return 0 if initial_offset == test_offset

			test_offset = initial_offset;
			buffer = retrieve_object(ui, initial_offset, buff_size)
			free_space, = buffer.unpack("v")
			while i < buff_size - free_space
				word_len = buffer[i]
				pos = buffer[i + 1]
				wrd_buf = buffer[i + 2, word_len - 1]

				if pos == 0
					word = wrd_buf
				else
					word[pos, wrd_buf.length] = wrd_buf
				end

				if text.casecmp(word) <= 0
					initial_offset, = buffer[i + word_len + 1, 4].unpack("V")
					break
				end
				i += word_len + 1 + 4 + 2
			end
		end

		initial_offset = 0 if initial_offset == test_offset
		initial_offset
	end

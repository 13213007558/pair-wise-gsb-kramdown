# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#++

require 'digest'
require 'set'
require 'zlib'
require 'kramdown/converter/html'

module Kramdown

  module Converter

    # Converts a Kramdown::Document to an EPUB 3 publication.
    #
    # The document is split into one XHTML chapter per header at the level configured with the
    # +epub_split_level+ option. Internal references (links of the form +#anchor+) are rewritten to
    # point to the chapter file containing the referenced anchor; duplicate explicit anchors are
    # handled deterministically (the first occurrence wins, later ones get a numeric suffix).
    # Local resources referenced with the +epub_resource_root+ option are packaged together with
    # the chapters and their references are rewritten to their packaged locations.
    #
    # The conversion result is a binary string containing the complete, ZIP-compressed EPUB file.
    # It can be written directly to a file with an +.epub+ extension.
    class Epub < Base

      # Media types for resource file extensions that may appear in an EPUB package.
      MEDIA_TYPES = {
        '.css' => 'text/css; charset=utf-8',
        '.gif' => 'image/gif',
        '.jpeg' => 'image/jpeg',
        '.jpg' => 'image/jpeg',
        '.png' => 'image/png',
        '.svg' => 'image/svg+xml',
        '.webp' => 'image/webp',
        '.ttf' => 'font/ttf',
        '.otf' => 'font/otf',
        '.woff' => 'font/woff',
        '.woff2' => 'font/woff2',
      }.freeze

      DEFAULT_CSS = <<~CSS.freeze
        body { margin: 5%; text-align: justify; }
        h1, h2, h3, h4, h5, h6 { text-align: left; }
        img { max-width: 100%; }
      CSS

      def convert(el)
        instance_variable_set(:@root, deep_copy(el)) # never modify the original tree
        @split_level = @options[:epub_split_level]
        @chapters = split_document(@root)
        normalize_ids
        @anchor_chapter = collect_anchors
        @resources = {}

        render_chapters
        ZipWriter.write(build_files)
      end

      private

      # Deep-copy the element tree. The abbreviation hashes carry default procs which Marshal
      # cannot serialize, so they are temporarily removed and re-attached afterwards.
      def deep_copy(element)
        abbrev_defs = element.options[:abbrev_defs]
        abbrev_attr = element.options[:abbrev_attr]
        defs_proc = abbrev_defs && abbrev_defs.default_proc
        attr_proc = abbrev_attr && abbrev_attr.default_proc
        abbrev_defs.default_proc = nil if abbrev_defs
        abbrev_attr.default_proc = nil if abbrev_attr
        copy = Marshal.load(Marshal.dump(element))
        abbrev_defs.default_proc = defs_proc if abbrev_defs
        abbrev_attr.default_proc = attr_proc if abbrev_attr
        copy.options[:abbrev_defs].default_proc = defs_proc if abbrev_defs
        copy.options[:abbrev_attr].default_proc = attr_proc if abbrev_attr
        copy
      end

      # Split the root element into chapters. Each entry is an array [title, elements] where title
      # is the raw header text of the split header or nil for the front matter (content before the
      # first split header). A front matter chapter is always kept so that each document has at
      # least one chapter.
      def split_document(root)
        chapters = [[nil, []]]
        root.children.each do |child|
          if child.type == :header && child.options[:level] == @split_level
            chapters << [child.options[:raw_text], [child]]
          else
            chapters.last[1] << child
          end
        end
        chapters.select!.with_index {|(_title, elements), index| index.zero? || !elements.empty? }
        chapters
      end

      # Assign missing header IDs and make all IDs unique across the publication, walking the tree
      # in document order. The first element with a given ID keeps it and every later element gets
      # a deterministic numeric suffix (e.g. foo, foo-1, foo-2).
      def normalize_ids
        used = {}
        all_elements(@root) do |element|
          if element.type == :header && element.attr['id'].to_s.empty? && @options[:auto_ids]
            element.attr['id'] = unique_id(header_id_base(element), used)
            next
          end
          id = element.attr['id']
          next if id.nil?
          if used.key?(id)
            warning("Duplicate explicit ID \"#{id}\" - using a unique ID")
            element.attr['id'] = unique_id(id, used)
          else
            used[id] = 0
          end
        end
      end

      # Yield every element of the tree in document order.
      def all_elements(element, &block)
        block.call(element)
        element.children.each {|child| all_elements(child, &block) }
      end

      # Compute the base ID for an automatically generated header ID, honoring the same options as
      # the HTML converter.
      def header_id_base(header)
        str = header.options[:raw_text]
        str = ::Kramdown::Utils::Unidecoder.decode(str) if @options[:transliterated_header_ids]
        base = basic_generate_id(str)
        base = 'section' if base.empty?
        @options[:auto_id_prefix] + base
      end

      # Return an unused ID derived from base, using the same scheme as Base#generate_id.
      def unique_id(base, used)
        if used.key?(base)
          candidate = +"#{base}-#{used[base] += 1}"
          candidate = +"#{base}-#{used[base] += 1}" while used.key?(candidate)
          used[candidate] = 0
          candidate
        else
          used[base] = 0
          base
        end
      end

      # Build a mapping of every ID defined in the document to the zero-based chapter index in
      # which it appears.
      def collect_anchors
        mapping = {}
        @chapters.each_with_index do |(_title, elements), chapter_index|
          elements.each {|element| collect_element_anchors(element, chapter_index, mapping) }
        end
        mapping
      end

      def collect_element_anchors(element, chapter_index, mapping)
        mapping[element.attr['id']] = chapter_index if element.attr['id']
        element.children.each {|child| collect_element_anchors(child, chapter_index, mapping) }
      end

      def render_chapters
        @chapter_files = Array.new(@chapters.length) {|index| format('ch%03d.xhtml', index + 1) }
        @chapter_titles = []
        @chapter_outputs = {}
        @chapters.each_with_index do |(title, elements), index|
          @current_chapter = index
          file_name = format('ch%03d.xhtml', index + 1)
          chapter_title = title || @options[:epub_title]
          @chapter_titles << chapter_title
          @chapter_outputs[file_name] = xhtml_document(chapter_title, rewrite_references(
            render_elements(elements)
          ))
        end
      end

      # Render the given elements with the HTML converter (as XML-safe numeric entities).
      def render_elements(elements)
        chapter_root = @root.dup
        chapter_root.children = elements
        html, html_warnings = Html.convert(chapter_root, @options.merge(entity_output: :numeric))
        @warnings.concat(html_warnings)
        html
      end

      # Rewrite all href/src attributes in the rendered HTML fragment: fragment-only references to
      # anchors in another chapter become cross-file references and local resources are packaged.
      def rewrite_references(html)
        html.gsub(/(\s(?:href|src)=)(['"])(.*?)\2/m) do
          "#{$1}#{$2}#{rewrite_url($3)}#{$2}"
        end
      end

      # Rewrite a single URL found in an href/src attribute.
      def rewrite_url(url)
        path, fragment = split_url(url)
        if path.nil?
          rewrite_fragment_url(fragment)
        elsif local_path?(path)
          package_local_reference(path, fragment)
        else
          url
        end
      end

      # Split a URL into the part before the fragment and the fragment itself. A nil path means
      # that the URL is fragment-only (e.g. "#anchor").
      def split_url(url)
        if (pos = url.index('#'))
          [pos.zero? ? nil : url[0...pos], url[(pos + 1)..]]
        else
          [url, nil]
        end
      end

      # Rewrite a fragment-only reference: anchors located in another chapter need a file prefix;
      # references within the current chapter and unresolved anchors are left untouched.
      def rewrite_fragment_url(fragment)
        target_chapter = @anchor_chapter[fragment]
        if target_chapter && target_chapter != @current_chapter
          "#{@chapter_files[target_chapter]}##{fragment}"
        else
          "##{fragment}"
        end
      end

      # Return whether the given path references a local file instead of e.g. an HTTP resource or
      # a special URI scheme (mailto, tel, data, ...).
      def local_path?(path)
        return false if path.empty? || path.start_with?('//')
        path[/\A[a-zA-Z][a-zA-Z0-9+.-]*:/].nil?
      end

      # Package a local file (resolved relative to the resource root) and return the reference to
      # use in the output. Unresolvable references are left untouched and a warning is issued.
      def package_local_reference(path, fragment)
        root = @options[:epub_resource_root]
        if root.empty?
          warning("Local resource '#{path}' cannot be packaged because epub_resource_root is not set")
          return fragment ? "#{path}##{fragment}" : path
        end

        source = File.expand_path(path, root)
        unless File.file?(source)
          warning("Local resource '#{path}' could not be found in '#{root}'")
          return fragment ? "#{path}##{fragment}" : path
        end
        packaged = register_resource(path, source)
        fragment ? "#{packaged}##{fragment}" : packaged
      end

      # Register a local resource file and return its flat packaged file name. The mapping is
      # deterministic: the same source path always yields the same packaged name and different
      # source paths sharing a basename are disambiguated numerically in encounter order.
      def register_resource(path, source)
        return @resources[path][:packaged] if @resources.key?(path)

        basename = File.basename(path).gsub(/[^a-zA-Z0-9._-]/, '_')
        used = Set.new(@resources.values.map {|entry| entry[:packaged] })
        packaged = basename
        index = 1
        while used.include?(packaged)
          packaged = "#{index}-#{basename}"
          index += 1
        end

        ext = File.extname(path).downcase
        media_type = MEDIA_TYPES[ext] || 'application/octet-stream'
        unless MEDIA_TYPES.key?(ext)
          warning("No known media type for resource '#{path}', using application/octet-stream")
        end
        @resources[path] = {source: source, packaged: packaged, media_type: media_type}
        packaged
      end

      def xhtml_document(title, body)
        lang = xml_escape(@options[:epub_language])
        <<~XHTML
          <?xml version="1.0" encoding="utf-8"?>
          <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="#{lang}" lang="#{lang}">
          <head>
          <title>#{xml_escape(title)}</title>
          <link rel="stylesheet" type="text/css" href="style.css" />
          </head>
          <body>
          #{body.chomp}
          </body>
          </html>
        XHTML
      end

      def xml_escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      def identifier
        @identifier ||= if @options[:epub_identifier].empty?
                          hex = Digest::SHA256.hexdigest(@options[:epub_title])
                          "urn:uuid:#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
                        else
                          @options[:epub_identifier]
                        end
      end

      # Assemble all files of the EPUB package as an ordered array of [path, binary content]. The
      # mimetype file has to be the first entry and is stored uncompressed by the ZIP writer.
      def build_files
        files = [
          ['mimetype', 'application/epub+zip'],
          ['META-INF/container.xml', container_xml],
          ['OEBPS/style.css', DEFAULT_CSS],
          ['OEBPS/nav.xhtml', nav_document],
        ]
        @chapter_files.each do |file_name|
          files << ["OEBPS/#{file_name}", @chapter_outputs[file_name]]
        end
        @resources.each_value do |entry|
          files << ["OEBPS/#{entry[:packaged]}", File.binread(entry[:source])]
        end
        files << ['OEBPS/content.opf', package_document]
        files
      end

      def container_xml
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
              <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
          </container>
        XML
      end

      def nav_document
        items = @chapter_files.each_with_index.map do |file_name, index|
          "      <li><a href=\"#{file_name}\">#{xml_escape(@chapter_titles[index])}</a></li>"
        end.join("\n")
        lang = xml_escape(@options[:epub_language])
        <<~XHTML
          <?xml version="1.0" encoding="utf-8"?>
          <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="#{lang}" lang="#{lang}">
          <head><title>#{xml_escape(@options[:epub_title])}</title></head>
          <body>
          <nav epub:type="toc" id="toc">
          <h1>#{xml_escape(@options[:epub_title])}</h1>
          <ol>
          #{items}
          </ol>
          </nav>
          </body>
          </html>
        XHTML
      end

      def package_document
        manifest = [manifest_item('nav', 'nav.xhtml', 'application/xhtml+xml', 'nav'),
                    manifest_item('style', 'style.css', 'text/css')]
        @chapter_files.each_with_index do |file_name, index|
          manifest << manifest_item("ch#{index + 1}", file_name, 'application/xhtml+xml')
        end
        @resources.each_value do |entry|
          manifest << manifest_item(resource_id(entry[:packaged]), entry[:packaged],
                                    entry[:media_type])
        end

        spine = @chapter_files.each_with_index.map do |_file_name, index|
          "    <itemref idref=\"ch#{index + 1}\"/>"
        end.join("\n")
        creator = @options[:epub_author].empty? ? +'' :
          "  <dc:creator id=\"creator\">#{xml_escape(@options[:epub_author])}</dc:creator>\n"
        lang = xml_escape(@options[:epub_language])
        <<~XML
          <?xml version="1.0" encoding="utf-8"?>
          <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="#{lang}">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">#{xml_escape(identifier)}</dc:identifier>
          #{creator}  <dc:title>#{xml_escape(@options[:epub_title])}</dc:title>
            <dc:language>#{xml_escape(@options[:epub_language])}</dc:language>
            <meta property="dcterms:modified">1970-01-01T00:00:00Z</meta>
          </metadata>
          <manifest>
          #{manifest.join("\n")}
          </manifest>
          <spine>
          #{spine}
          </spine>
          </package>
        XML
      end

      def manifest_item(id, href, media_type, properties = nil)
        properties_attr = properties ? " properties=\"#{properties}\"" : ''
        "    <item id=\"#{id}\" href=\"#{href}\" media-type=\"#{media_type}\"#{properties_attr}/>"
      end

      # Build a valid manifest item ID from a packaged file name.
      def resource_id(packaged_name)
        "res-#{packaged_name.gsub(/[^a-zA-Z0-9]/, '_')}"
      end

      # Minimal, dependency-free ZIP archive writer.
      #
      # Writes the ZIP entries in the given order. The first entry (the EPUB mimetype) is stored
      # uncompressed and without extra fields as required by the OCF specification; all other
      # entries are deflate-compressed. Fixed DOS time/date values are used so that the resulting
      # archive is byte-reproducible.
      class ZipWriter

        STORED = 0
        DEFLATED = 8
        FIXED_DOS_TIME = 0
        FIXED_DOS_DATE = 0x21

        def self.write(files)
          new(files).write
        end

        def initialize(files)
          @files = files
        end

        def write
          io = String.new.force_encoding(Encoding::BINARY)
          central = []

          @files.each_with_index do |(name, content), index|
            data = binary(content)
            compression = index.zero? ? STORED : DEFLATED
            compressed = if compression == DEFLATED
                           deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
                           deflater.deflate(data, Zlib::FINISH).tap { deflater.close }
                         else
                           data
                         end
            crc32 = Zlib.crc32(data)

            local_offset = io.bytesize
            io << local_header(name, compressed, crc32, data.bytesize, compression)
            io << compressed
            central << [name, compressed.bytesize, crc32, data.bytesize, compression,
                        local_offset]
          end

          central_offset = io.bytesize
          central.each do |name, compressed_size, crc32, size, compression, offset|
            io << central_record(name, compressed_size, crc32, size, compression, offset)
          end
          io << end_of_central_directory(central.size, io.bytesize - central_offset,
                                         central_offset)
          io
        end

        private

        def binary(content)
          String(content).dup.force_encoding(Encoding::BINARY)
        end

        def local_header(name, compressed, crc32, size, compression)
          [0x04034b50, 20, 0, compression, FIXED_DOS_TIME, FIXED_DOS_DATE, crc32,
           compressed.bytesize, size, name.bytesize, 0].pack('VvvvvvVVVvv') + binary(name)
        end

        def central_record(name, compressed_size, crc32, size, compression, offset)
          [0x02014b50, 20, 20, 0, compression, FIXED_DOS_TIME, FIXED_DOS_DATE, crc32,
           compressed_size, size, name.bytesize, 0, 0, 0, 0, 0, offset].pack(
             'VvvvvvvVVVvvvvvVV'
           ) + binary(name)
        end

        def end_of_central_directory(count, central_size, central_offset)
          [0x06054b50, 0, 0, count, count, central_size, central_offset, 0].pack('VvvvvVVV')
        end

      end

    end

  end

end

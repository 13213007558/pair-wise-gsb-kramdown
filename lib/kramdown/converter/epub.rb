# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++
#

require 'zlib'
require 'securerandom'
require 'kramdown/converter/html'

module Kramdown

  module Converter

    # Converts a Kramdown::Document to an EPUB 3 electronic book.
    #
    # The document is split into chapters at headers with a level equal to or lower than the
    # +epub_chapter_level+ option. Each chapter is converted to an XHTML content document.
    # Additionally, an EPUB navigation document and a package document (with manifest and spine)
    # are generated and everything, including local resources like images, is packaged into a
    # ZIP archive following the EPUB 3 specification.
    #
    # Links to anchors inside the document are rewritten to point to the correct chapter file.
    # Duplicate anchor names are renamed deterministically: the first occurrence (in document
    # order) keeps its name, later occurrences get a numeric suffix (e.g. +name-1+).
    #
    # The result of the conversion is a binary string containing the EPUB archive.
    class Epub < Html

      # Media types for packaged resources, keyed by lowercase file extension.
      RESOURCE_MEDIA_TYPES = {
        'png' => 'image/png', 'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif', 'svg' => 'image/svg+xml', 'webp' => 'image/webp',
        'avif' => 'image/avif', 'bmp' => 'image/bmp', 'css' => 'text/css',
        'js' => 'application/javascript', 'mp3' => 'audio/mpeg',
        'mp4' => 'video/mp4', 'woff' => 'font/woff', 'woff2' => 'font/woff2',
        'ttf' => 'font/ttf', 'otf' => 'font/otf',
      }.freeze

      # The EPUB mimetype, stored uncompressed as the first archive entry.
      EPUB_MIMETYPE = 'application/epub+zip'

      def apply_template_before?
        false
      end

      def apply_template_after?
        false
      end

      # Convert the document into an EPUB archive and return it as a binary string.
      def convert(el)
        @resources = {}
        @resource_names = {}
        # Work on a deep copy of the document tree so that the original tree is not modified
        # (anchor rewrites and ID assignments would otherwise leak into other conversions).
        root = Element.new(:root, nil, nil, el.options)
        root.children.concat(Marshal.load(Marshal.dump(el.children)))
        assign_header_ids(root)
        chapters = split_chapters(root)
        chapters.each_with_index do |chapter, index|
          chapter[:filename] = format('chapter%03d.xhtml', index + 1)
          chapter[:title] = chapter_title(chapter, index)
        end
        register_anchors(chapters)
        chapters.each {|chapter| process_chapter_references(chapter) }

        files = {}
        files['META-INF/container.xml'] = container_xml
        files['OEBPS/content.opf'] = package_opf(chapters)
        files['OEBPS/nav.xhtml'] = nav_xhtml(chapters)
        chapters.each do |chapter|
          files["OEBPS/#{chapter[:filename]}"] = chapter_xhtml(chapter)
        end
        @resources.each_key do |name|
          files["OEBPS/#{name}"] = File.binread(@resources[name])
        end
        build_epub_archive(files)
      end

      protected

      # Walk the element tree rooted at +el+ in document order, yielding each element. Footnote
      # content (stored in the value of :footnote elements) is walked as well.
      def walk_elements(el, &block)
        yield el
        walk_elements(el.value, &block) if el.type == :footnote && el.value.kind_of?(Element)
        el.children.each {|child| walk_elements(child, &block) }
      end

      # Assign IDs to all headers that don't have one yet so that anchors are stable across
      # chapters (uses a single ID sequence for the whole document).
      def assign_header_ids(root)
        return unless @options[:auto_ids]

        walk_elements(root) do |el|
          el.attr['id'] = generate_id(el.options[:raw_text].to_s) if el.type == :header && !el.attr['id']
        end
      end

      # Split the children of the root element into chapters. A new chapter is started at each
      # header with a level equal to or lower than the configured chapter level.
      def split_chapters(root)
        level = @options[:epub_chapter_level]
        chapters = []
        current = []
        root.children.each do |child|
          if child.type == :header && child.options[:level].to_i <= level
            chapters << current
            current = [child]
          else
            current << child
          end
        end
        chapters << current
        chapters.reject! {|children| children.all? {|c| c.type == :blank } }
        chapters.map {|children| {children: children} }
      end

      # Return the plain text of the element +el+ and its children.
      def extract_text(el)
        el.type == :text ? el.value.to_s : el.children.map {|c| extract_text(c) }.join
      end

      # Return the title of a chapter, derived from its first header.
      def chapter_title(chapter, index)
        header = chapter[:children].find {|c| c.type == :header }
        text = header ? extract_text(header).strip : ''
        text.empty? ? "Chapter #{index + 1}" : text
      end

      # Register all anchor IDs of the document, mapping each ID to the filename of the chapter
      # it is in. Duplicate IDs are renamed deterministically: the first occurrence in document
      # order keeps its ID, later occurrences get a numeric suffix.
      def register_anchors(chapters)
        @anchors = {}
        chapters.each do |chapter|
          chapter[:children].each do |child|
            walk_elements(child) do |el|
              id = el.attr['id']
              next if id.nil? || id.empty?

              if @anchors.key?(id)
                new_id = unique_anchor_id(id)
                el.attr['id'] = new_id
                @anchors[new_id] = chapter[:filename]
              else
                @anchors[id] = chapter[:filename]
              end
            end
          end
        end
      end

      # Return a unique anchor ID derived from +id+ by appending a numeric suffix.
      def unique_anchor_id(id)
        index = 1
        index += 1 while @anchors.key?("#{id}-#{index}")
        "#{id}-#{index}"
      end

      # Rewrite fragment links of the chapter to point to the correct chapter file and package
      # local resources referenced by the chapter.
      def process_chapter_references(chapter)
        chapter[:children].each do |child|
          walk_elements(child) do |el|
            if (href = el.attr['href']) && href =~ /\A#(.+)\z/
              if (target = @anchors[Regexp.last_match(1)])
                el.attr['href'] = "#{target}##{Regexp.last_match(1)}" unless target == chapter[:filename]
              else
                warning("No anchor found for link '#{href}'")
              end
            end
            if (src = el.attr['src']) && local_resource?(src) && (packaged = package_resource(src))
              el.attr['src'] = packaged
            end
          end
        end
      end

      # Return +true+ if the given URI references a local resource (i.e. it has no URI scheme and
      # is not a protocol-relative or fragment-only URI).
      def local_resource?(uri)
        uri !~ %r{\A(?:[a-zA-Z][a-zA-Z0-9+.\-]*:|//)} && !uri.start_with?('#')
      end

      # Package the local resource referenced by +src+ and return its packaged name (relative to
      # the content directory), or +nil+ if the resource could not be found.
      def package_resource(src)
        return @resource_names[src] if @resource_names.key?(src)

        path = File.expand_path(src.sub(%r{\A/}, ''), @options[:epub_resource_dir])
        unless File.file?(path)
          warning("Resource '#{src}' not found - not packaging it")
          return nil
        end

        base = File.basename(src)
        name = "images/#{base}"
        if @resources.key?(name) && @resources[name] != path
          ext = File.extname(base)
          stem = base[0, base.length - ext.length]
          index = 1
          index += 1 while @resources.key?(name = "images/#{stem}-#{index}#{ext}")
        end
        @resources[name] = path
        @resource_names[src] = name
        name
      end

      # Return the media type for the packaged resource +name+.
      def resource_media_type(name)
        RESOURCE_MEDIA_TYPES[File.extname(name).sub(/\A\./, '').downcase] || 'application/octet-stream'
      end

      # Convert the chapter to an XHTML content document.
      def chapter_xhtml(chapter)
        root = Element.new(:root, nil, nil, @root.options)
        root.children.concat(chapter[:children])
        body, warnings = Html.convert(root, @options.merge(template: ''))
        @warnings.concat(warnings)
        xhtml_document(chapter[:title], body)
      end

      # Wrap the given HTML +body+ into a full XHTML document with the given +title+.
      def xhtml_document(title, body)
        lang = escape_html(@options[:epub_language], :attribute)
        <<~XHTML
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE html>
          <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="#{lang}" lang="#{lang}">
          <head>
            <meta charset="UTF-8" />
            <title>#{escape_html(title, :text)}</title>
          </head>
          <body>
          #{body}</body>
          </html>
        XHTML
      end

      # Return the title of the book.
      def book_title(chapters)
        title = @options[:epub_title]
        title.empty? && !chapters.empty? ? chapters.first[:title] : title
      end

      # Generate the EPUB 3 navigation document.
      def nav_xhtml(chapters)
        items = chapters.map do |chapter|
          header = chapter[:children].find {|c| c.type == :header }
          anchor = header && header.attr['id']
          href = chapter[:filename] + (anchor ? "##{anchor}" : '')
          "    <li><a href=\"#{escape_html(href, :attribute)}\">#{escape_html(chapter[:title], :text)}</a></li>"
        end
        body = <<~HTML
          <nav epub:type="toc" id="toc">
            <h1>#{escape_html(book_title(chapters), :text)}</h1>
            <ol>
          #{items.join("\n")}
            </ol>
          </nav>
        HTML
        xhtml_document(book_title(chapters), body)
      end

      # Generate the EPUB 3 package document (metadata, manifest and spine).
      def package_opf(chapters)
        identifier = @options[:epub_identifier]
        identifier = "urn:uuid:#{SecureRandom.uuid}" if identifier.empty?
        manifest = []
        spine = []
        manifest << '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        chapters.each do |chapter|
          id = chapter[:filename].sub(/\.xhtml\z/, '')
          manifest << "    <item id=\"#{id}\" href=\"#{chapter[:filename]}\" media-type=\"application/xhtml+xml\"/>"
          spine << "    <itemref idref=\"#{id}\"/>"
        end
        (@resources || {}).each_key.with_index do |name, index|
          manifest << "    <item id=\"res#{format('%03d', index + 1)}\" href=\"#{name}\" media-type=\"#{resource_media_type(name)}\"/>"
        end
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="#{escape_html(@options[:epub_language], :attribute)}">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:identifier id="pub-id">#{escape_html(identifier, :text)}</dc:identifier>
              <dc:title>#{escape_html(book_title(chapters), :text)}</dc:title>
              <dc:language>#{escape_html(@options[:epub_language], :text)}</dc:language>
              <meta property="dcterms:modified">#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}</meta>
            </metadata>
            <manifest>
          #{manifest.join("\n")}
            </manifest>
            <spine>
          #{spine.join("\n")}
            </spine>
          </package>
        XML
      end

      # Generate the fixed container file pointing to the package document.
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

      # Build the EPUB archive (a ZIP archive) from the given ordered map of file names to file
      # contents and return it as a binary string.
      def build_epub_archive(files)
        zip = ZipWriter.new
        zip.add('mimetype', EPUB_MIMETYPE, compress: false)
        files.each {|name, data| zip.add(name, data) }
        zip.to_blob
      end

      # A minimal ZIP archive writer (stored and deflated entries, no dependencies).
      class ZipWriter

        Entry = Struct.new(:name, :data, :compress)

        def initialize
          @entries = []
        end

        # Add an entry with the given +name+ and +data+ to the archive.
        def add(name, data, compress: true)
          @entries << Entry.new(name.b, data.b, compress)
        end

        # Return the ZIP archive as a binary string.
        def to_blob
          out = String.new(encoding: Encoding::BINARY)
          central = String.new(encoding: Encoding::BINARY)
          @entries.each do |entry|
            offset = out.bytesize
            crc = Zlib.crc32(entry.data)
            if entry.compress
              deflator = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
              cdata = deflator.deflate(entry.data, Zlib::FINISH)
              deflator.close
              method = 8
            else
              cdata = entry.data
              method = 0
            end
            fields = [0x0800, method, 0, 0x21, crc, cdata.bytesize, entry.data.bytesize]
            out << [0x04034b50, 20, *fields, entry.name.bytesize, 0].pack('Vv5V3v2') << entry.name << cdata
            central << [0x02014b50, 20, 20, *fields, entry.name.bytesize, 0, 0, 0, 0, 0,
                        offset].pack('Vv6V3v5V2') << entry.name
          end
          out << central
          out << [0x06054b50, 0, 0, @entries.length, @entries.length, central.bytesize,
                  out.bytesize - central.bytesize, 0].pack('Vv4V2v')
          out
        end

      end

    end

  end

end

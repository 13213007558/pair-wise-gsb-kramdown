# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#++

require 'minitest/autorun'
require 'kramdown'
require 'zlib'
require 'rexml/document'
require 'tmpdir'
require 'fileutils'

Encoding.default_external = 'utf-8'

class TestEpub < Minitest::Test

  # Minimal, dependency-free reader for the ZIP archives produced by the EPUB converter. Only
  # supports what the tests need: listing entries and reading their (stored or deflated) content.
  class ZipReader

    Entry = Struct.new(:name, :content, :compression, :offset)

    STORED = 0
    DEFLATED = 8

    def self.read(data)
      new(data).entries
    end

    def initialize(data)
      @data = data
    end

    def entries
      result = []
      pos = 0
      while @data[pos, 4].unpack1('V') == 0x04034b50
        compression = @data[pos + 8, 2].unpack1('v')
        compressed_size = @data[pos + 18, 4].unpack1('V')
        uncompressed_size = @data[pos + 22, 4].unpack1('V')
        name_length = @data[pos + 26, 2].unpack1('v')
        extra_length = @data[pos + 28, 2].unpack1('v')
        name = @data[pos + 30, name_length]
        payload_start = pos + 30 + name_length + extra_length
        payload = @data[payload_start, compressed_size]
        content = inflate(compression, payload, uncompressed_size)
        result << Entry.new(name, content, compression, pos)
        pos = payload_start + compressed_size
      end
      result
    end

    private

    def inflate(compression, payload, size)
      return payload if compression == STORED
      inflated = Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(payload)
      raise 'unexpected inflated size' unless inflated.bytesize == size
      inflated
    end

  end

  def setup
    @tmpdir = Dir.mktmpdir('kramdown-epub')
    @resource_root = File.join(@tmpdir, 'assets')
    FileUtils.mkdir_p(File.join(@resource_root, 'img'))
    File.binwrite(File.join(@resource_root, 'img', 'logo.png'), png_bytes)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def png_bytes
    # Minimal valid 1x1 transparent PNG (hand-crafted, no external data).
    bytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    bytes += [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]
    bytes += [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01]
    bytes += [0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89]
    bytes += [0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54]
    bytes += [0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01]
    bytes += [0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44]
    bytes += [0xAE, 0x42, 0x60, 0x82]
    bytes.pack('C*').b
  end

  DOCUMENT = <<~MD.freeze
    Front matter linking to [the second chapter](#chapter-two) and
    an [external site](https://example.com/page).

    ![logo](img/logo.png)

    # Chapter One

    Introduction with a [deep section](#deep-section) and a link to
    [chapter two](#chapter-two).

    ## Deep Section

    Deep section content.

    First shared anchor
    {: #shared}

    # Chapter Two

    Second chapter body.

    # Chapter One

    Duplicate heading text with an explicit duplicate anchor below.

    A later shared anchor
    {: #shared}

    References resolve to the first one: [shared](#shared).
  MD

  def build_epub(document = DOCUMENT, **options)
    defaults = {
      epub_title: 'Sample Book', epub_author: 'Test Author', epub_language: 'en',
      epub_split_level: 1, epub_resource_root: @resource_root
    }
    doc = Kramdown::Document.new(document, defaults.merge(options))
    [doc.to_epub, doc]
  end

  def files_for(epub)
    Hash[ZipReader.read(epub).map {|entry| [entry.name, entry] }]
  end

  # ---- mimetype / archive structure ----

  def test_mimetype_is_first_entry_stored_uncompressed_and_unencrypted
    epub, = build_epub
    entries = ZipReader.read(epub)
    first = entries.first
    assert_equal('mimetype', first.name)
    assert_equal(0, first.offset)
    assert_equal(ZipReader::STORED, first.compression)
    assert_equal('application/epub+zip', first.content)
    # The first 38 bytes are the local file header plus the 20 byte mimetype name.
    assert_equal(30 + 'mimetype'.bytesize, epub.index('application/epub+zip'))
  end

  def test_mimetype_entry_has_no_extra_field
    epub, = build_epub
    entries = ZipReader.read(epub)
    name_length = 'mimetype'.bytesize
    # Local header: extra field length at offset 28 (2 bytes).
    assert_equal(0, epub[28, 2].unpack1('v'))
    assert_equal(name_length, epub[26, 2].unpack1('v'))
  end

  def test_required_files_are_present
    epub, = build_epub
    names = files_for(epub).keys
    %w[mimetype META-INF/container.xml OEBPS/content.opf OEBPS/nav.xhtml OEBPS/style.css].each do |name|
      assert_includes(names, name, "missing required file #{name}")
    end
    (1..4).each {|i| assert_includes(names, format('OEBPS/ch%03d.xhtml', i)) }
    assert_includes(names, 'OEBPS/logo.png')
  end

  def test_container_points_to_package_document
    epub, = build_epub
    files = files_for(epub)
    xml = REXML::Document.new(files['META-INF/container.xml'].content)
    rootfile = REXML::XPath.first(xml, '//c:rootfile', 'c' => 'urn:oasis:names:tc:opendocument:xmlns:container')
    assert_equal('OEBPS/content.opf', rootfile.attributes['full-path'])
    assert_equal('application/oebps-package+xml', rootfile.attributes['media-type'])
  end

  # ---- package document / spine / manifest ----

  def test_package_manifest_and_spine_are_consistent
    epub, = build_epub
    files = files_for(epub)
    opf = REXML::Document.new(files['OEBPS/content.opf'].content)
    opf_ns = 'http://www.idpf.org/2007/opf'

    manifest_hrefs = REXML::XPath.match(opf, '//opf:item', 'opf' => opf_ns).map do |item|
      item.attributes['href']
    end
    %w[nav.xhtml style.css ch001.xhtml ch002.xhtml ch003.xhtml ch004.xhtml logo.png].each do |href|
      assert_includes(manifest_hrefs, href)
    end

    nav_item = REXML::XPath.first(opf, "//opf:item[@href='nav.xhtml']", 'opf' => opf_ns)
    assert_equal('nav', nav_item.attributes['properties'])
    assert_equal('application/xhtml+xml', nav_item.attributes['media-type'])

    logo_item = REXML::XPath.first(opf, "//opf:item[@href='logo.png']", 'opf' => opf_ns)
    assert_equal('image/png', logo_item.attributes['media-type'])

    id_to_href = {}
    REXML::XPath.match(opf, '//opf:item', 'opf' => opf_ns).each do |item|
      id_to_href[item.attributes['id']] = item.attributes['href']
    end
    spine_ids = REXML::XPath.match(opf, '//opf:spine/opf:itemref', 'opf' => opf_ns).map do |ref|
      ref.attributes['idref']
    end
    assert_equal(%w[ch1 ch2 ch3 ch4], spine_ids)
    spine_ids.each {|id| assert_includes(manifest_hrefs, id_to_href[id]) }
  end

  def test_package_metadata
    epub, = build_epub
    opf = REXML::Document.new(files_for(epub)['OEBPS/content.opf'].content)
    dc = 'http://purl.org/dc/elements/1.1/'
    assert_equal('Sample Book', REXML::XPath.first(opf, '//dc:title', 'dc' => dc).text)
    assert_equal('Test Author', REXML::XPath.first(opf, '//dc:creator', 'dc' => dc).text)
    assert_equal('en', REXML::XPath.first(opf, '//dc:language', 'dc' => dc).text)
    assert_kind_of(String, REXML::XPath.first(opf, '//dc:identifier', 'dc' => dc).text)
    modified = REXML::XPath.first(opf, "//opf:meta[@property='dcterms:modified']",
                                'opf' => 'http://www.idpf.org/2007/opf')
    assert_equal('1970-01-01T00:00:00Z', modified.text)
  end

  # ---- navigation document ----

  def test_navigation_document_lists_all_chapters_in_order
    epub, = build_epub
    nav = REXML::Document.new(files_for(epub)['OEBPS/nav.xhtml'].content)
    links = REXML::XPath.match(nav, '//h:nav[@id="toc"]//h:a', 'h' => 'http://www.w3.org/1999/xhtml')
    hrefs = links.map {|a| a.attributes['href'] }
    assert_equal(%w[ch001.xhtml ch002.xhtml ch003.xhtml ch004.xhtml], hrefs)
    assert_equal(['Sample Book', 'Chapter One', 'Chapter Two', 'Chapter One'], links.map(&:text))
  end

  # ---- chapters, internal references and anchors ----

  def test_every_chapter_is_well_formed_xhtml_and_links_stylesheet
    files = files_for(build_epub.first)
    (1..4).each do |i|
      name = format('OEBPS/ch%03d.xhtml', i)
      doc = REXML::Document.new(files[name].content)
      refute_nil(REXML::XPath.first(doc, '//h:body', 'h' => 'http://www.w3.org/1999/xhtml'))
      css = REXML::XPath.first(doc, '//h:link[@rel="stylesheet"]',
                             'h' => 'http://www.w3.org/1999/xhtml')
      assert_equal('style.css', css.attributes['href'])
    end
  end

  def test_internal_references_point_to_existing_files_and_anchors
    files = files_for(build_epub.first)
    anchors = {}
    files.each do |name, entry|
      next unless name.start_with?('OEBPS/ch')
      doc = REXML::Document.new(entry.content)
      ids = REXML::XPath.match(doc, '//h:*[@id]', 'h' => 'http://www.w3.org/1999/xhtml').map do |el|
        el.attributes['id']
      end
      anchors[File.basename(name)] = ids
    end
    files.each do |name, entry|
      next unless name.start_with?('OEBPS/ch')
      each_reference(entry.content) {|kind, url| verify_reference(kind, url, name, files, anchors) }
    end
  end

  def test_cross_chapter_fragment_links_are_rewritten
    files = files_for(build_epub.first)
    assert_match(%r{href="ch003\.xhtml#chapter-two"}, files['OEBPS/ch001.xhtml'].content)
    assert_match(%r{src="logo\.png"}, files['OEBPS/ch001.xhtml'].content)
    assert_includes(files['OEBPS/ch001.xhtml'].content, 'href="https://example.com/page"')
    assert_includes(files['OEBPS/ch002.xhtml'].content, 'href="#deep-section"')
    assert_includes(files['OEBPS/ch002.xhtml'].content, 'href="ch003.xhtml#chapter-two"')
    assert_includes(files['OEBPS/ch004.xhtml'].content, 'href="ch002.xhtml#shared"')
  end

  def test_duplicate_explicit_anchor_is_handled_deterministically
    epub, = build_epub
    files = files_for(epub)
    assert_includes(files['OEBPS/ch002.xhtml'].content, 'id="shared"')
    assert_includes(files['OEBPS/ch004.xhtml'].content, 'id="shared-1"')
    assert_equal(epub, build_epub.first) # byte-reproducible output
  end

  def test_duplicate_heading_ids_are_unique
    files = files_for(build_epub.first)
    assert_includes(files['OEBPS/ch002.xhtml'].content, 'id="chapter-one"')
    assert_includes(files['OEBPS/ch004.xhtml'].content, 'id="chapter-one-1"')
  end

  def test_split_level_two_does_not_split_on_level_one
    document = "# Title\n\n## Section A\n\ntext a\n\n## Section B\n\ntext b\n"
    files = files_for(build_epub(document, epub_split_level: 2).first)
    assert_includes(files['OEBPS/ch001.xhtml'].content, '<h1 id="title">Title</h1>')
    assert_includes(files['OEBPS/ch002.xhtml'].content, '<h2 id="section-a">Section A</h2>')
    assert_includes(files['OEBPS/ch003.xhtml'].content, '<h2 id="section-b">Section B</h2>')
    refute(files.key?('OEBPS/ch004.xhtml'))
  end

  def test_local_resources_are_packaged_with_manifest_entries
    epub, = build_epub
    files = files_for(epub)
    assert_equal(png_bytes, files['OEBPS/logo.png'].content)
    opf = files['OEBPS/content.opf'].content
    assert_includes(opf, 'href="logo.png"')
    assert_includes(opf, 'media-type="image/png"')
  end

  def test_missing_local_resource_leaves_reference_untouched_and_warns
    document = "Text with ![missing](missing.png) image.\n"
    epub, doc = build_epub(document, epub_resource_root: @tmpdir)
    files = files_for(epub)
    assert_includes(files['OEBPS/ch001.xhtml'].content, 'src="missing.png"')
    refute(files.key?('OEBPS/missing.png'))
    assert(doc.warnings.any? {|warning| warning.include?('missing.png') })
  end

  def test_external_references_are_never_rewritten_or_packaged
    files = files_for(build_epub.first)
    assert_includes(files['OEBPS/ch001.xhtml'].content, 'href="https://example.com/page"')
    refute(files.key?('OEBPS/page'))
  end

  def test_all_xml_files_are_well_formed
    files_for(build_epub.first).each do |name, entry|
      next unless name.end_with?('.xhtml', '.xml', '.opf')
      REXML::Document.new(entry.content)
    end
  end

  private

  # Yield each URL referenced via an href/src attribute in an HTML fragment.
  def each_reference(content)
    content.scan(/\s(?:href|src)=(['"])(.*?)\1/m) { yield('ref', $2) }
  end

  # Verify one internal reference: same-file fragments exist in the source chapter; packaged
  # cross-file references point to an existing packaged file and to an existing fragment.
  def verify_reference(_kind, raw_url, source_name, files, anchors)
    path, fragment = split_reference(raw_url)
    if path.nil?
      own = anchors[File.basename(source_name)]
      assert_includes(own, fragment, "#{source_name}: dangling fragment ##{fragment}")
      return
    end
    return unless local_reference?(path)
    packaged = "OEBPS/#{File.basename(path)}"
    assert(files.key?(packaged), "#{source_name}: unpackaged local reference '#{path}'")
    if fragment
      target_anchors = anchors[File.basename(path)]
      assert_includes(target_anchors, fragment, "#{source_name}: ##{fragment} missing in #{path}") if target_anchors
    end
  end

  def split_reference(url)
    if (pos = url.index('#'))
      [pos.zero? ? nil : url[0...pos], url[(pos + 1)..]]
    else
      [url, nil]
    end
  end

  def local_reference?(path)
    return false if path.empty? || path.start_with?('//')
    path[/\A[a-zA-Z][a-zA-Z0-9+.-]*:/].nil?
  end

end

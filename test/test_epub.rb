# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++
#

require 'minitest/autorun'
require 'kramdown'
require 'tmpdir'
require 'zlib'

class TestEpub < Minitest::Test

  CHAPTER_DOC = <<~MD
    # Alpha

    Intro with [link to beta](#beta) and a footnote[^n1].

    [^n1]: The note.

    ## Subsection

    More text.

    # Beta

    Back to [alpha](#alpha).
  MD

  # Read a ZIP archive from a binary string and return a list of entry names (in order of
  # appearance) together with a hash mapping entry names to entry data.
  def read_zip(data)
    entries = {}
    order = []
    pos = 0
    while pos + 4 <= data.bytesize
      sig = data.byteslice(pos, 4).unpack1('V')
      break if sig == 0x02014b50 || sig == 0x06054b50

      assert_equal(0x04034b50, sig, "expected local file header at offset #{pos}")
      _version, flags, method, _time, _date, crc, csize, usize, nlen, elen =
        data.byteslice(pos + 4, 26).unpack('v5V3v2')
      name = data.byteslice(pos + 30, nlen)
      cdata = data.byteslice(pos + 30 + nlen + elen, csize)
      content = if method == 8
                  inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
                  begin
                    inflater.inflate(cdata) + inflater.finish
                  ensure
                    inflater.close
                  end
                else
                  cdata
                end
      assert_equal(usize, content.bytesize, "size mismatch for entry #{name}")
      assert_equal(crc, Zlib.crc32(content), "CRC mismatch for entry #{name}")
      entries[name] = {method: method, flags: flags, extra_len: elen, content: content}
      order << name
      pos += 30 + nlen + elen + csize
    end
    [order, entries]
  end

  def convert_to_epub(text, options = {})
    doc = Kramdown::Document.new(text, options)
    [doc.to_epub, doc]
  end

  # Assert that every internal href/src reference in every content document of the archive
  # points to an existing archive member and that every fragment points to an existing anchor.
  def assert_all_internal_references_valid(entries)
    entries.each do |name, entry|
      next unless name.end_with?('.xhtml', '.opf')

      dir = File.dirname(name)
      entry[:content].scan(/(?:href|src)="([^"]*)"/) do |(uri)|
        next if uri.empty? || uri.start_with?('//') || uri =~ /\A[a-zA-Z][a-zA-Z0-9+.\-]*:/

        file, frag = uri.split('#', 2)
        target = file.empty? ? name : File.expand_path(File.join(dir, file), '/').sub(%r{\A/}, '')
        assert(entries.key?(target),
               "broken reference '#{uri}' in #{name}: '#{target}' is not in the archive")
        next if frag.nil? || frag.empty?

        assert_match(/id="#{Regexp.escape(frag)}"/, entries[target][:content],
                     "missing anchor '##{frag}' in #{target} (referenced from #{name})")
      end
    end
  end

  def test_mimetype_is_first_entry_and_stored_uncompressed
    data, = convert_to_epub(CHAPTER_DOC)
    order, entries = read_zip(data)
    assert_equal('mimetype', order.first)
    assert_equal(0, entries['mimetype'][:method], "mimetype entry has to be stored uncompressed")
    assert_equal(0, entries['mimetype'][:extra_len], "mimetype entry must not have an extra field")
    assert_equal('application/epub+zip', entries['mimetype'][:content])
  end

  def test_required_files_exist
    data, = convert_to_epub(CHAPTER_DOC)
    _order, entries = read_zip(data)
    %w[mimetype META-INF/container.xml OEBPS/content.opf OEBPS/nav.xhtml
       OEBPS/chapter001.xhtml OEBPS/chapter002.xhtml].each do |name|
      assert(entries.key?(name), "required file #{name} is missing from the archive")
    end
  end

  def test_container_xml_references_existing_package_document
    data, = convert_to_epub(CHAPTER_DOC)
    _order, entries = read_zip(data)
    container = entries['META-INF/container.xml'][:content]
    assert_match(/full-path="OEBPS\/content.opf"/, container)
    assert(entries.key?('OEBPS/content.opf'))
    opf = entries['OEBPS/content.opf'][:content]
    assert_match(/<manifest>/, opf)
    assert_match(/<spine>/, opf)
    assert_match(/<item[^>]*properties="nav"[^>]*href="nav.xhtml"|<item[^>]*href="nav.xhtml"[^>]*properties="nav"/, opf)
    assert_match(/<itemref idref="chapter001"\/>/, opf)
    assert_match(/<itemref idref="chapter002"\/>/, opf)
  end

  def test_splits_document_into_chapters_at_configured_header_level
    data, = convert_to_epub(CHAPTER_DOC)
    _order, entries = read_zip(data)
    chapters = entries.keys.grep(%r{\AOEBPS/chapter\d+\.xhtml\z})
    assert_equal(2, chapters.length)
    assert_includes(entries['OEBPS/chapter001.xhtml'][:content], '<h2 id="subsection">')

    data, = convert_to_epub(CHAPTER_DOC, epub_chapter_level: 2)
    _order, entries = read_zip(data)
    chapters = entries.keys.grep(%r{\AOEBPS/chapter\d+\.xhtml\z})
    assert_equal(3, chapters.length)
    assert_includes(entries['OEBPS/chapter002.xhtml'][:content], '<h2 id="subsection">')
  end

  def test_content_before_first_header_becomes_first_chapter
    data, = convert_to_epub("Preface text.\n\n# Alpha\n\nBody.\n")
    _order, entries = read_zip(data)
    assert_includes(entries['OEBPS/chapter001.xhtml'][:content], 'Preface text.')
    assert_includes(entries['OEBPS/chapter002.xhtml'][:content], '<h1 id="alpha">')
  end

  def test_rewrites_fragment_links_to_cross_file_links
    data, = convert_to_epub(CHAPTER_DOC)
    _order, entries = read_zip(data)
    assert_includes(entries['OEBPS/chapter001.xhtml'][:content], 'href="chapter002.xhtml#beta"')
    assert_includes(entries['OEBPS/chapter002.xhtml'][:content], 'href="chapter001.xhtml#alpha"')
  end

  def test_handles_duplicate_anchor_ids_deterministically
    text = <<~MD
      # One {#dup}

      [self](#dup) and [other](#dup) again.

      # Two {#dup}

      [back](#dup)
    MD
    data, = convert_to_epub(text)
    _order, entries = read_zip(data)
    assert_includes(entries['OEBPS/chapter001.xhtml'][:content], 'id="dup"')
    assert_includes(entries['OEBPS/chapter002.xhtml'][:content], 'id="dup-1"')
    refute_includes(entries['OEBPS/chapter002.xhtml'][:content], 'id="dup"')
    assert_includes(entries['OEBPS/chapter001.xhtml'][:content], 'href="#dup"')
    assert_includes(entries['OEBPS/chapter002.xhtml'][:content], 'href="chapter001.xhtml#dup"')

    second, = convert_to_epub(text)
    _order2, entries2 = read_zip(second)
    entries.each do |name, entry|
      next unless name.end_with?('.xhtml')

      assert_equal(entry[:content], entries2[name][:content],
                   "conversion of #{name} is not deterministic")
    end
  end

  def test_warns_about_unresolvable_fragment_links
    _data, doc = convert_to_epub("# A\n\n[missing](#nope)\n")
    assert(doc.warnings.any? {|w| w =~ /No anchor found for link '#nope'/ },
           "expected a warning about the unresolvable link")
  end

  def test_packages_local_images
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, 'pic.png'), "fake-png-bytes")
      Dir.mkdir(File.join(dir, 'sub'))
      File.binwrite(File.join(dir, 'sub', 'pic.png'), "other-png-bytes")
      text = "![one](pic.png)\n\n![two](sub/pic.png)\n\n![remote](https://example.com/x.png)\n"
      data, = convert_to_epub(text, epub_resource_dir: dir)
      _order, entries = read_zip(data)

      assert_equal('fake-png-bytes', entries['OEBPS/images/pic.png'][:content])
      assert_equal('other-png-bytes', entries['OEBPS/images/pic-1.png'][:content])

      chapter = entries['OEBPS/chapter001.xhtml'][:content]
      assert_includes(chapter, 'src="images/pic.png"')
      assert_includes(chapter, 'src="images/pic-1.png"')
      assert_includes(chapter, 'src="https://example.com/x.png"')

      opf = entries['OEBPS/content.opf'][:content]
      assert_match(/<item[^>]*href="images\/pic.png"[^>]*media-type="image\/png"/, opf)
      assert_match(/<item[^>]*href="images\/pic-1.png"[^>]*media-type="image\/png"/, opf)
    end
  end

  def test_all_internal_references_resolve
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, 'pic.png'), "fake-png-bytes")
      text = CHAPTER_DOC + "\n![image](pic.png)\n"
      data, = convert_to_epub(text, epub_resource_dir: dir)
      _order, entries = read_zip(data)
      assert_all_internal_references_valid(entries)
    end
  end

end

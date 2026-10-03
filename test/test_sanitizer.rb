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
require 'kramdown/converter/hash_ast'

Encoding.default_external = 'utf-8'

describe 'sanitize' do

  def sanitize_html(source, sanitize: true, **options)
    Kramdown::Document.new(source, sanitize: sanitize, **options).to_html
  end

  describe 'markdown generated links and images' do
    it 'removes the href of inline links with a dangerous scheme' do
      _(sanitize_html('[click](javascript:alert(1))')).must_equal '<p><a>click</a></p>' + "\n"
    end

    it 'removes the href of reference links with a dangerous scheme' do
      _(sanitize_html("[click][ref]\n\n[ref]: javascript:alert(1)")).must_equal '<p><a>click</a></p>' + "\n\n"
    end

    it 'keeps links with an allowed scheme' do
      _(sanitize_html('[ok](https://example.com) and [mail](mailto:a@b.c)'))
        .must_equal '<p><a href="https://example.com">ok</a> and <a href="mailto:a@b.c">mail</a></p>' + "\n"
    end

    it 'keeps autolinks with an allowed scheme' do
      _(sanitize_html('<https://example.com>'))
        .must_equal '<p><a href="https://example.com">https://example.com</a></p>' + "\n"
    end

    it 'removes the src of images with a dangerous scheme' do
      _(sanitize_html('![pic](javascript:alert(1))')).must_equal '<p><img alt="pic" /></p>' + "\n"
    end
  end

  describe 'embedded raw HTML' do
    it 'applies the same rules to raw HTML links' do
      _(sanitize_html('<a href="javascript:alert(1)">x</a>')).must_equal '<p><a>x</a></p>' + "\n"
    end

    it 'removes script elements together with their content' do
      _(sanitize_html("before\n\n<script>alert(1)</script>\n\nafter"))
        .must_equal "<p>before</p>\n\n\n<p>after</p>\n"
    end

    it 'matches element names case-insensitively' do
      _(sanitize_html('<SCRIPT>alert(1)</SCRIPT>')).must_equal "\n"
    end

    it 'removes event handler and other undeclared attributes' do
      _(sanitize_html('<a href="https://example.com" onclick="x()" id="keep">x</a>'))
        .must_equal '<p><a href="https://example.com" id="keep">x</a></p>' + "\n"
    end
  end

  describe 'URL normalization' do
    it 'detects decimal entity encoded schemes' do
      _(sanitize_html('<a href="&#106;avascript:alert(1)">x</a>')).must_equal '<p><a>x</a></p>' + "\n"
    end

    it 'detects hexadecimal entity encoded schemes' do
      _(sanitize_html('[x](&#x6A;avascript:alert(1))')).must_equal '<p><a>x</a></p>' + "\n"
    end

    it 'detects schemes containing control characters' do
      _(sanitize_html("<a href=\"java\tscript:alert(1)\">x</a>")).must_equal '<p><a>x</a></p>' + "\n"
      _(sanitize_html('[x](jav&#x09;ascript:alert(1))')).must_equal '<p><a>x</a></p>' + "\n"
    end

    it 'detects schemes with mixed case' do
      _(sanitize_html('[x](JaVaScRiPt:alert(1))')).must_equal '<p><a>x</a></p>' + "\n"
    end
  end

  describe 'data URL image whitelist' do
    it 'keeps data URLs with an allowed image type' do
      _(sanitize_html('![pic](data:image/png;base64,iVBORw0KGgo=)'))
        .must_equal '<p><img src="data:image/png;base64,iVBORw0KGgo=" alt="pic" /></p>' + "\n"
    end

    it 'removes data URLs with a disallowed image type' do
      _(sanitize_html('![pic](data:image/svg+xml;base64,PHN2Zz4=)'))
        .must_equal '<p><img alt="pic" /></p>' + "\n"
    end

    it 'removes data URLs that are not images' do
      _(sanitize_html('![pic](data:text/html;base64,PHNjcmlwdD4=)'))
        .must_equal '<p><img alt="pic" /></p>' + "\n"
    end

    it 'does not allow data URLs in href attributes' do
      _(sanitize_html('[x](data:image/png;base64,iVBORw0KGgo=)'))
        .must_equal '<p><a>x</a></p>' + "\n"
    end
  end

  describe 'relative URL handling' do
    it 'allows relative URLs by default' do
      _(sanitize_html('[x](/local/page) and [y](#anchor)'))
        .must_equal '<p><a href="/local/page">x</a> and <a href="#anchor">y</a></p>' + "\n"
    end

    it 'removes relative URLs when the policy denies them' do
      _(sanitize_html('[x](/local) and [y](https://example.com)', sanitize: {relative: :deny}))
        .must_equal '<p><a>x</a> and <a href="https://example.com">y</a></p>' + "\n"
    end
  end

  describe 'nested and namespaced content' do
    it 'sanitizes deeply nested elements' do
      _(sanitize_html('<div><div><script>alert(1)</script></div></div>', parse_block_html: true))
        .must_equal "<div>\n  <div></div>\n</div>\n"
    end

    it 'checks namespaced URL attributes by their local name' do
      policy = {
        elements: %w[svg a p],
        attributes: {'a' => %w[xlink:href]},
        schemes: {'href' => %w[http https]},
      }
      _(sanitize_html('<svg><a xlink:href="javascript:alert(1)">x</a></svg>',
                      sanitize: policy, parse_block_html: true))
        .must_equal "<svg><a>x</a></svg>\n"
    end
  end

  describe 'strategies' do
    it 'removes disallowed elements with their content by default' do
      _(sanitize_html('<div><script>alert(1)</script></div>', parse_block_html: true))
        .must_equal "<div></div>\n"
    end

    it 'keeps the text of disallowed elements with the unwrap strategy' do
      _(sanitize_html('<div><script>alert(1)</script></div>',
                      sanitize: {strategy: :unwrap}, parse_block_html: true))
        .must_equal "<div>\nalert(1)\n</div>\n"
    end

    it 'keeps the text of unknown formatting elements with the unwrap strategy' do
      _(sanitize_html('<marquee>some text</marquee>', sanitize: {strategy: :unwrap}))
        .must_equal "some text"
    end

    it 'rejects an invalid strategy' do
      _(proc { sanitize_html('text', sanitize: {strategy: :clean}) }).must_raise(Kramdown::Error)
    end
  end

  describe 'style content' do
    it 'removes style elements instead of string-cleaning them' do
      _(sanitize_html("<style>body { background: url(javascript:x) }</style>", parse_block_html: true))
        .must_equal "\n"
    end

    it 'removes style attributes instead of string-cleaning them' do
      _(sanitize_html('<p style="background: url(javascript:x)">x</p>', parse_block_html: true))
        .must_equal "<p>x</p>\n"
    end
  end

  describe 'reporting' do
    it 'reports the position and reason for each removal or rewrite' do
      doc = Kramdown::Document.new("[x](javascript:alert(1))\n\n<script>alert(2)</script>",
                                   sanitize: true)
      doc.to_html
      _(doc.warnings).must_equal([
        "sanitize: line 1: removed attribute 'a/href' - URL scheme 'javascript' is not allowed",
        "sanitize: line 3: removed element 'script' - element is not allowed",
      ])
    end
  end

  describe 'idempotency' do
    it 'produces the same structure when sanitizing twice' do
      source = "[x](javascript:alert(1)) ![i](data:image/png;base64,AAA=)\n\n" \
        "<script>alert(1)</script>\n\n<div style=\"x\">t</div>"
      policy = Kramdown::Utils::Sanitizer.policy(true)
      tree, first_issues = Kramdown::Utils::Sanitizer.sanitize_tree(
        Kramdown::Document.new(source).root, policy)
      _(first_issues).wont_be_empty
      tree2, second_issues = Kramdown::Utils::Sanitizer.sanitize_tree(tree, policy)
      _(second_issues).must_be_empty
      _(Kramdown::Converter::HashAst.convert(tree, {}).first)
        .must_equal(Kramdown::Converter::HashAst.convert(tree2, {}).first)
    end
  end

  describe 'disabled mode' do
    it 'leaves the conversion result unchanged when not enabled' do
      source = "[x](javascript:alert(1))\n\n<script>alert(1)</script>"
      doc = Kramdown::Document.new(source)
      _(doc.to_html)
        .must_equal "<p><a href=\"javascript:alert(1)\">x</a></p>\n\n<script>alert(1)</script>\n\n"
      _(doc.warnings).must_be_empty
    end

    it 'does not modify the document tree of the document' do
      doc = Kramdown::Document.new('<script>alert(1)</script>', sanitize: true)
      doc.to_html
      _(doc.root.children.map(&:type)).must_include(:html_element)
    end
  end

  describe 'policy validation' do
    it 'rejects unknown policy keys' do
      _(proc { sanitize_html('text', sanitize: {unknown: true}) }).must_raise(Kramdown::Error)
    end

    it 'rejects invalid option values' do
      _(proc { sanitize_html('text', sanitize: 'yes') }).must_raise(Kramdown::Error)
    end
  end

end

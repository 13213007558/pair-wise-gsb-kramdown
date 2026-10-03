# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++
#

require 'kramdown/utils'
require 'kramdown/utils/entities'

module Kramdown

  module Utils

    # Sanitizes a kramdown element tree according to an explicit, caller-declared policy.
    #
    # The sanitizer works purely on the structure of the element tree: the policy declares which
    # elements and attributes are allowed, which URL schemes may appear in URL attributes and how
    # relative URLs are treated. The same rules are applied to elements generated from kramdown
    # syntax (e.g. links and images) and to raw HTML elements embedded in the document.
    #
    # Important properties:
    #
    # * Disallowed elements are either removed together with their content (mode +:remove+) or
    #   removed while keeping their text content (mode +:strip+). The two strategies are never
    #   mixed - one mode applies to the whole document.
    #
    # * Attribute values are never modified. Especially, no string replacement based cleaning of
    #   unsupported content (like CSS in +style+ attributes) is performed: an attribute is
    #   either allowed as-is or removed.
    #
    # * URLs are analyzed after entity decoding, case normalization and removal of control
    #   characters, so that obfuscated dangerous schemes (entity encoded, mixed case or
    #   containing tab characters) are reliably detected. URLs are never requested/fetched.
    #
    # * Every removal or rewrite is reported with the source line (if available) and the reason.
    #
    # * Running the sanitizer twice on the same tree yields the same structure (idempotency).
    module Sanitizer

      # Element removal mode: disallowed elements are removed together with their content.
      MODE_REMOVE = :remove

      # Element removal mode: disallowed elements are removed but their text content is kept.
      MODE_STRIP = :strip

      # All valid removal modes.
      MODES = [MODE_REMOVE, MODE_STRIP].freeze

      # All valid treatments for relative URLs.
      RELATIVE_POLICIES = [:allow, :remove].freeze

      # The default policy used when the +sanitize+ option is activated. Individual parts can be
      # overridden with the +sanitize_policy+ option.
      DEFAULT_POLICY = {
        elements: %w[a abbr b blockquote br code dd div dl dt em h1 h2 h3 h4 h5 h6 hr i img ins
                     kbd li ol p pre q s samp span strong sub sup table tbody td tfoot th thead
                     tr ul var],
        attributes: {
          '*' => %w[title],
          'a' => %w[href],
          'img' => %w[src alt width height],
          'ol' => %w[start],
          'td' => %w[colspan rowspan],
          'th' => %w[colspan rowspan],
        },
        schemes: %w[http https mailto],
        relative: :allow,
        mode: MODE_REMOVE,
      }.freeze

      # Attributes whose values are URLs and therefore checked against the allowed schemes.
      URL_ATTRIBUTES = %w[href src xlink:href action formaction cite background poster data
                          longdesc].freeze

      # Element types that never represent output HTML elements and are always kept.
      KEEP_TYPES = [:root, :text, :blank, :entity, :typographic_sym, :smart_quote, :abbreviation,
                    :math].freeze

      # Element types that are always removed when sanitizing because their content would be
      # passed through to the output unescaped.
      REMOVE_TYPES = {
        xml_comment: 'HTML comment',
        xml_pi: 'XML processing instruction',
        comment: 'comment',
        raw: 'raw passthrough string',
      }.freeze

      # Maps native kramdown element types to their HTML tag name. The :header type is handled
      # specially because the tag name depends on the header level.
      NATIVE_TAG_NAMES = {
        p: 'p', blockquote: 'blockquote', codeblock: 'pre', ul: 'ul', ol: 'ol', li: 'li',
        dl: 'dl', dt: 'dt', dd: 'dd', hr: 'hr', table: 'table', thead: 'thead', tbody: 'tbody',
        tfoot: 'tfoot', tr: 'tr', td: 'td', a: 'a', img: 'img', em: 'em', strong: 'strong',
        codespan: 'code', br: 'br',
      }.freeze

      # Key of the policy attributes entry that applies to all elements.
      WILDCARD_ATTRIBUTES = '*'

      # Entities that are not part of kramdown's HTML4 entity table but are relevant for
      # detecting obfuscated URLs.
      ADDITIONAL_ENTITIES = {
        'colon' => ':', 'Tab' => "\t", 'NewLine' => "\n",
      }.freeze

      # Matches an HTML entity reference (named, decimal or hexadecimal).
      ENTITY_RE = /&([\w:][\w.:-]*);|&#(\d+);|&#[xX]([0-9a-fA-F]+);/ # :nodoc:

      # Matches a URL scheme at the beginning of a normalized URL.
      SCHEME_RE = /\A([a-zA-Z][a-zA-Z0-9+.\-]*):/ # :nodoc:

      # Matches data: URLs that are allowed when the 'data' scheme is whitelisted: base64
      # encoded images with a common image media type.
      DATA_IMAGE_RE = /\Adata:image\/(?:png|gif|jpe?g|webp);base64,[a-z0-9+\/=\s]*\z/i # :nodoc:

      # Sanitize the element tree rooted at +root+ in place according to the policy defined by
      # the +sanitize_policy+ option (merged over the DEFAULT_POLICY) and return an array of
      # messages describing each removal or rewrite together with its location and reason.
      #
      # The method is idempotent: sanitizing an already sanitized tree performs no further
      # changes and returns an empty array.
      def self.sanitize(root, options)
        policy = resolve_policy(options[:sanitize_policy])
        messages = []
        sanitize_children(root, policy, messages)
        messages
      end

      # Return the effective policy by merging the caller-declared +custom+ policy (a hash,
      # possibly empty) over the DEFAULT_POLICY.
      def self.resolve_policy(custom)
        custom ||= {}
        policy = {
          elements: (custom[:elements] || DEFAULT_POLICY[:elements]).map {|e| e.to_s.downcase },
          schemes: (custom[:schemes] || DEFAULT_POLICY[:schemes]).map {|s| s.to_s.downcase },
          relative: (custom[:relative] || DEFAULT_POLICY[:relative]).to_sym,
          mode: (custom[:mode] || DEFAULT_POLICY[:mode]).to_sym,
          attributes: {},
        }
        unless RELATIVE_POLICIES.include?(policy[:relative])
          raise ::Kramdown::Error, 'Invalid relative URL treatment in sanitize policy: ' \
            "#{policy[:relative].inspect} (valid: #{RELATIVE_POLICIES.join(', ')})"
        end
        unless MODES.include?(policy[:mode])
          raise ::Kramdown::Error, 'Invalid element removal mode in sanitize policy: ' \
            "#{policy[:mode].inspect} (valid: #{MODES.join(', ')})"
        end
        DEFAULT_POLICY[:attributes].each do |el, attrs|
          policy[:attributes][el] = attrs.dup
        end
        (custom[:attributes] || {}).each do |el, attrs|
          policy[:attributes][el.to_s.downcase] = Array(attrs).map {|a| a.to_s.downcase }
        end
        policy
      end

      # Sanitize the children of +el+, replacing the children array with the sanitized result.
      def self.sanitize_children(el, policy, messages)
        el.children = el.children.flat_map do |child|
          Array(sanitize_element(child, policy, messages))
        end
      end
      private_class_method :sanitize_children

      # Sanitize a single element and return the element itself, an array of replacement
      # elements or +nil+ if the element was removed.
      def self.sanitize_element(el, policy, messages)
        if KEEP_TYPES.include?(el.type)
          sanitize_children(el, policy, messages)
          return el
        elsif el.type == :footnote
          sanitize_children(el.value, policy, messages) if el.value.kind_of?(::Kramdown::Element)
          return el
        elsif (reason = REMOVE_TYPES[el.type])
          messages << message(el, "removed #{reason}")
          return nil
        end

        tag = tag_name(el)
        return el if tag.nil? # unknown future element type: keep as-is

        unless policy[:elements].include?(tag)
          return handle_disallowed_element(el, tag, policy, messages)
        end

        sanitize_attributes(el, tag, policy, messages)
        sanitize_children(el, policy, messages)
        el
      end
      private_class_method :sanitize_element

      # Return the HTML tag name for the element +el+ or +nil+ if the element type has no tag
      # semantics.
      def self.tag_name(el)
        case el.type
        when :html_element then el.value.to_s.downcase
        when :header then "h#{el.options[:level] || 1}"
        else NATIVE_TAG_NAMES[el.type]
        end
      end
      private_class_method :tag_name

      # Handle an element whose tag name is not allowed, according to the configured removal
      # mode.
      def self.handle_disallowed_element(el, tag, policy, messages)
        if policy[:mode] == MODE_STRIP
          messages << message(el, "stripped disallowed element '#{tag}', keeping its text content")
          container = ::Kramdown::Element.new(:root)
          container.children = replacement_for(el)
          sanitize_children(container, policy, messages)
          container.children
        else
          messages << message(el, "removed disallowed element '#{tag}'")
          nil
        end
      end
      private_class_method :handle_disallowed_element

      # Return the replacement elements used when stripping the element +el+: its children or,
      # for elements that store text in their value, a text element with that value.
      def self.replacement_for(el)
        if !el.children.empty?
          el.children
        elsif el.value.kind_of?(String) && !el.value.empty?
          [::Kramdown::Element.new(:text, el.value, nil, location: el.options[:location])]
        else
          []
        end
      end
      private_class_method :replacement_for

      # Remove all attributes of the element +el+ (with tag name +tag+) that are not allowed and
      # all URL attributes whose URL is not allowed.
      def self.sanitize_attributes(el, tag, policy, messages)
        return if el.attr.nil? || el.attr.empty?

        allowed = (policy[:attributes][WILDCARD_ATTRIBUTES] || []) |
                  (policy[:attributes][tag] || [])
        el.attr.keys.each do |name|
          key = name.to_s
          unless allowed.include?(key.downcase)
            messages << message(el, "removed disallowed attribute '#{key}' from element '#{tag}'")
            el.attr.delete(name)
            next
          end
          next unless URL_ATTRIBUTES.include?(key.downcase)

          value = el.attr[name].to_s
          next if (reason = disallowed_url_reason(value, policy)).nil?

          messages << message(el, "removed attribute '#{key}' from element '#{tag}': #{reason}")
          el.attr.delete(name)
        end
      end
      private_class_method :sanitize_attributes

      # Return +nil+ if the URL +url+ is allowed by the policy or a string describing the reason
      # why it is not allowed.
      #
      # The URL is normalized before the check: HTML entities are decoded, ASCII control
      # characters and whitespace are removed and the scheme is compared case-insensitively. The
      # URL itself is never modified or requested.
      def self.disallowed_url_reason(url, policy)
        normalized = decode_entities(url).gsub(/[\x00-\x20\x7f]/, '')
        if (match = SCHEME_RE.match(normalized))
          scheme = match[1].downcase
          unless policy[:schemes].include?(scheme)
            return "URL scheme '#{scheme}' is not allowed"
          end
          if scheme == 'data' && !DATA_IMAGE_RE.match?(normalized)
            return 'data URL is not a whitelisted image data URL'
          end
          nil
        elsif policy[:relative] == :allow
          nil
        else
          'relative URLs are not allowed'
        end
      end
      private_class_method :disallowed_url_reason

      # Decode all HTML entity references (named, decimal and hexadecimal) in the string +str+.
      # Unknown entities are left as-is.
      def self.decode_entities(str)
        str.gsub(ENTITY_RE) do |match|
          if $2
            begin [$2.to_i].pack('U') rescue match end
          elsif $3
            begin [$3.to_i(16)].pack('U') rescue match end
          else
            entity = ::Kramdown::Utils::Entities.entity($1)
            (entity && entity.char) || ADDITIONAL_ENTITIES[$1] || match
          end
        end
      end
      private_class_method :decode_entities

      # Format a sanitizer message, prefixing it with the source line of the element if
      # available.
      def self.message(el, text)
        location = el.options[:location]
        (location ? "line #{location}: " : '') + text
      end
      private_class_method :message

    end

  end

end

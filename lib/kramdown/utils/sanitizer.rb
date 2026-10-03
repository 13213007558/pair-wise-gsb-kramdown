# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++
#

require 'kramdown/error'
require 'kramdown/utils'
require 'kramdown/utils/entities'

module Kramdown

  module Utils

    # == Structural sanitizer for kramdown element trees
    #
    # This module implements an explicit, opt-in sanitization mode for documents that contain
    # user-submitted Markdown and/or raw HTML. It works purely on the structure of the element
    # tree, i.e. the same rules are applied to elements originating from Markdown syntax (like
    # links and images) and to elements originating from embedded raw HTML.
    #
    # The policy is fully declared by the caller:
    #
    # [+:elements+] An array of allowed HTML element names (e.g. <tt>%w[p a img]</tt>). Element
    #               names are matched case-insensitively. kramdown native elements are mapped to
    #               their HTML counterparts (e.g. a header of level 2 is matched as +h2+).
    # [+:attributes+] A hash mapping an element name (or <tt>'*'</tt> for all elements) to an
    #                 array of allowed attribute names. Attribute names are matched
    #                 case-insensitively; namespaced attributes (e.g. +xlink:href+) are matched
    #                 by their local name for URL checks.
    # [+:schemes+] A hash mapping a URL attribute name (or <tt>'*'</tt>) to an array of allowed
    #              URL schemes (e.g. <tt>%w[http https mailto]</tt>).
    # [+:relative+] How relative URLs (including protocol-relative URLs) are handled: +:allow+
    #               (default) keeps them, +:deny+ removes the containing attribute.
    # [+:data_image_types+] An array of image sub types (e.g. <tt>%w[png gif]</tt>) that are
    #                       allowed for +data:+ URLs. +data:+ URLs that are not images of an
    #                       allowed type are rejected.
    # [+:strategy+] How disallowed elements are handled: +:remove+ (default) deletes the element
    #               together with its whole subtree, +:unwrap+ deletes only the element itself
    #               and keeps its (sanitized) children. The two strategies cannot be mixed - a
    #               single strategy applies to the whole sanitization run.
    #
    # URL attributes are normalized before the scheme is checked: HTML entities are decoded
    # (repeatedly, to catch nested encodings), ASCII control characters and whitespace are
    # removed and the scheme is compared case-insensitively. Note that no URL is ever requested
    # - sanitization is a purely local, structural operation.
    #
    # Note also that the content of +style+ attributes and +style+ elements is *not* filtered by
    # string replacement. They are simply not part of the default policy; if a caller explicitly
    # allows them, their content is passed through unchanged at the caller's own risk.
    #
    # Every removed element/attribute is reported as an Issue containing the action, the element
    # or attribute name, the reason and the source line (if available).
    module Sanitizer

      # Represents a single action taken by the sanitizer.
      #
      # [action] One of +:remove_element+, +:unwrap_element+ or +:remove_attribute+.
      # [name] The name of the affected element (or "element/attribute" for attributes).
      # [reason] A human readable reason for the action.
      # [line] The source line number of the element, or +nil+ if unknown.
      Issue = Struct.new(:action, :name, :reason, :line) do
        def to_s # :nodoc:
          location = line ? "line #{line}: " : ""
          target = action == :remove_attribute ? "attribute '#{name}'" : "element '#{name}'"
          verb = action == :unwrap_element ? "unwrapped" : "removed"
          "sanitize: #{location}#{verb} #{target} - #{reason}"
        end
      end

      # Mapping of kramdown native element types to their HTML element names.
      TAG_FOR_TYPE = {
        p: 'p', blockquote: 'blockquote', codeblock: 'pre', ul: 'ul', ol: 'ol', dl: 'dl',
        li: 'li', dt: 'dt', dd: 'dd', table: 'table', thead: 'thead', tbody: 'tbody',
        tr: 'tr', td: 'td', hr: 'hr', br: 'br', a: 'a', img: 'img', codespan: 'code',
        em: 'em', strong: 'strong',
      }.freeze

      # Element types that have no HTML element representation on their own and are always
      # allowed (their children are still sanitized).
      STRUCTURAL_TYPES = %i[root blank text comment entity typographic_sym smart_quote
                            abbreviation footnote math].freeze

      # The default set of allowed elements, used when the policy does not declare +:elements+.
      DEFAULT_ELEMENTS = %w[a abbr b blockquote br code dd div dl dt em h1 h2 h3 h4 h5 h6 hr i
                            img kbd li ol p pre q s span strike strong sub sup table tbody td th
                            thead tr u ul].freeze

      # The default set of allowed attributes.
      DEFAULT_ATTRIBUTES = {
        '*' => %w[id class title],
        'a' => %w[href],
        'img' => %w[src alt width height],
        'td' => %w[colspan rowspan],
        'th' => %w[colspan rowspan],
      }.freeze

      # The default set of allowed URL schemes per URL attribute.
      DEFAULT_SCHEMES = {
        'href' => %w[http https mailto],
        'src' => %w[http https data],
        '*' => %w[http https],
      }.freeze

      # Attributes (by local name) whose values are treated as URLs.
      DEFAULT_URL_ATTRIBUTES = %w[href src action formaction poster background cite data].freeze

      # The default set of allowed image sub types for +data:+ URLs.
      DEFAULT_DATA_IMAGE_TYPES = %w[gif jpeg png webp].freeze

      POLICY_KEYS = %i[elements attributes schemes url_attributes data_image_types relative
                       strategy].freeze

      # Normalize and validate the given sanitize specification (either +true+ for the default
      # policy or a hash with policy declarations) and return a complete policy hash.
      def self.policy(spec)
        spec = {} if spec == true
        unless spec.kind_of?(Hash)
          raise Kramdown::Error, "Invalid value for option :sanitize - expected true or a Hash"
        end
        unknown = spec.keys.map(&:to_sym) - POLICY_KEYS
        unless unknown.empty?
          raise Kramdown::Error, "Unknown sanitize policy keys: #{unknown.join(', ')}"
        end
        spec = spec.each_with_object({}) {|(k, v), h| h[k.to_sym] = v }

        relative = (spec[:relative] || :allow).to_sym
        unless %i[allow deny].include?(relative)
          raise Kramdown::Error, "Invalid sanitize policy value for :relative - " +
            "expected :allow or :deny"
        end
        strategy = (spec[:strategy] || :remove).to_sym
        unless %i[remove unwrap].include?(strategy)
          raise Kramdown::Error, "Invalid sanitize policy value for :strategy - " +
            "expected :remove or :unwrap"
        end

        {
          elements: downcase_list(spec[:elements] || DEFAULT_ELEMENTS),
          attributes: normalize_name_map(spec[:attributes] || DEFAULT_ATTRIBUTES),
          schemes: normalize_name_map(spec[:schemes] || DEFAULT_SCHEMES),
          url_attributes: downcase_list(spec[:url_attributes] || DEFAULT_URL_ATTRIBUTES),
          data_image_types: downcase_list(spec[:data_image_types] || DEFAULT_DATA_IMAGE_TYPES),
          relative: relative,
          strategy: strategy,
        }
      end

      # Sanitize a deep copy of the element tree rooted at +root+ using the given +policy+ (see
      # ::policy). Returns the new root element together with an array of Issue objects
      # describing every removal or rewrite.
      #
      # The operation is idempotent: sanitizing an already sanitized tree with the same policy
      # yields the same structure and no further issues.
      def self.sanitize_tree(root, policy)
        issues = []
        new_root = sanitize_node(deep_dup(root), policy, issues)
        # The root element itself is always kept; only its children are replaced.
        [new_root || root, issues]
      end

      # :stopdoc:

      def self.sanitize_node(el, policy, issues) # :nodoc:
        tag = tag_name_for(el)
        if tag && !allowed_element?(tag, policy)
          issues << Issue.new(:"#{policy[:strategy]}_element", tag,
                              "element is not allowed", el.options[:location])
          if policy[:strategy] == :unwrap
            # A :raw element carries its text in the value, not in child elements - keep the
            # text itself (it will be escaped on output) when unwrapping.
            if el.type == :raw
              return Element.new(:text, el.value, nil, el.options.dup)
            end
            el.children = sanitize_children(el, policy, issues)
            return el.children
          end
          return nil
        end
        sanitize_attributes(el, tag, policy, issues) if tag
        el.children = sanitize_children(el, policy, issues)
        el
      end

      def self.sanitize_children(el, policy, issues) # :nodoc:
        el.children.flat_map do |child|
          Array(sanitize_node(child, policy, issues))
        end
      end

      def self.sanitize_attributes(el, tag, policy, issues) # :nodoc:
        return if el.attr.empty?
        allowed = (policy[:attributes]['*'] || []) | (policy[:attributes][tag] || [])
        seen = {}
        el.attr.keys.each do |name|
          key = name.to_s.downcase
          if seen[key]
            el.attr.delete(name)
            issues << Issue.new(:remove_attribute, "#{tag}/#{name}",
                                "duplicate attribute", el.options[:location])
          elsif !allowed.include?(key)
            el.attr.delete(name)
            issues << Issue.new(:remove_attribute, "#{tag}/#{name}",
                                "attribute is not allowed", el.options[:location])
          elsif url_attribute?(key, policy) &&
              (reason = check_url(el.attr[name], key, policy))
            el.attr.delete(name)
            issues << Issue.new(:remove_attribute, "#{tag}/#{name}",
                                reason, el.options[:location])
          else
            seen[key] = true
          end
        end
      end

      def self.tag_name_for(el) # :nodoc:
        case el.type
        when :html_element then el.value.to_s.downcase
        when :header then "h#{el.options[:level] || 1}"
        when :xml_comment, :xml_pi then 'xml_comment'
        when :raw then 'raw'
        when *STRUCTURAL_TYPES then nil
        else TAG_FOR_TYPE[el.type]
        end
      end

      def self.allowed_element?(tag, policy) # :nodoc:
        policy[:elements].include?(tag) ||
          policy[:elements].include?(tag.split(':').last)
      end

      def self.url_attribute?(name, policy) # :nodoc:
        policy[:url_attributes].include?(name) ||
          policy[:url_attributes].include?(name.split(':').last)
      end

      # Check the URL in +value+ for the attribute +attr+ against the policy. Returns +nil+ if
      # the URL is allowed, otherwise a string describing the reason for the rejection.
      def self.check_url(value, attr, policy) # :nodoc:
        compact = decode_entities(value.to_s).gsub(/[\u0000-\u0020\u007f]+/, '')
        if compact =~ /\A([A-Za-z][A-Za-z0-9+.\-]*):/
          scheme = $1.downcase
          local = attr.split(':').last
          allowed = policy[:schemes][attr] || policy[:schemes][local] || policy[:schemes]['*'] || []
          return "URL scheme '#{scheme}' is not allowed" unless allowed.include?(scheme)
          if scheme == 'data' &&
              !(compact =~ /\Adata:image\/([a-z0-9.+\-]+)[;,]/i &&
                policy[:data_image_types].include?($1.downcase))
            return "data URL is not an allowed image type"
          end
          nil
        elsif policy[:relative] == :deny
          "relative URLs are not allowed"
        end
      end

      # Decode HTML entities (named, decimal and hexadecimal) repeatedly (at most 3 passes) so
      # that nested encodings are resolved as well.
      def self.decode_entities(str) # :nodoc:
        3.times do
          decoded = str.gsub(/&(?:#(\d+)|#[xX]([0-9a-fA-F]+)|([A-Za-z][A-Za-z0-9]+));/) do
            if $1 || $2
              begin
                [($1 ? $1.to_i : $2.to_i(16))].pack('U')
              rescue RangeError
                $&
              end
            elsif (entity = Utils::Entities.entity($3))
              entity.char
            else
              $&
            end
          end
          break str if decoded == str
          str = decoded
        end
        str
      end

      def self.deep_dup(el) # :nodoc:
        copy = Element.new(el.type, el.value, el.attr.dup, el.options.dup)
        copy.children = el.children.map {|child| deep_dup(child) }
        copy
      end

      def self.downcase_list(list) # :nodoc:
        Array(list).map {|item| item.to_s.downcase }.freeze
      end

      def self.normalize_name_map(map) # :nodoc:
        map.each_with_object({}) do |(k, v), h|
          h[k.to_s.downcase] = Array(v).map {|item| item.to_s.downcase }.freeze
        end.freeze
      end

      private_class_method :sanitize_node, :sanitize_children, :sanitize_attributes,
                           :tag_name_for, :allowed_element?, :url_attribute?, :deep_dup,
                           :downcase_list, :normalize_name_map

    end

  end

end

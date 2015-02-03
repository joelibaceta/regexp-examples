module RegexpExamples
  class Parser
    attr_reader :regexp_string
    def initialize(regexp_string, options={})
      @regexp_string = regexp_string
      @num_groups = 0
      @current_position = 0
      RegexpExamples::ResultCountLimiters.configure!(
        options[:max_repeater_variance],
        options[:max_group_results]
      )
    end

    def parse
      repeaters = []
      while @current_position < regexp_string.length
        group = parse_group(repeaters)
        break if group.is_a? MultiGroupEnd
        if group.is_a? OrGroup
          return [OneTimeRepeater.new(group)]
        end
        @current_position += 1
        repeaters << parse_repeater(group)
      end
      repeaters
    end

    private

    def parse_group(repeaters)
      case next_char
      when '('
        group = parse_multi_group
      when ')'
        group = parse_multi_end_group
      when '['
        group = parse_char_group
      when '.'
        group = parse_dot_group
      when '|'
        group = parse_or_group(repeaters)
      when '\\'
        group = parse_after_backslash_group
      when '^', 'A'
        if @current_position == 0
          group = parse_single_char_group('') # Ignore the "illegal" character
        else
          raise IllegalSyntaxError, "Anchors cannot be supported, as they are not regular"
        end
      when '$', 'z', 'Z'
        if @current_position == (regexp_string.length - 1)
          group = parse_single_char_group('') # Ignore the "illegal" character
        else
          raise IllegalSyntaxError, "Anchors cannot be supported, as they are not regular"
        end
      else
        group = parse_single_char_group(next_char)
      end
      group
    end

    def parse_after_backslash_group
      @current_position += 1
      case
      when rest_of_string =~ /\A(\d+)/
        @current_position += ($1.length - 1) # In case of 10+ backrefs!
        group = parse_backreference_group($1)
      when rest_of_string =~ /\Ak<([^>]+)>/ # Named capture group
        @current_position += ($1.length + 2)
        group = parse_backreference_group($1)
      when BackslashCharMap.keys.include?(next_char)
        group = CharGroup.new(
          # Note: The `.dup` is important, as it prevents modifying the constant, in
          # CharGroup#init_ranges (where the '-' is moved to the front)
          BackslashCharMap[next_char].dup
        )
      when rest_of_string =~ /\A(c|C-)(.)/ # Control character
        @current_position += $1.length
        group = parse_single_char_group( parse_control_character($2) )
      when rest_of_string =~ /\Ax(\h{1,2})/ # Escape sequence
        @current_position += $1.length
        group = parse_single_char_group( parse_escape_sequence($1) )
      when rest_of_string =~ /\Au(\h{4}|\{\h{1,4}\})/ # Unicode sequence
        @current_position += $1.length
        sequence = $1.match(/\h{1,4}/)[0] # Strip off "{" and "}"
        group = parse_single_char_group( parse_unicode_sequence(sequence) )
      when rest_of_string =~ /\Ap\{([^}]+)\}/ # Named properties
        @current_position += ($1.length + 2)
        raise UnsupportedSyntaxError, "Named properties ({\\p#{$1}}) are not yet supported"
      when rest_of_string =~ /\Ag/ # Subexpression call
        # TODO: Should this be IllegalSyntaxError ?
        raise UnsupportedSyntaxError, "Subexpression calls (\g) are not yet supported"
      when rest_of_string =~ /\A[GbB]/ # Anchors
        raise IllegalSyntaxError, "Anchors cannot be supported, as they are not regular"
      when rest_of_string =~ /\AA/ # Start of string
        if @current_position == 1
          group = parse_single_char_group('') # Ignore the "illegal" character
        else
          raise IllegalSyntaxError, "Anchors cannot be supported, as they are not regular"
        end
      when rest_of_string =~ /\A[zZ]/ # End of string
        if @current_position == (regexp_string.length - 1)
          group = parse_single_char_group('') # Ignore the "illegal" character
        else
          raise IllegalSyntaxError, "Anchors cannot be supported, as they are not regular"
        end
      else
        group = parse_single_char_group( next_char )
      end
      group
    end

    def parse_repeater(group)
      case next_char
      when '*'
        repeater = parse_star_repeater(group)
      when '+'
        repeater = parse_plus_repeater(group)
      when '?'
        repeater = parse_question_mark_repeater(group)
      when '{'
        repeater = parse_range_repeater(group)
      else
        repeater = parse_one_time_repeater(group)
      end
      repeater
    end

    def parse_multi_group
      @current_position += 1
      @num_groups += 1
      group_id = nil # init
      rest_of_string.match(/\A(\?)?(:|!|=|<(!|=|[^!=][^>]*))?/) do |match|
        case
        when match[1].nil? # e.g. /(normal)/
          group_id = @num_groups.to_s
        when match[2] == ':' # e.g. /(?:nocapture)/
          @current_position += 2
          group_id = nil
        when %w(! =).include?(match[2]) # e.g. /(?=lookahead)/, /(?!neglookahead)/
          raise IllegalSyntaxError, "Lookaheads are not regular; cannot generate examples"
        when %w(! =).include?(match[3]) # e.g. /(?<=lookbehind)/, /(?<!neglookbehind)/
          raise IllegalSyntaxError, "Lookbehinds are not regular; cannot generate examples"
        else # e.g. /(?<name>namedgroup)/
          @current_position += (match[3].length + 3)
          group_id = match[3]
        end
      end
      groups = parse
      MultiGroup.new(groups, group_id)
    end

    def parse_multi_end_group
      MultiGroupEnd.new
    end

    def parse_char_group
      if rest_of_string =~ /\A\[\[:[^:]+:\]\]/
        raise UnsupportedSyntaxError, "POSIX bracket expressions are not yet implemented"
      end
      chars = []
      @current_position += 1
      if next_char == ']'
        # Beware of the sneaky edge case:
        # /[]]/ (match "]")
        chars << ']'
        @current_position += 1
      end
      until next_char == ']' \
        && !regexp_string[0..@current_position-1].match(/[^\\](\\{2})*\\\z/)
        # Beware of having an ODD number of "\" before the "]", e.g.
        # /[\]]/ (match "]")
        # /[\\]/ (match "\")
        # /[\\\]]/ (match "\" or "]")
        chars << next_char
        @current_position += 1
      end
      CharGroup.new(chars)
    end

    def parse_dot_group
      DotGroup.new
    end

    def parse_or_group(left_repeaters)
      @current_position += 1
      right_repeaters = parse
      OrGroup.new(left_repeaters, right_repeaters)
    end


    def parse_single_char_group(char)
      SingleCharGroup.new(char)
    end

    def parse_backreference_group(match)
      BackReferenceGroup.new(match)
    end

    def parse_control_character(char)
      (char.ord % 32).chr # Black magic!
      # eval "?\\C-#{char.chr}" # Doesn't work for e.g. char = "?"
    end

    def parse_escape_sequence(match)
      eval "?\\x#{match}"
    end

    def parse_unicode_sequence(match)
      eval "?\\u{#{match}}"
    end

    def parse_star_repeater(group)
      @current_position += 1
      parse_reluctant_or_possessive_repeater
      StarRepeater.new(group)
    end

    def parse_plus_repeater(group)
      @current_position += 1
      parse_reluctant_or_possessive_repeater
      PlusRepeater.new(group)
    end

    def parse_reluctant_or_possessive_repeater
      if next_char =~ /[?+]/
        # Don't treat these repeaters any differently when generating examples
        @current_position += 1
      end
    end

    def parse_question_mark_repeater(group)
      @current_position += 1
      parse_reluctant_or_possessive_repeater
      QuestionMarkRepeater.new(group)
    end

    def parse_range_repeater(group)
      match = rest_of_string.match(/\A\{(\d+)?(,)?(\d+)?\}/)
      @current_position += match[0].size
      min = match[1].to_i if match[1]
      has_comma = !match[2].nil?
      max = match[3].to_i if match[3]
      repeater = RangeRepeater.new(group, min, has_comma, max)
      parse_reluctant_or_possessive_range_repeater(repeater, min, has_comma, max)
    end

    def parse_reluctant_or_possessive_range_repeater(repeater, min, has_comma, max)
        # .{1}? should be equivalent to (?:.{1})?, i.e. NOT a "non-greedy quantifier"
        if min && !has_comma && !max && next_char == "?"
          repeater = parse_question_mark_repeater(repeater)
        else
          parse_reluctant_or_possessive_repeater
        end
        repeater
    end

    def parse_one_time_repeater(group)
      OneTimeRepeater.new(group)
    end

    def rest_of_string
      regexp_string[@current_position..-1]
    end

    def next_char
      regexp_string[@current_position]
    end
  end
end


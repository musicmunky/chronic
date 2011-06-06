module Chronic

  DEFAULT_OPTIONS = {
    :context => :future,
    :now => nil,
    :guess => true,
    :ambiguous_time_range => 6,
    :endian_precedence    => [:middle, :little],
    :ambiguous_year_future_bias => 50
  }

  class << self

    # Parses a string containing a natural language date or time. If the
    # parser can find a date or time, either a Time or Chronic::Span will
    # be returned (depending on the value of <tt>:guess</tt>). If no date
    # or time can be found, +nil+ will be returned.
    #
    # @option opts [Symbol] :context (:future)
    #   If your string represents a birthday, you can set `:context` to
    #   `:past` and if an ambiguous string is given, it will assume it is
    #   in the past. Specify `:future` or omit to set a future context.
    #
    # @option opts [Object] :now (Time.now)
    #   By setting `:now` to a Time, all computations will be based off of
    #   that time instead of `Time.now`. If set to nil, Chronic will use
    #   `Time.now`.
    #
    # @option opts [Boolean] :guess (true)
    #   By default, the parser will guess a single point in time for the given
    #   date or time. If you'd rather have the entire time span returned,
    #   set `:guess` to `false` and a {Chronic::Span} will be returned.
    #
    # @option opts [Integer] :ambiguous_time_range (6)
    #   If an Integer is given, ambiguous times (like 5:00) will be
    #   assumed to be within the range of that time in the AM to that time
    #   in the PM. For example, if you set it to <tt>7</tt>, then the parser
    #   will look for the time between 7am and 7pm. In the case of 5:00, it
    #   would assume that means 5:00pm. If <tt>:none</tt> is given, no
    #   assumption will be made, and the first matching instance of that
    #   time will be used.
    #
    # @option opts [Array] :endian_precedence ([:middle, :little])
    #   By default, Chronic will parse "03/04/2011" as the fourth day
    #   of the third month. Alternatively you can tell Chronic to parse
    #   this as the third day of the fourth month by altering the
    #   `:endian_precedence` to `[:little, :middle]`.
    #
    # @option opts [Integer] :ambiguous_year_future_bias (50)
    # @return [Time, Chronic::Span, nil]
    def parse(text, opts={})
      @text = text
      options = DEFAULT_OPTIONS.merge opts

      # ensure the specified options are valid
      (opts.keys-DEFAULT_OPTIONS.keys).each {|key| raise(InvalidArgumentException, "#{key} is not a valid option key.")}

      [:past, :future, :none].include?(options[:context]) || raise(InvalidArgumentException, "Invalid value ':#{options[:context]}' for :context specified. Valid values are :past and :future.")

      options[:now] ||= Chronic.time_class.now
      @now = options[:now]

      options[:text] = text

      # tokenize words
      tokens = tokenize(text, options)

      if Chronic.debug
        puts "+---------------------------------------------------"
        puts "| " + tokens.to_s
        puts "+---------------------------------------------------"
      end

      span = tokens_to_span(tokens, options)

      if options[:guess]
        guess span
      else
        span
      end
    end

    # Clean up the specified input text by stripping unwanted characters,
    # converting idioms to their canonical form, converting number words
    # to numbers (three => 3), and converting ordinal words to numeric
    # ordinals (third => 3rd)
    #
    # @example
    #   Chronic.pre_normalize('first day in May')
    #     #=> "1st day in may"
    #
    #   Chronic.pre_normalize('tomorrow after noon')
    #     #=> "next day future 12:00"
    #
    #   Chronic.pre_normalize('one hundred and thirty six days from now')
    #     #=> "136 days future this second"
    #
    # @param [String] text The string to normalize
    # @return [String] A new string ready for Chronic to parse
    def pre_normalize(text) #:nodoc:
      normalized_text = text.to_s.downcase
      normalized_text.gsub!(/['"\.,]/, '')
      normalized_text.gsub!(/\bsecond (of|day|month|hour|minute|second)\b/, '2nd \1')
      normalized_text = numericize_numbers(normalized_text)
      normalized_text.gsub!(/ \-(\d{4})\b/, ' tzminus\1')
      normalized_text.gsub!(/([\/\-\,\@])/) { ' ' + $1 + ' ' }
      normalized_text.gsub!(/\b0(\d+:\d+\s*pm?\b)/, '\1')
      normalized_text.gsub!(/\btoday\b/, 'this day')
      normalized_text.gsub!(/\btomm?orr?ow\b/, 'next day')
      normalized_text.gsub!(/\byesterday\b/, 'last day')
      normalized_text.gsub!(/\bnoon\b/, '12:00')
      normalized_text.gsub!(/\bmidnight\b/, '24:00')
      normalized_text.gsub!(/\bbefore now\b/, 'past')
      normalized_text.gsub!(/\bnow\b/, 'this second')
      normalized_text.gsub!(/\b(ago|before)\b/, 'past')
      normalized_text.gsub!(/\bthis past\b/, 'last')
      normalized_text.gsub!(/\bthis last\b/, 'last')
      normalized_text.gsub!(/\b(?:in|during) the (morning)\b/, '\1')
      normalized_text.gsub!(/\b(?:in the|during the|at) (afternoon|evening|night)\b/, '\1')
      normalized_text.gsub!(/\btonight\b/, 'this night')
      normalized_text.gsub!(/\b\d+:?\d*[ap]\b/,'\0m')
      normalized_text.gsub!(/(\d)([ap]m|oclock)\b/, '\1 \2')
      normalized_text.gsub!(/\b(hence|after|from)\b/, 'future')
      normalized_text
    end

    # Convert number words to numbers (three => 3)
    def numericize_numbers(text) #:nodoc:
      Numerizer.numerize(text)
    end

    # Guess a specific time within the given span
    def guess(span) #:nodoc:
      return nil if span.nil?
      if span.width > 1
        span.begin + (span.width / 2)
      else
        span.begin
      end
    end

    def definitions(options={}) #:nodoc:
      options[:endian_precedence] ||= [:middle, :little]

      @definitions ||= {
        :time => [
          Handler.new([:repeater_time, :repeater_day_portion?], nil)
        ],

        :date => [
          Handler.new([:repeater_day_name, :repeater_month_name, :scalar_day, :repeater_time, :separator_slash_or_dash?, :time_zone, :scalar_year], :handle_rdn_rmn_sd_t_tz_sy),
          Handler.new([:repeater_month_name, :scalar_day, :scalar_year], :handle_rmn_sd_sy),
          Handler.new([:repeater_month_name, :ordinal_day, :scalar_year], :handle_rmn_od_sy),
          Handler.new([:repeater_month_name, :scalar_day, :scalar_year, :separator_at?, 'time?'], :handle_rmn_sd_sy),
          Handler.new([:repeater_month_name, :ordinal_day, :scalar_year, :separator_at?, 'time?'], :handle_rmn_od_sy),
          Handler.new([:repeater_month_name, :scalar_day, :separator_at?, 'time?'], :handle_rmn_sd),
          Handler.new([:repeater_time, :repeater_day_portion?, :separator_on?, :repeater_month_name, :scalar_day], :handle_rmn_sd_on),
          Handler.new([:repeater_month_name, :ordinal_day, :separator_at?, 'time?'], :handle_rmn_od),
          Handler.new([:repeater_time, :repeater_day_portion?, :separator_on?, :repeater_month_name, :ordinal_day], :handle_rmn_od_on),
          Handler.new([:repeater_month_name, :scalar_year], :handle_rmn_sy),
          Handler.new([:scalar_day, :repeater_month_name, :scalar_year, :separator_at?, 'time?'], :handle_sd_rmn_sy),
          Handler.new([:scalar_year, :separator_slash_or_dash, :scalar_month, :separator_slash_or_dash, :scalar_day, :separator_at?, 'time?'], :handle_sy_sm_sd),
          Handler.new([:scalar_month, :separator_slash_or_dash, :scalar_year], :handle_sm_sy)
        ],

        # tonight at 7pm
        :anchor => [
          Handler.new([:grabber?, :repeater, :separator_at?, :repeater?, :repeater?], :handle_r),
          Handler.new([:grabber?, :repeater, :repeater, :separator_at?, :repeater?, :repeater?], :handle_r),
          Handler.new([:repeater, :grabber, :repeater], :handle_r_g_r)
        ],

        # 3 weeks from now, in 2 months
        :arrow => [
          Handler.new([:scalar, :repeater, :pointer], :handle_s_r_p),
          Handler.new([:pointer, :scalar, :repeater], :handle_p_s_r),
          Handler.new([:scalar, :repeater, :pointer, 'anchor'], :handle_s_r_p_a)
        ],

        # 3rd week in march
        :narrow => [
          Handler.new([:ordinal, :repeater, :separator_in, :repeater], :handle_o_r_s_r),
          Handler.new([:ordinal, :repeater, :grabber, :repeater], :handle_o_r_g_r)
        ]
      }

      endians = [
        Handler.new([:scalar_month, :separator_slash_or_dash, :scalar_day, :separator_slash_or_dash, :scalar_year, :separator_at?, 'time?'], :handle_sm_sd_sy),
        Handler.new([:scalar_day, :separator_slash_or_dash, :scalar_month, :separator_slash_or_dash, :scalar_year, :separator_at?, 'time?'], :handle_sd_sm_sy)
      ]

      case endian = Array(options[:endian_precedence]).first
      when :little
        @definitions[:endian] = endians.reverse
      when :middle
        @definitions[:endian] = endians
      else
        raise InvalidArgumentException, "Unknown endian option '#{endian}'"
      end

      @definitions
    end

    private

    def tokenize(text, options) #:nodoc:
      text = pre_normalize(text)
      tokens = text.split(' ').map { |word| Token.new(word) }
      [Repeater, Grabber, Pointer, Scalar, Ordinal, Separator, TimeZone].each do |tok|
        tokens = tok.scan(tokens, options)
      end
      tokens.select { |token| token.tagged? }
    end

    def tokens_to_span(tokens, options) #:nodoc:
      definitions = definitions(options)

      (definitions[:date] + definitions[:endian]).each do |handler|
        if handler.match(tokens, definitions)
          puts "-date" if Chronic.debug
          good_tokens = tokens.select { |o| !o.get_tag Separator }
          return Handlers.send(handler.handler_method, good_tokens, options)
        end
      end

      definitions[:anchor].each do |handler|
        if handler.match(tokens, definitions)
          puts "-anchor" if Chronic.debug
          good_tokens = tokens.select { |o| !o.get_tag Separator }
          return Handlers.send(handler.handler_method, good_tokens, options)
        end
      end

      definitions[:arrow].each do |handler|
        if handler.match(tokens, definitions)
          puts "-arrow" if Chronic.debug
          tags = [SeparatorAt, SeparatorSlashOrDash, SeparatorComma]
          good_tokens = tokens.reject { |o| tags.any? { |t| o.get_tag(t) } }
          return Handlers.send(handler.handler_method, good_tokens, options)
        end
      end

      definitions[:narrow].each do |handler|
        if handler.match(tokens, definitions)
          puts "-narrow" if Chronic.debug
          good_tokens = tokens.select { |o| !o.get_tag Separator }
          return Handlers.send(handler.handler_method, tokens, options)
        end
      end

      puts "-none" if Chronic.debug
      return nil
    end

  end

  # Internal exception
  class ChronicPain < Exception #:nodoc:

  end

  # This exception is raised if an invalid argument is provided to
  # any of Chronic's methods
  class InvalidArgumentException < Exception

  end
end

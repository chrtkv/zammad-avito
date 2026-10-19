module AvitoMessenger
  # Avito takes at most 1000 characters per message. A longer reply goes out as several messages, cut where a
  # reader would pause: a blank line, then a line break, then the end of a sentence, then a space. A text
  # with none of those in reach is cut hard at the limit.
  module TextSplitter
    BREAKS = [
      /\n[ \t]*\n/,   # paragraph
      /\n/,           # line
      /[.!?…]+["»)]*\s/, # sentence
      /\s/,           # word
    ].freeze

    module_function

    def split(text, limit: Client::TEXT_LIMIT)
      rest   = text.to_s.gsub("\r\n", "\n").strip
      chunks = []

      while rest.length > limit
        cut = cut_position(rest, limit)
        chunks << rest[0, cut].rstrip
        rest = rest[cut..].lstrip
      end
      chunks << rest

      chunks.reject(&:empty?)
    end

    # The end of the last break that fits, preferring stronger breaks as long as they are not in the first
    # third of the window (which would leave a stub of a message).
    def cut_position(text, limit)
      window = text[0, limit + 1]
      floor  = limit / 3

      BREAKS.each do |pattern|
        position = last_break_end(window, pattern, limit)
        return position if position && position > floor
      end

      limit
    end

    def last_break_end(window, pattern, limit)
      position = nil
      window.scan(pattern) do
        match_end = Regexp.last_match.end(0)
        position = match_end if match_end <= limit
      end
      position
    end
  end
end

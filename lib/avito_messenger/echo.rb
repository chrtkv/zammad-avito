module AvitoMessenger
  # Recognises Avito reporting back a message Zammad itself sent, when the message id never made it onto the
  # article (the send succeeded and the save after it did not). Such an own message has the same text as a
  # piece of a reply Zammad sent to the same chat a moment earlier.
  #
  #   Echo.match(message, sent) # sent: [{ article_id:, chat_id:, text:, sent_at: }]
  #
  # Pass only pieces whose Avito id is still unknown: a piece with a known id is matched by id, and a
  # greeting a manager repeats in Avito must not be taken for the echo of an earlier one.
  module Echo
    WINDOW = 600

    module_function

    # The article id the message echoes, or nil when a manager wrote it in Avito.
    def match(message, sent, window: WINDOW)
      return nil if !message.own? || message.type != 'text'

      text = normalize(message.text)
      return nil if text.empty?

      candidate = sent.find do |piece|
        piece[:chat_id].to_s == message.chat_id.to_s &&
          normalize(piece[:text]) == text &&
          within?(piece[:sent_at], message.created_at, window)
      end
      candidate && candidate[:article_id]
    end

    def normalize(text)
      text.to_s.gsub(/\s+/, ' ').strip
    end

    def within?(sent_at, created_at, window)
      return false if sent_at.nil? || created_at.nil?

      (created_at - sent_at).abs <= window
    end
  end
end

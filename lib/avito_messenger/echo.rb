module AvitoMessenger
  # Recognises Avito reporting back a message Zammad itself sent, when the message id never made it onto the
  # article (the send went out and its answer was lost, or the save after it failed). Such an own message is
  # the same piece (same text, or an image for an image) in the same chat, written at or after the attempt.
  #
  #   Echo.match(message, sent) # sent: [{ article_id:, chat_id:, kind: 'text' | 'image', text:, sent_at: }]
  #
  # Pass only pieces whose Avito id is still unknown: a piece with a known id is matched by id, and a
  # greeting a manager repeats in Avito must not be taken for the echo of an earlier one.
  module Echo
    # How long after an attempt Avito may report the message.
    WINDOW = 600
    # How far Avito's clock may run behind ours. A message from before the attempt, beyond this, was written
    # by someone else (a manager in Avito) and must not pass for the reply.
    SKEW = 30

    module_function

    # The article id the message echoes, or nil when a manager wrote it in Avito.
    def match(message, sent, window: WINDOW, skew: SKEW)
      return nil if !message.own?

      candidate = sent.find do |piece|
        piece[:chat_id].to_s == message.chat_id.to_s &&
          same_piece?(piece, message) &&
          after_attempt?(piece[:sent_at], message.created_at, window, skew)
      end
      candidate && candidate[:article_id]
    end

    def same_piece?(piece, message)
      return message.type == 'image' if piece[:kind].to_s == 'image'
      return false if message.type != 'text'

      text = normalize(message.text)
      !text.empty? && normalize(piece[:text]) == text
    end

    def normalize(text)
      text.to_s.gsub(/\s+/, ' ').strip
    end

    def after_attempt?(sent_at, created_at, window, skew)
      return false if sent_at.nil? || created_at.nil?

      created_at >= sent_at - skew && created_at <= sent_at + window
    end
  end
end

module AvitoChannel
  # Retries of the Avito jobs, in one place: one counter, ActiveJob's executions (retry_job carries it over),
  # and one rule for the wait: the delay Avito names in a 429, otherwise `base` for every run so far.
  #
  # The jobs rescue their errors and call this instead of using ActiveJob's retry_on, which keeps a count and
  # a wait of its own: a delivery that hit 429 four times was then retried by retry_on as well, and was sent
  # seven times with four "unable to send" notes (review, 2026-10-21). Giving up does not raise either, since
  # Delayed Job would retry a raised job once more on its own.
  module JobRetry
    # Whether the job may run again after this run.
    def retries_left?(attempts)
      executions < attempts
    end

    def retry_later(error, base:)
      wait = error.is_a?(AvitoMessenger::Error::RateLimited) ? error.retry_after : executions * base
      retry_job(wait: wait.seconds, error:)
    end
  end
end

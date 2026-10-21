class ChannelsAvitoController < ApplicationController
  prepend_before_action :authenticate_and_authorize!, except: [:webhook]
  skip_before_action :verify_csrf_token, only: [:webhook]

  SENSITIVE_FIELDS = %w[client_secret].freeze

  def index
    assets   = {}
    channels = AvitoChannel.channels.reorder(:id).to_a
    channels.each { |channel| assets = channel.assets(assets) }

    render json: {
      assets:       assets,
      channel_ids:  channels.map(&:id),
      webhook_urls: channels.to_h { |channel| [channel.id, AvitoChannel::Account.webhook_url(channel)] },
      history:      channels.to_h { |channel| [channel.id, AvitoChannel::History.latest(channel)&.as_json] },
    }
  end

  def add
    channel = save_account(nil)
    AvitoChannel::Account.subscribe!(channel)
    render json: masked(channel.reload)
  end

  def update
    channel = save_account(find_channel)
    AvitoChannel::Account.resubscribe_if_moved!(channel)
    render json: masked(channel.reload)
  end

  def subscribe
    channel = find_channel
    AvitoChannel::Account.subscribe!(channel)
    render json: masked(channel.reload)
  end

  def enable
    find_channel.update!(active: true)
    render json: {}
  end

  def disable
    find_channel.update!(active: false)
    render json: {}
  end

  def check
    render json: AvitoChannel::Account.check(find_channel)
  end

  def sync
    AvitoSyncJob.perform_later(find_active_channel.id)
    render json: {}
  end

  def history
    render json: AvitoChannel::History.start!(find_active_channel, days: params[:days]).as_json
  rescue AvitoChannel::History::Invalid => e
    raise Exceptions::UnprocessableContent, e.message
  end

  # The progress of a history load, which the admin page follows while it runs.
  def history_state
    render json: AvitoChannel::History.latest(find_channel)&.as_json
  end

  def destroy
    AvitoChannel::Account.destroy!(find_channel)
    render json: {}
  end

  # Avito wants a 200 within 2 s: check who is calling and hand the message to a job.
  def webhook
    channel = AvitoChannel::Account.by_callback_token(params[:callback_token])
    raise ActiveRecord::RecordNotFound, 'unknown Avito webhook' if !channel

    AvitoChannel::Account.note_webhook(channel)
    body = parse_body
    return render(json: {}, status: :ok) if AvitoMessenger::WebhookEvent.probe?(body) || !channel.active

    event = AvitoMessenger::WebhookEvent.parse(body)
    raise Exceptions::UnprocessableContent, 'event is for another account' if !event.for_account?(channel.options[:user_id])

    if event.message?
      wait = event.message.own? ? AvitoChannel::OWN_MESSAGE_DELAY : 0
      AvitoImportJob.set(wait: wait.seconds).perform_later(channel.id, body['payload']['value'])
    end

    render json: {}, status: :ok
  rescue AvitoMessenger::Error::BadPayload => e
    raise Exceptions::UnprocessableContent, e.message
  end

  private

  def find_channel
    Channel.find_by!(id: params[:id], area: AvitoChannel::AREA)
  end

  def find_active_channel
    channel = find_channel
    raise Exceptions::UnprocessableContent, __('The Avito account is disabled.') if !channel.active

    channel
  end

  def save_account(channel)
    AvitoChannel::Account.save!(params.permit(:client_id, :client_secret, :group_id, :backfill_days, :poll_interval,
                                              :mark_read, :webhook_base_url), channel)
  rescue AvitoChannel::Account::Invalid => e
    raise Exceptions::UnprocessableContent, e.message
  end

  def parse_body
    raw = request.raw_post.presence || '{}'
    JSON.parse(raw)
  rescue JSON::ParserError
    raise Exceptions::UnprocessableContent, 'body is not JSON'
  end

  def masked(channel)
    mask_sensitive_values(channel.as_json, channel)
  end

  def sensitive_attributes(_input, object)
    return Channel::SENSITIVE_FIELDS if object.is_a?(Channel)

    SENSITIVE_FIELDS
  end
end

# The texts added after the first migration (AvitoChannel::Setup::TRANSLATIONS), for systems that ran it.
class AvitoChannelTexts < ActiveRecord::Migration[8.0]
  def up
    return if !Setting.exists?(name: 'system_init_done')

    AvitoChannel::Setup.ensure!
  end
end

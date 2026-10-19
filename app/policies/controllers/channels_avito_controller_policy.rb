class Controllers::ChannelsAvitoControllerPolicy < Controllers::ApplicationControllerPolicy
  default_permit!('admin.channel_avito')
end

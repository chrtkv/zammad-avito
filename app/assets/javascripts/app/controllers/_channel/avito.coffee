class ChannelAvito extends App.ControllerSubContent
  @requiredPermission: 'admin.channel_avito'
  events:
    'click .js-new':       'new'
    'click .js-edit':      'edit'
    'click .js-delete':    'delete'
    'click .js-disable':   'disable'
    'click .js-enable':    'enable'
    'click .js-subscribe': 'subscribe'
    'click .js-check':     'check'
    'click .js-sync':      'sync'
    'click .js-history':   'history'

  # What a failed "Check connection" means, by the status the server reports.
  @checkFailures:
    auth:          __('Avito refused the API keys.')
    subscription:  __('Avito refuses the chats: the account has no Messenger API subscription.')
    rate_limited:  __('Avito is limiting requests from this system. Try again in a few minutes.')
    network:       __('Avito could not be reached from this system.')
    other_account: __('These keys now open another Avito account.')
    error:         __('Avito answered with an error.')

  constructor: ->
    super

    @title __('Avito'), true
    @load()

  load: =>
    @startLoading()
    @ajax(
      id:   'avito_index'
      type: 'GET'
      url:  "#{@apiPath}/channels_avito"
      processData: true
      success: (data) =>
        @stopLoading()
        App.Collection.loadAssets(data.assets)
        @render(data)
    )

  render: (data) =>
    channels = []
    for channel_id in data.channel_ids
      channel = App.Channel.find(channel_id)
      continue if !channel || !channel.options

      group   = channel.group_id && App.Group.find(channel.group_id)
      history = data.history?[channel_id]
      channels.push(
        channel:    channel
        groupName:  if group then group.displayName() else '-'
        webhookUrl: data.webhook_urls[channel_id]
        history:    history
        historyAt:  history?.finished_at && new Date(history.finished_at * 1000).toISOString()
      )

    @html App.view('avito/index')(
      items: channels
    )

  channelId: (e) ->
    $(e.target).closest('.action').data('id')

  new: (e) =>
    e.preventDefault()
    new ChannelAvitoAccount(
      container: @el.parents('.content')
      load:      @load
    )

  edit: (e) =>
    e.preventDefault()
    new ChannelAvitoAccount(
      channel:   App.Channel.find(@channelId(e))
      container: @el.parents('.content')
      load:      @load
    )

  delete: (e) =>
    e.preventDefault()
    id = @channelId(e)
    new App.ControllerConfirm(
      message:     __('Are you sure? Messages already in tickets stay, new ones will no longer arrive.')
      buttonClass: 'btn--danger'
      container:   @el.closest('.content')
      callback: =>
        @ajax(
          id:   'avito_delete'
          type: 'DELETE'
          url:  "#{@apiPath}/channels_avito/#{id}"
          processData: true
          success: @load
        )
    )

  disable: (e) =>
    @post(e, 'disable')

  enable: (e) =>
    @post(e, 'enable')

  subscribe: (e) =>
    @post(e, 'subscribe')

  check: (e) =>
    e.preventDefault()
    id     = @channelId(e)
    result = $(e.target).closest('.action').find('.js-checkResult')
    show   = (params) -> result.removeClass('hide').html(App.view('avito/check')(params))

    show(checking: true)
    @ajax(
      id:   "avito_check_#{id}"
      type: 'POST'
      url:  "#{@apiPath}/channels_avito/#{id}/check"
      processData: true
      success: (data) ->
        show(result: data, failure: ChannelAvito.checkFailures[data.status] || ChannelAvito.checkFailures.error)
      error: (xhr) ->
        show(result: { status: 'error', message: xhr.responseJSON?.error }, failure: ChannelAvito.checkFailures.error)
    )

  sync: (e) =>
    e.preventDefault()
    @ajax(
      id:   'avito_sync'
      type: 'POST'
      url:  "#{@apiPath}/channels_avito/#{@channelId(e)}/sync"
      processData: true
      success: =>
        @notify(type: 'success', msg: __('The account is being checked for missed messages.'))
        # The poll runs in the background; its outcome shows under "Polling" once it is done.
        @delay(@load, 5000, 'avito_sync_reload')
    )

  history: (e) =>
    e.preventDefault()
    new ChannelAvitoHistory(
      channelId: @channelId(e)
      container: @el.parents('.content')
      load:      @load
    )

  post: (e, action) =>
    e.preventDefault()
    @ajax(
      id:   "avito_#{action}"
      type: 'POST'
      url:  "#{@apiPath}/channels_avito/#{@channelId(e)}/#{action}"
      processData: true
      success: @load
    )

class ChannelAvitoAccount extends App.ControllerModal
  shown: true
  buttonCancel: true
  small: true

  constructor: ->
    @head   = if @channel then __('Avito Account') else __('Add Avito Account')
    @button = if @channel then __('Save') else __('Add')
    super

  content: ->
    options = @channel?.options || {}
    content = $(App.view('avito/account')(
      channel: @channel
      options: options
      sync:    options.sync || {}
    ))
    content.find('.js-messagesGroup').replaceWith App.UiElement.tree_select.render(
      name:       'group_id'
      multiple:   false
      limit:      100
      null:       false
      relation:   'Group'
      nulloption: true
      value:      @channel?.group_id || 1
    )
    content

  onClosed: =>
    return if !@isChanged
    @isChanged = false
    @load()

  onSubmit: (e) =>
    element = $(e.target).closest('form').get(0)
    if element && element.reportValidity && !element.reportValidity()
      return false

    params = @formParams()
    params.mark_read = !!params.mark_read

    @formDisable(e)
    @ajax(
      id:   'avito_save'
      type: if @channel then 'PUT' else 'POST'
      url:  if @channel then "#{@apiPath}/channels_avito/#{@channel.id}" else "#{@apiPath}/channels_avito"
      data: JSON.stringify(params)
      processData: true
      success: =>
        @isChanged = true
        @close()
      error: (xhr) =>
        data = JSON.parse(xhr.responseText)
        @formEnable(e)
        @el.find('.alert').removeClass('hidden').text(App.i18n.translateContent(data.error || __('The Avito account could not be saved.')))
    )

class ChannelAvitoHistory extends App.ControllerModal
  shown: true
  buttonCancel: true
  small: true
  head: __('Load History')
  buttonSubmit: __('Load')

  content: ->
    $(App.view('avito/history')())

  onSubmit: (e) =>
    element = $(e.target).closest('form').get(0)
    if element && element.reportValidity && !element.reportValidity()
      return false

    @formDisable(e)
    @ajax(
      id:   'avito_history'
      type: 'POST'
      url:  "#{@apiPath}/channels_avito/#{@channelId}/history"
      data: JSON.stringify(days: @formParams().days)
      processData: true
      success: =>
        @close()
        @load()
      error: (xhr) =>
        @formEnable(e)
        @el.find('.alert').removeClass('hidden').text(App.i18n.translateContent(xhr.responseJSON?.error || __('The history could not be loaded.')))
    )

App.Config.set('Avito', { prio: 5600, name: __('Avito'), parent: '#channels', target: '#channels/avito', controller: ChannelAvito, permission: ['admin.channel_avito'] }, 'NavBarAdmin')

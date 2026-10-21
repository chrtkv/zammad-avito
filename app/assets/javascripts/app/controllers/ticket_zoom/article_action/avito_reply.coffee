# "Reply" on Avito messages, and the Avito article type in the reply form of tickets that came from Avito.
class AvitoReply
  @TYPE: 'avito message'

  @action: (actions, ticket, article, ui) ->
    return actions if !ticket.editable()
    return actions if ticket.currentView() is 'customer'
    return actions if article.type.name isnt AvitoReply.TYPE
    return actions if article.sender.name isnt 'Customer'

    actions.push {
      name: __('reply')
      type: 'avitoMessageReply'
      icon: 'reply'
      href: '#'
    }
    actions

  @perform: (articleContainer, type, ticket, article, ui) ->
    return true if type isnt 'avitoMessageReply'

    ui.scrollToCompose()

    articleNew =
      to:          ''
      cc:          ''
      body:        ui.el.closest('.ticketZoom').find('.article-add [data-name="body"]').html().trim() || ''
      in_reply_to: article.message_id || ''

    App.Event.trigger('ui::ticket::setArticleType', {
      ticket:   ticket
      type:     App.TicketArticleType.find(article.type_id)
      article:  articleNew
      position: 'end'
    })

    true

  # By the Avito chat the ticket belongs to, not by its first article's type: a chat can open with Avito's own
  # notice, which is an internal note.
  @fromAvito: (ticket) ->
    return false if !ticket
    return true if ticket.preferences?.avito?.chat_id
    return false if !ticket.create_article_type_id
    App.TicketArticleType.find(ticket.create_article_type_id)?.name is AvitoReply.TYPE

  @articleTypes: (articleTypes, ticket, ui) ->
    return articleTypes if !ticket || ticket.currentView() is 'customer'
    return articleTypes if !AvitoReply.fromAvito(ticket)

    # The reply form asks for its types while it is being built, before it picks the default one (ui.type is
    # unset then): a ticket from Avito starts on an Avito reply instead of an internal note. A type the agent
    # left in a draft is kept. The form asks again before every type switch; those calls leave it alone.
    ui.defaults.type ||= AvitoReply.TYPE if ui?.defaults && !ui.type

    # Avito takes plain text; a longer reply is sent as several messages of 1000 characters.
    articleTypes.push {
      name:              AvitoReply.TYPE
      icon:              'chat'
      attributes:        []
      internal:          false
      features:          ['attachment']
      maxTextLength:     10000
      warningTextLength: 1000
    }
    articleTypes

  @setArticleTypePost: (type, ticket, ui) ->
    # After a reply is sent the form resets to a note with empty defaults; go back to an Avito reply. An agent
    # choosing a note keeps it: the defaults are not empty then.
    if type is 'note' && ui?.defaults && _.isEmpty(ui.defaults) && ticket?.currentView() isnt 'customer' && AvitoReply.fromAvito(ticket)
      ui.defaults.type = AvitoReply.TYPE
      ui.setArticleTypePre(AvitoReply.TYPE)
      ui.setArticleTypePost(AvitoReply.TYPE)
      return

    return if type isnt AvitoReply.TYPE

    AvitoReply.pasteImagesAsAttachments(ui)

    rawHTML   = ui.$('[data-name=body]').html()
    cleanHTML = App.Utils.htmlRemoveRichtext(rawHTML)
    if cleanHTML && cleanHTML.html() != rawHTML
      ui.$('[data-name=body]').html(cleanHTML)

  # A picture pasted into an Avito reply goes in as an attachment, sent like one picked as a file. The editor
  # would put it into the text as an inline image, which an Avito message cannot carry and which the text's
  # cleaning (@params) removes: the picture vanished (2026-10-22). Bound once per form, in the capture phase on
  # the form, so it runs before the editor's own paste handling; it acts only while the reply is an Avito one
  # and the clipboard holds a picture without text (text and HTML are pasted as before).
  @pasteImagesAsAttachments: (ui) ->
    form = ui.$('.article-add').get(0)
    return if !form || form.avitoPasteBound
    form.avitoPasteBound = true

    form.addEventListener('paste', (e) ->
      return if ui.type isnt AvitoReply.TYPE
      return if !$(e.target).closest('[data-name=body]').length

      files = AvitoReply.clipboardImages(e.clipboardData)
      return if _.isEmpty(files)

      e.preventDefault()
      e.stopPropagation()
      AvitoReply.attach(ui, files)
    , true)

  @clipboardImages: (clipboardData) ->
    return [] if !clipboardData
    return [] if (clipboardData.getData('text/plain') || '').trim()

    stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, '')
    files = []
    for item, index in clipboardData.items || []
      continue if item.kind isnt 'file' || item.type.indexOf('image/') isnt 0
      file = item.getAsFile()
      continue if !file
      extension = item.type.split('/')[1].replace('jpeg', 'jpg').replace(/\+.*/, '')
      files.push(new File([file], "image-#{stamp}-#{index + 1}.#{extension}", type: item.type))
    files

  # Hands the files to the form's attachment field, as if picked there: Zammad's own upload takes them on.
  @attach: (ui, files) ->
    input = ui.$('.article-attachment input[type=file]').get(0)
    return if !input

    transfer = new DataTransfer()
    transfer.items.add(file) for file in files
    input.files = transfer.files
    input.dispatchEvent(new Event('change', bubbles: true))

  @params: (type, params, ui) ->
    if type is AvitoReply.TYPE
      App.Utils.htmlRemoveRichtext(ui.$('[data-name=body]'), false)
      params.content_type = 'text/plain'
      params.body         = App.Utils.html2text(params.body, true)

    params

  # Avito takes images only. Delivery refuses anything else too, but by then the reply is saved and only its
  # failed status says why; here the agent can still remove the file.
  @validation: (type, params, ui) ->
    return true if type isnt AvitoReply.TYPE

    others = _.filter(ui.attachments || [], (file) ->
      (ui.attachmentContentType(file) || '').indexOf('image/') isnt 0
    )
    return true if _.isEmpty(others)

    new App.ControllerModal(
      head: __('Avito accepts only images')
      buttonCancel: __('Cancel')
      buttonCancelClass: 'btn--danger'
      buttonSubmit: false
      message: App.i18n.translatePlain(__('Remove the attachments that are not images: %s'), _.pluck(others, 'filename').join(', '))
      shown: true
      small: true
      container: ui.el.closest('.content')
    )
    false

App.Config.set('310-AvitoReply', AvitoReply, 'TicketZoomArticleAction')

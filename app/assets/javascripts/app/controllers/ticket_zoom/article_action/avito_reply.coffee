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

  @fromAvito: (ticket) ->
    return false if !ticket || !ticket.create_article_type_id
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

    rawHTML   = ui.$('[data-name=body]').html()
    cleanHTML = App.Utils.htmlRemoveRichtext(rawHTML)
    if cleanHTML && cleanHTML.html() != rawHTML
      ui.$('[data-name=body]').html(cleanHTML)

  @params: (type, params, ui) ->
    if type is AvitoReply.TYPE
      App.Utils.htmlRemoveRichtext(ui.$('[data-name=body]'), false)
      params.content_type = 'text/plain'
      params.body         = App.Utils.html2text(params.body, true)

    params

App.Config.set('310-AvitoReply', AvitoReply, 'TicketZoomArticleAction')

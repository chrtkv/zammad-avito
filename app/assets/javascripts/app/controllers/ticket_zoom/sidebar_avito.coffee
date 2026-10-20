# The "Avito" tab of a ticket that came from an Avito chat: the listing the chat is about, its price and link,
# the shop's account, and a link to the chat itself.
class SidebarAvito extends App.Controller
  # Four dots in Avito's colours, drawn here: Zammad's icon sprite has no Avito mark, and adding one would mean
  # rebuilding the sprite.
  @BADGE: '''
    <svg class="icon icon-avito" viewBox="0 0 24 24" width="24" height="24" aria-hidden="true">
      <circle cx="7.5" cy="7.5" r="5.5" fill="#97cf26"/>
      <circle cx="18" cy="6" r="3" fill="#00aaff"/>
      <circle cx="16.5" cy="16.5" r="5" fill="#a169f7"/>
      <circle cx="6" cy="18" r="3" fill="#ff6163"/>
    </svg>
  '''

  sidebarItem: =>
    return if !@avito()

    @item = {
      name:            'avito'
      badgeCallback:   (el) -> el.html(SidebarAvito.BADGE)
      sidebarHead:     __('Avito')
      sidebarCallback: @showAvito
      sidebarActions:  []
    }
    @item

  avito: =>
    preferences = @ticket?.preferences
    return if !preferences || !preferences.avito || !preferences.avito.chat_id
    preferences.avito

  showAvito: (el) =>
    el.html App.view('avito/sidebar')(
      avito:   @avito()
      chatUrl: "https://www.avito.ru/profile/messenger/channel/#{encodeURIComponent(@avito().chat_id)}"
    )

App.Config.set('450-Avito', SidebarAvito, 'TicketZoomSidebar')

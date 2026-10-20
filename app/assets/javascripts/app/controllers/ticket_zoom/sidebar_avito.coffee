# The "Avito" tab of a ticket that came from an Avito chat: the listing the chat is about, its price and link,
# the shop's account, and a link to the chat itself.
class SidebarAvito extends App.Controller
  # Avito's four dots (small top left, large top right, large bottom left, medium bottom right), drawn here:
  # Zammad's icon sprite has no Avito mark, and adding one would mean rebuilding the sprite. No fill of its own,
  # so it takes the tab's colour like the other sidebar icons.
  @BADGE: '''
    <svg class="icon icon-avito" viewBox="0 0 24 24" width="24" height="24" aria-hidden="true">
      <circle cx="6" cy="5.5" r="2.5"/>
      <circle cx="15.5" cy="7.5" r="5.5"/>
      <circle cx="7.5" cy="16" r="6"/>
      <circle cx="17.5" cy="17.5" r="3.8"/>
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

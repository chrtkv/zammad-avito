# The "Avito" tab of a ticket that came from an Avito chat: the listing the chat is about, its price and link,
# the shop's account, and a link to the chat itself.
class SidebarAvito extends App.Controller
  sidebarItem: =>
    return if !@avito()

    @item = {
      name:            'avito'
      badgeIcon:       'chat'
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

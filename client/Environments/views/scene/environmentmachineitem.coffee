class EnvironmentMachineItem extends EnvironmentItem

  JView.mixin @prototype

  constructor:(options={}, data)->

    options.cssClass           = 'machine'
    options.joints             = ['left', 'right']
    options.staticJoints       = ['right']

    options.allowedConnections =
      EnvironmentDomainItem : ['right']
      EnvironmentExtraItem  : ['left']

    super options, data

    @terminalIcon = new KDCustomHTMLView
      tagName     : "span"
      cssClass    : "terminal"
      click       : @bound "openTerminal"

  contextMenuItems : ->
    colorSelection = new ColorSelection selectedColor : @getOption 'colorTag'
    colorSelection.on "ColorChanged", @bound 'setColorTag'

    vmName = @getData().hostnameAlias
    vmAlwaysOnSwitch = new VMAlwaysOnToggleButtonView null, {vmName}
    items =
      customView4         : vmAlwaysOnSwitch
      'Re-initialize VM'  :
        disabled          : KD.isGuest()
        callback          : ->
          KD.getSingleton("vmController").reinitialize vmName
          @destroy()
      'Open VM Terminal'  :
        callback          : =>
          @openTerminal()
          @destroy()
        separator         : yes
      'Update init script':
        separator         : yes
        callback          : @bound "showInitScriptEditor"
      'Delete'            :
        disabled          : KD.isGuest()
        separator         : yes
        action            : 'delete'
      customView3         : colorSelection

    return items

  openTerminal:->
    vmName = @getData().hostnameAlias
    KD.getSingleton("router").handleRoute "/Terminal", replaceState: yes
    KD.getSingleton("appManager").open "Terminal", params: {vmName}, forceNew: yes

  confirmDestroy:->
    KD.getSingleton('vmController').remove @getData().hostnameAlias, @bound "destroy"

  showInitScriptEditor: ->
    modal =  new EditorModal
      editor              :
        title             : "VM Init Script Editor <span>(experimental)</span>"
        content           : @data.meta?.initScript or ""
        saveMessage       : "VM init script saved"
        saveFailedMessage : "Couldn't save VM init script"
        saveCallback      : (script, modal) =>
          KD.remote.api.JVM.updateInitScript @data.hostnameAlias, script, (err, res) =>
            if err
              modal.emit "SaveFailed"
            else
              modal.emit "Saved"
              @data.meta or= {}
              @data.meta.initScript = Encoder.htmlEncode modal.editor.getValue()

  pistachio:->
    {label, provider, publicAddress} = @getData()
    title = label or provider

    """
      <div class='details'>
        <span class='toggle'></span>
        <h3>#{title}</h3>
        <a href="http://#{publicAddress}" target="_blank" title="#{publicAddress}">
          <span class='url'></span>
        </a>
        {{> @terminalIcon}}
        {{> @chevron}}
      </div>
    """

jraphical   = require 'jraphical'
KodingError = require '../../error'

JAccount    = require '../account'
JUser       = require '../user'

{argv}      = require 'optimist'
KONFIG      = require('koding-config-manager').load("main.#{argv.c}")

module.exports = class JReward extends jraphical.Message

  {Relationship} = jraphical

  {race, secure, daisy, dash, signature, ObjectId} = require 'bongo'

  @share()

  @set

    sharedMethods     :

      static          :
        addCustomReward:
          (signature Object, Function)
        fetchEarnedAmount:
          (signature Object, Function)
        some:
          (signature Object, Object, Function)
        fetchCustomData:
          (signature Object, Object, Function)

    sharedEvents      :
      static          : []
      instance        : []

    indexes           :

      # we need a compound index here
      # since bongo is not supporting them
      # we need to manually define following:
      #
      #   - { providedBy:1, originId:1, sourceCampaign:1 } (unique)
      #

      type            : 'sparse'
      unit            : 'sparse'
      originId        : 'sparse'
      sourceCampaign  : 'sparse'
      providedBy      : 'sparse'
      confirmed       : 'sparse'

    schema            :
      # for now we only have disk space
      type            :
        type          : String
      unit            :
        type          : String
      amount          :
        type          : Number
      sourceCampaign  :
        type          : String
        default       : "register"
      createdAt       :
        type          : Date
        default       : -> new Date
      providedBy      :
        type          : ObjectId
      originId        :
        type          : ObjectId
        required      : yes
      confirmed       :
        type          : Boolean
        default       : -> no


  # Helpers
  # -------

  useDefault = (options)->

    options.unit ?= "MB"
    options.type ?= "disk"

    return options


  fetchEarnedReward = (options, callback)->

    { originId, unit, type } = useDefault options

    JEarnedReward = require './earnedreward'
    JEarnedReward.one { originId, unit, type }, callback


  aggregateAmount = (options, callback)->

    { originId, unit, type } = useDefault options

    JReward.aggregate
      $match     : { unit, type, originId, confirmed: yes }
    ,
      $group     :
        _id      : "$originId"
        total    :
          $sum   : "$amount"

    , (err, res)->

      return callback err      if err?
      return callback null, 0  unless res?

      callback null, res[0]?.total ? 0



  # Private Methods
  # ---------------

  @updateEarnedAmount = (options, callback)->

    { originId, unit, type, amount } = useDefault options

    # Force maximum possible disk size to 17000MB ~ 17GB
    if type is "disk" and unit is "MB"
      amount = Math.min amount, 17000

    JEarnedReward = require './earnedreward'
    JEarnedReward.update { originId, unit, type }
    ,
      $set: { amount }
    ,
      upsert: yes
    ,
      (err)-> callback err


  @calculateAndUpdateEarnedAmount = (options, callback)->

    options = useDefault options

    aggregateAmount options, (err, amount)->

      return callback err  if err?

      options.amount = amount

      JReward.updateEarnedAmount options, (err)->
        return callback err  if err?

        callback null, amount


  @fetchEarnedAmount = (options, callback)->

    options = useDefault options

    fetchEarnedReward options, (err, earnedReward)->
      return callback err  if err?

      callback null, earnedReward?.amount or 0

      # We can manually call this if we need.
      # JReward.calculateAndUpdateEarnedAmount options, callback



  # Shared Methods
  # --------------

  @addCustomReward = secure (client, options, callback)->

    {delegate} = client.connection
    unless delegate.can 'administer accounts'
      return callback new KodingError "Not allowed to create custom rewards."

    { username, type, unit } = useDefault options

    unless username
      return callback new KodingError "Please set username"

    providedBy = client?.connection?.delegate?.getId()

    return callback { message : "account is not set" }  if not providedBy

    JAccount.one 'profile.nickname': username, (err, account)->

      return callback err if err

      unless account
        return callback new KodingError "Account not found"

      originId = account.getId()

      reward = new JReward {
        amount         : options.amount         or 512
        sourceCampaign : options.sourceCampaign or "register"
        confirmed      : yes
        providedBy, originId, type, unit
      }

      reward.save (err)->

        return callback err if err

        options = { unit, type, originId }

        JReward.calculateAndUpdateEarnedAmount options, (err)->

          return callback err if err
          callback null, reward


  @fetchEarnedAmount$ = secure (client, options, callback)->

    originId = client?.connection?.delegate?.getId()

    return callback { message : "account is not set" }  unless originId

    options         ?= {}
    options.originId = originId

    @fetchEarnedAmount options, callback


  @some$ = secure (client, selector, options, callback)->

    originId = client?.connection?.delegate?.getId()

    return callback { message : "account is not set" }  unless originId

    selector ?= {}
    options  ?= {}

    selector.originId = originId

    @some selector, options, callback


  @fetchCustomData = secure (client, selector, options, callback)->

    # To be able to fetch earned amount first
    # we need to extract type and unit info from selector
    {type, unit} = selector
    _options     = useDefault {type, unit}

    @fetchEarnedAmount$ client, _options, (err, total) =>
      return callback err  if err

      @some$ client, selector, options, (err, rewards) ->
        return callback err  if err

        queue    = []
        rewards ?= []

        rewards.forEach (reward)->
          queue.push ->

            JAccount.one {_id: reward.providedBy}, (err, account)->
              if not err and account
                reward.providedBy = account
              else
                reward.providedBy = null
                reward._hasError  = new KodingError "No user found"

              queue.next()

        queue.push ->
          callback null, {total, rewards}

        daisy queue


  # Background Processes
  # --------------------

  do ->

    logError = (rest...)-> console.error '[Rewards]', rest...

    fetchReferrer = (account, callback)->

      unless referrerUsername = account.referrerUsername
        return callback null # User doesn't have any referrer

      # get referrer
      JAccount.one 'profile.nickname': referrerUsername, (err, referrer)->

        return callback err  if err

        unless referrer
          # if referrer not fonud then do nothing and return
          return callback null # Referrer couldn't found

        callback null, referrer


    confirmRewards = (source, target, callback)->

      JReward.update
        providedBy : source.getId()
        originId   : target.getId()
      ,
        $set       : confirmed : yes
      , (err)->
        return callback err  if err?

        options = { originId: target.getId() }
        JReward.calculateAndUpdateEarnedAmount options, callback


    createRewards = (campaign, source, target, callback)->

      reward   = null
      type     = campaign.type
      unit     = campaign.unit
      originId = target.getId()

      queue = [

        ->

          reward = new JReward {
            amount         : campaign.perEventAmount
            sourceCampaign : campaign.name
            providedBy     : source.getId()
            originId, type, unit
          }

          reward.save (err) ->
            return callback err  if err
            queue.next()

        ->

          campaign.increaseGivenAmount (err)->
            logError "Couldn't increase given amount:", err  if err?

            callback null

      ]

      daisy queue


    JRewardCampaign = require "./rewardcampaign"

    # When users registers we need to give them
    # rewards from existing campaign, if its.

    JUser.on 'UserRegistered', ({user, account})->

      unless user?
        return logError "User is not defined in 'UserRegistered' event"

      referrer = null
      campaign = null

      queue = [
        ->

          # TODO Add fetcher for active campaign ~ GG
          JRewardCampaign.isValid "register", (err, res)->
            return logError err  if err
            return  unless res.isValid

            campaign = res.campaign
            queue.next()

        ->

          fetchReferrer account, (err, _referrer)->
            return logError err  if err
            return  unless _referrer
            referrer = _referrer
            queue.next()

        ->

          createRewards campaign, referrer, account, (err)->
            return logError err  if err
            queue.next()

        ->

          createRewards campaign, account, referrer, (err)->
            return logError err  if err
            queue.next()

      ]

      daisy queue


    # When users confirm their emails we need to confirm
    # existing rewards for them.

    JUser.on 'EmailConfirmed', (user)->

      unless user?
        return logError "User is not defined in 'EmailConfirmed' event"

      me       = null
      referrer = null
      campaign = null

      queue = [

        ->

          user.fetchOwnAccount (err, myAccount)->
            return logError err  if err
            # if account not found then do nothing and return
            return logError "Account couldn't found" unless myAccount

            me = myAccount
            queue.next()

        ->

          if me.referralUsed
            return logError "User already get the referrer"

          fetchReferrer me, (err, _referrer)->
            return logError err  if err
            return  unless _referrer
            referrer = _referrer
            queue.next()

        ->

          me.update $set: "referralUsed": yes, (err)->
            return logError err if err
            queue.next()

        ->

          confirmRewards referrer, me, (err)->
            return logError err if err
            queue.next()

        ->

          confirmRewards me, referrer, (err)->
            return logError err if err
            queue.next()

      ]

      daisy queue

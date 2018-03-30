{ Message, TextMessage } = require.main.require 'hubot'
SlackClient = require './client'
SlackMention = require './mention'
Promise = require 'bluebird'

class ReactionMessage extends Message
  # Represents a message generated by an emoji reaction event
  #
  # type      - A String indicating 'reaction_added' or 'reaction_removed'
  # user      - A User instance that reacted to the item.
  # reaction  - A String identifying the emoji reaction.
  # item_user - A String indicating the user that posted the item.
  # item      - An Object identifying the target message, file, or comment item.
  # event_ts  - A String of the reaction event timestamp.
  constructor: (@type, @user, @reaction, @item_user, @item, @event_ts) ->
    super @user
    @type = @type.replace('reaction_', '')

class PresenceMessage extends Message
  # Represents a message generated by a presence change event
  #
  # users      - Array of users that changed their status
  # presence   - Status is either 'active' or 'away'
  constructor: (@users, @presence) ->
    super({ room: '' })

class SlackTextMessage extends TextMessage

  @MESSAGE_REGEX =  ///
    <              # opening angle bracket
    ([@#!])?       # link type
    ([^>|]+)       # link
    (?:\|          # start of |label (optional)
    ([^>]+)        # label
    )?             # end of label
    >              # closing angle bracket
  ///g

  @MESSAGE_RESERVED_KEYWORDS = ['channel','group','everyone','here']

  # Represents a TextMessage created from the Slack adapter
  #
  # user       - The User object
  # text       - The parsed message text
  # rawText    - The unparsed message text
  # rawMessage - The Slack Message object
  constructor: (@user, text, rawText, @rawMessage, channel, robot_name) ->
    # private instance properties (not trying to expand API contract)
    @_channel = channel
    @_robot_name = robot_name

    # public instance property initialization
    @rawText = if rawText? then rawText else @rawMessage.text
    @text = if text? then text else undefined
    @thread_ts = @rawMessage.thread_ts if @rawMessage.thread_ts?
    @mentions = []

    super @user, @text, @rawMessage.ts

  ###*
  # Build the text property, a flat string representation of the contents of this message.
  ###
  buildText: (client, cb) ->
    # base text
    text = @rawMessage.text

    # flatten any attachments into text
    if @rawMessage.attachments
      attachment_text = @rawMessage.attachments.map(a => a.fallback).join('\n')
      text = text + '\n' + attachment_text

    # Replace links in text async to fetch user and channel info (if present)
    @replaceLinks(client, text).then((replacedText) =>

      text = replacedText
      text = text.replace /&lt;/g, '<'
      text = text.replace /&gt;/g, '>'
      text = text.replace /&amp;/g, '&'

      if @_channel?.is_im
        startOfText = if text.indexOf('@') == 0 then 1 else 0
        robotIsNamed = text.indexOf(@robot.name) == startOfText || text.indexOf(@robot.alias) == startOfText
        # Assume it was addressed to us even if it wasn't
        if not robotIsNamed
          text = "#{@_robot_name} #{text}"     # If this is a DM, pretend it was addressed to us
        
      @text = text

      cb()
    )

  ###*
  # Replace links inside of text
  ###
  replaceLinks: (client, text) ->
    regex = SlackTextMessage.MESSAGE_REGEX
    regex.lastIndex = 0
    cursor = 0
    parts = []

    while (result = regex.exec(text))
      [m, type, link, label] = result

      switch type
        when '@'
          if label
            parts.push(text.slice(cursor, result.index), "@#{label}")
            mention = new SlackMention(link, 'user', undefined)
            @mentions.push(mention)
          else
            parts.push(text.slice(cursor, result.index), @replaceUser(client, link, @mentions))
        
        when '#'
          if label
            parts.push(text.slice(cursor, result.index), "\##{label}")
            mention = new SlackMention(link, 'conversation', undefined)
            @mentions.push(mention)
          else
            parts.push(text.slice(cursor, result.index), @replaceConversation(client, link, @mentions))

        when '!'
          if link in SlackTextMessage.MESSAGE_RESERVED_KEYWORDS
            parts.push(text.slice(cursor, result.index), "@#{link}")
          else if label
            parts.push(text.slice(cursor, result.index), label)
          else
            parts.push(text.slice(cursor, result.index), m)

        else
          link = link.replace /^mailto:/, ''
          if label and -1 == link.indexOf label
            parts.push(text.slice(cursor, result.index), "#{label} (#{link})")
          else
            parts.push(text.slice(cursor, result.index), link)

      cursor = regex.lastIndex
      if (result[0].length == 0) 
        regex.lastIndex++

    parts.push text.slice(cursor)

    return Promise.all(parts).then((substrings) ->
      return substrings.join('')
    )

  ###*
  # Returns name of user with id
  ###
  replaceUser: (client, id, mentions) ->
    client.web.users.info(id).then((user) ->
      if user
        mention = new SlackMention(user.id, 'user', user)
        mentions.push(mention)
        return "@#{user.name}"
      else return "<@#{id}>"
    )
    .catch((error) =>
      client.robot.logger.error "Error getting user info #{id}: #{error.message}"
      return "<@#{id}>"
    )

  ###*
  # Returns name of channel with id
  ###
  replaceConversation: (client, id, mentions) ->
    client.web.conversations.info(id).then((conversation) ->
      if conversation
        mention = new SlackMention(conversation.id, 'conversation', conversation)
        mentions.push(mention)
        return "\##{conversation.name}"
      else return "<\##{id}>"
    )
    .catch((error) =>
      client.robot.logger.error "Error getting conversation info #{id}: #{error.message}"
      return "<\##{id}>"
    )


  ###*
  # Factory method to construct SlackTextMessage
  ###
  @makeSlackTextMessage: (@user, text, rawText, @rawMessage, channel, robot_name, client, cb) ->
    message = new SlackTextMessage(@user, text, rawText, @rawMessage, channel, robot_name, client)

    if not message.text? then message.buildText(client, () ->
      setImmediate(() -> cb(message))
    ) else 
      setImmediate(() -> cb(message))

exports.SlackTextMessage = SlackTextMessage
exports.ReactionMessage = ReactionMessage
exports.PresenceMessage = PresenceMessage
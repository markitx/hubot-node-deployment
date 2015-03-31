_ = require('underscore')

events = require('events')
util = require('util')

version = require('../package.json').version

EventQueue = require('./aws-utils/event-queue');

cloudFormationMessageParser = (message) ->
    # Cloud formation messages can have trailing new lines
    message = message.trim()

    # Clear out escaped single quotes - we are creating JSON objects so don't
    # need the extra escaped quote
    message = message.replace(/'/g, '')

    # Split the message on new lines.  This will get us key/value pairs with '=' separating the key and value (roughly)
    properties = message.split('\n')

    # Create an array of key/value pairs
    kvps = properties.map (e) -> e.split('=')

    # Create an object out of the key/value pairs
    object = _.object(kvps)

    # Strip out the PhysicalResourceId property as it is not complete (It is a URL with query parameters that get chopped up by the split on =)
    _.omit(object, 'PhysicalResourceId')

module.exports = class EventListener
    constructor: () ->
        config =
            name: "hubot-deployments-#{version.replace(/\./gi, '-')}"
            sqsConfig:
                parse: cloudFormationMessageParser

        @eventQueue = new EventQueue(config)

        @eventQueue.on 'event', (event, done) =>
            @_listener(event, done)
        @eventQueue.on 'error', (event) =>
            console.log(event)

        @events = new events.EventEmitter

    getSnsArn: () ->
        @eventQueue.components.topic.topicArn

    stop: () ->
        @eventQueue.stop()

    on: (event, args...) ->
        @events.on event, args...

    emit: (event, args...) ->
        @events.emit event, args...

    _listener: (event, done) ->
        if event.ResourceType == 'AWS::CloudFormation::Stack' && event.ResourceStatus.match(/COMPLETE/g)
                @emit('event', event.StackId, event.ResourceStatus, event)
            done()





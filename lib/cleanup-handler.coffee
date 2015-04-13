_ = require('underscore')

events = require('events')
util = require('util')
moment = require('moment')

version = require('../package.json').version

EventQueue = require('./aws-utils/event-queue')

cleanupMessageParser = (message) ->
    try 
        message = JSON.parse(message)
        return message.body
    catch ex
        console.log 'ERROR'
        console.log message
        console.log ex
        return {}

module.exports = class CleanupHandler
    constructor: () ->
        config =
            name: "hubot-deployments-cleanup-#{version.replace(/\./gi, '-')}"
            sqsConfig:
                parse: cleanupMessageParser

        @queue = new EventQueue(config)

        @queue.on 'event', (event, done) =>
            now = moment()
            cleanupTime = moment(event.cleanupTime)
            if now >= cleanupTime
                return @_listener(event, done)

            @queue.publish event
            done()

        @queue.on 'error', (err) =>
            console.log 'ERROR in cleanup queue'
            console.log(err)

        @queue.components.mainQueue.sqs.getAttributes (err, data) =>
            if err? or not data? or not data.QueueArn?
                console.log "Error configuring queue"
                console.log err
                return

            attributes =
                DelaySeconds: '900'
            
            @queue.components.mainQueue.sqs.setAttributes attributes, (err) =>
                if err?
                    console.log "Error configuring queue when setting attributes"
                    console.log err
                    return
                console.log "Finished configuring cleanup queue: #{data.QueueArn}"

        @events = new events.EventEmitter

        @versionMap = {}

    prepareCleanup: (environment, application, version) =>
        environmentMap = @versionMap[environment] || {}
        versions = {}
        versions[version] = false
        environmentMap[application] = versions
        @versionMap[environment] = environmentMap

    queueCleanup: (environment, application, version) =>
        if @versionMap[environment]
            if @versionMap[environment][application]
                if @versionMap[environment][application][version]?
                    @versionMap[environment][application][version] = true
                    now = moment()
                    cleanupTime = now.add(4, 'hours')
                    console.log "Scheduling cleanup for #{cleanupTime.format()}"
                    @queue.publish { application: application, version: version, environment: environment, timestamp: now.valueOf(), cleanupTime: cleanupTime.valueOf() }

    cancelCleanup: (environment, application) =>
        if @versionMap[environment]
            @versionMap[environment][application] = null

    on: (event, args...) =>
        @events.on event, args...

    emit: (event, args...) =>
        @events.emit event, args...

    _listener: (event, done) =>
        done()
        environment = event.environment
        application = event.application
        version = event.version
        if @versionMap[environment]
            if @versionMap[environment][application]
                if @versionMap[environment][application][version]
                    @emit('cleanup', environment, application, version)




